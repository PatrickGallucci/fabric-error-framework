#Requires -Version 7.0
<#
.SYNOPSIS
    Packages the Fabric Error Framework Python modules as a wheel and deploys
    them to a Microsoft Fabric Environment so the package is available tenant-wide.

.DESCRIPTION
    Implements Option 1 — Fabric Environment + .whl package — for sharing
    fabric_error_codes.py and fabric_error_framework.py across all workspaces.

    Workflow
    --------
    1. Scaffold a minimal Python package directory from the two source .py files.
    2. Build a platform-independent wheel (.whl) using 'python -m build'.
    3. Authenticate to the Fabric REST API via Az PowerShell.
    4. Create the target Environment in the shared workspace (idempotent — reuses
       an existing Environment if the display name already exists).
    5. Upload the wheel to the Environment's staging area (GA Upload Custom Library API).
    6. Trigger a publish operation (GA Publish Environment API, beta=false).
    7. Poll publish status until Success, Failed, or Cancelled.

    Authentication
    --------------
    Requires the Az.Accounts module.  Run Connect-AzAccount before calling this
    script, or supply a service-principal credential via the -TenantId /
    -ClientId / -ClientSecret parameters for non-interactive (CI/CD) runs.

    API endpoints used  (GA, beta=false)
    ------------------------------------
    • List environments   GET  /v1/workspaces/{wid}/environments
    • Create environment  POST /v1/workspaces/{wid}/environments
    • Upload custom lib   POST /v1/workspaces/{wid}/environments/{eid}/staging/libraries
    • Publish environment POST /v1/workspaces/{wid}/environments/{eid}/staging/publish?beta=false
    • Get environment     GET  /v1/workspaces/{wid}/environments/{eid}

.PARAMETER WorkspaceId
    GUID of the shared platform workspace that will host the Environment item.
    Example: 'cfafbeb1-8037-4d0c-896e-a46fb27ff229'

.PARAMETER EnvironmentName
    Display name for the Fabric Environment item.
    Default: 'udp-shared-env'

.PARAMETER EnvironmentDescription
    Description written to the Environment item on creation.

.PARAMETER SourceDirectory
    Path to the folder containing fabric_error_codes.py and fabric_error_framework.py.
    Defaults to the directory this script resides in.

.PARAMETER PackageVersion
    Semantic version embedded in the wheel file name.
    Default: '1.0.0'

.PARAMETER BuildDirectory
    Temporary working directory used to scaffold and build the package.
    Defaults to a subfolder 'fabric_error_framework_build' in $env:TEMP.

.PARAMETER KeepBuildDirectory
    When specified, the build scaffold is not removed after the wheel is built.
    Useful for inspecting the generated package structure.

.PARAMETER PollIntervalSeconds
    Seconds between publish-status polls.  Default: 15.

.PARAMETER PollTimeoutSeconds
    Maximum seconds to wait for publish to complete.  Default: 600 (10 minutes).

.PARAMETER TenantId
    Azure tenant ID for non-interactive (service-principal) authentication.

.PARAMETER ClientId
    Service-principal application (client) ID.

.PARAMETER ClientSecret
    Service-principal client secret (as a SecureString).

.EXAMPLE
    # Interactive — user account, default environment name
    .\Deploy-FabricErrorFramework.ps1 -WorkspaceId 'cfafbeb1-8037-4d0c-896e-a46fb27ff229'

.EXAMPLE
    # Non-interactive — service principal, custom version, custom env name
    $secret = ConvertTo-SecureString 'my-sp-secret' -AsPlainText -Force
    .\Deploy-FabricErrorFramework.ps1 `
        -WorkspaceId   'cfafbeb1-8037-4d0c-896e-a46fb27ff229' `
        -EnvironmentName 'udp-shared-env' `
        -PackageVersion '1.2.0' `
        -TenantId      '00000000-0000-0000-0000-000000000000' `
        -ClientId      '11111111-1111-1111-1111-111111111111' `
        -ClientSecret  $secret

.NOTES
    Prerequisites
    -------------
    • PowerShell 7.0+
    • Python 3.10+ with 'build' package installed  (pip install build)
    • Az.Accounts module  (Install-Module Az.Accounts -Scope CurrentUser)
    • Contributor or higher role on the target Fabric workspace

    The wheel produced is platform-independent (py3-none-any) because the
    framework contains only pure-Python source files.
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string] $WorkspaceId,

    [Parameter()]
    [string] $EnvironmentName = 'udp-shared-env',

    [Parameter()]
    [string] $EnvironmentDescription = 'Shared UDP Python libraries — fabric_error_framework',

    [Parameter()]
    [string] $SourceDirectory = $PSScriptRoot,

    [Parameter()]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string] $PackageVersion = '1.0.0',

    [Parameter()]
    [string] $BuildDirectory = (Join-Path ([IO.Path]::GetTempPath()) 'fabric_error_framework_build'),

    [Parameter()]
    [switch] $KeepBuildDirectory,

    [Parameter()]
    [ValidateRange(5, 300)]
    [int] $PollIntervalSeconds = 15,

    [Parameter()]
    [ValidateRange(60, 3600)]
    [int] $PollTimeoutSeconds = 600,

    # ── Service-principal parameters (optional — for CI/CD) ──────────────────
    [Parameter()]
    [string] $TenantId,

    [Parameter()]
    [string] $ClientId,

    [Parameter()]
    [SecureString] $ClientSecret
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Constants
# ─────────────────────────────────────────────────────────────────────────────
$FABRIC_API_BASE    = 'https://api.fabric.microsoft.com/v1'
$FABRIC_RESOURCE    = 'https://api.fabric.microsoft.com'
$PACKAGE_NAME       = 'fabric_error_framework'
$REQUIRED_PY_FILES  = @('fabric_error_codes.py', 'fabric_error_framework.py')

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Logging helpers
# ─────────────────────────────────────────────────────────────────────────────
function Write-Step {
    param([string] $Message)
    Write-Host "`n── $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string] $Message)
    Write-Host "   ✓ $Message" -ForegroundColor Green
}

function Write-Info {
    param([string] $Message)
    Write-Host "   · $Message" -ForegroundColor Gray
}

function Write-Warn {
    param([string] $Message)
    Write-Warning "   $Message"
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Fabric REST API helper
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-FabricApi {
    <#
    .SYNOPSIS
        Thin wrapper around Invoke-RestMethod for the Fabric REST API.
        Handles auth headers, JSON serialisation, and error surfacing.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string]      $Uri,
        [Parameter(Mandatory)] [string]      $Method,
        [Parameter()]          [hashtable]   $Headers     = @{},
        [Parameter()]          [object]      $Body        = $null,
        [Parameter()]          [hashtable]   $Form        = $null,
        [Parameter()]          [string]      $ContentType = 'application/json'
    )

    # Merge caller headers with the auth bearer token
    $allHeaders = $Headers + $script:AuthHeaders

    $params = @{
        Uri         = $Uri
        Method      = $Method
        Headers     = $allHeaders
        ErrorAction = 'Stop'
    }

    if ($null -ne $Form) {
        # Multipart — let PS build the Content-Type boundary automatically
        $params['Form']        = $Form
    }
    elseif ($null -ne $Body) {
        $params['ContentType'] = $ContentType
        $params['Body']        = ($Body | ConvertTo-Json -Depth 10 -Compress)
    }

    try {
        return Invoke-RestMethod @params
    }
    catch [System.Net.Http.HttpRequestException] {
        $statusCode = $_.Exception.Response?.StatusCode
        $detail     = $_.ErrorDetails.Message
        throw "Fabric API call failed  Method=$Method  URI=$Uri  Status=$statusCode`n$detail"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Step 0 — Prerequisite validation
# ─────────────────────────────────────────────────────────────────────────────
Write-Step 'Validating prerequisites'

# Python must be available
$pythonCmd = Get-Command python3 -ErrorAction SilentlyContinue
    ?? (Get-Command python -ErrorAction SilentlyContinue)

if ($null -eq $pythonCmd) {
    throw 'Python 3.10+ is required but was not found in PATH.  Install Python and retry.'
}

$pythonVersion = (& $pythonCmd.Source --version 2>&1) -replace 'Python ', ''
Write-Info "Python: $($pythonCmd.Source)  ($pythonVersion)"

# 'build' package must be installed
$buildCheck = & $pythonCmd.Source -m build --version 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "'python -m build' is not available.  Run: pip install build"
}
Write-Info "build: $buildCheck"

# Az.Accounts must be present
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    throw "Az.Accounts module is required.  Run: Install-Module Az.Accounts -Scope CurrentUser"
}

# Source .py files must exist
foreach ($pyFile in $REQUIRED_PY_FILES) {
    $fullPath = Join-Path $SourceDirectory $pyFile
    if (-not (Test-Path $fullPath)) {
        throw "Required source file not found: $fullPath"
    }
}
Write-Success 'All prerequisites met'

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Step 1 — Scaffold Python package and build wheel
# ─────────────────────────────────────────────────────────────────────────────
Write-Step 'Building Python wheel'

$packageDir = Join-Path $BuildDirectory $PACKAGE_NAME
$distDir    = Join-Path $BuildDirectory 'dist'

if (Test-Path $BuildDirectory) {
    Remove-Item $BuildDirectory -Recurse -Force
}
New-Item -ItemType Directory -Path $packageDir -Force | Out-Null

# ── Copy source modules into the package ─────────────────────────────────────
foreach ($pyFile in $REQUIRED_PY_FILES) {
    Copy-Item -Path (Join-Path $SourceDirectory $pyFile) -Destination $packageDir
}
Write-Info "Copied source files to $packageDir"

# ── Write __init__.py — re-exports everything so notebooks use one import ─────
$initContent = @"
"""
fabric_error_framework package
Re-exports all public symbols so notebooks can use:

    import fabric_error_framework as ef
    ef.ErrorCode.SRC_1000
    ef.handle_error(...)
"""
from .fabric_error_codes import ErrorCode, ErrorSeverity
from .fabric_error_framework import (
    FabricError,
    handle_error,
    log_error_to_lakehouse,
    retry_on_transient,
    get_spark_logger,
    NOTEBOOK_NAME,
    ENVIRONMENT,
    ERROR_TABLE_NAME,
    MAX_RETRIES,
    RETRY_DELAY_SECONDS,
    RUN_ID,
)

__all__ = [
    "ErrorCode",
    "ErrorSeverity",
    "FabricError",
    "handle_error",
    "log_error_to_lakehouse",
    "retry_on_transient",
    "get_spark_logger",
    "NOTEBOOK_NAME",
    "ENVIRONMENT",
    "ERROR_TABLE_NAME",
    "MAX_RETRIES",
    "RETRY_DELAY_SECONDS",
    "RUN_ID",
]

__version__ = "$PackageVersion"
"@
$initContent | Set-Content -Path (Join-Path $packageDir '__init__.py') -Encoding UTF8NoBOM

# ── Write pyproject.toml ──────────────────────────────────────────────────────
$pyprojectContent = @"
[build-system]
requires = ["setuptools>=68", "wheel"]
build-backend = "setuptools.backends.legacy:build"

[project]
name = "$PACKAGE_NAME"
version = "$PackageVersion"
description = "Unified error handling framework for Microsoft Fabric Notebooks"
readme = "README.md"
requires-python = ">=3.10"
license = { text = "MIT" }
keywords = ["microsoft", "fabric", "spark", "error-handling"]

[tool.setuptools.packages.find]
where = ["."]
include = ["$PACKAGE_NAME*"]
"@
$pyprojectContent | Set-Content -Path (Join-Path $BuildDirectory 'pyproject.toml') -Encoding UTF8NoBOM

# ── Write minimal README ──────────────────────────────────────────────────────
@"
# fabric_error_framework

Unified error handling framework for Microsoft Fabric PySpark Notebooks.

## Usage

```python
import fabric_error_framework as ef
ef.NOTEBOOK_NAME = notebookutils.runtime.context['notebookName']
ef.ENVIRONMENT   = 'prod'
```
"@ | Set-Content -Path (Join-Path $BuildDirectory 'README.md') -Encoding UTF8NoBOM

# ── Build the wheel ───────────────────────────────────────────────────────────
if ($PSCmdlet.ShouldProcess($BuildDirectory, 'Build Python wheel')) {
    Write-Info "Running: python -m build --wheel --outdir $distDir $BuildDirectory"
    & $pythonCmd.Source -m build --wheel --outdir $distDir $BuildDirectory

    if ($LASTEXITCODE -ne 0) {
        throw "python -m build failed with exit code $LASTEXITCODE"
    }
}

$whlFile = Get-ChildItem -Path $distDir -Filter '*.whl' | Select-Object -First 1
if ($null -eq $whlFile) {
    throw "No .whl file found in $distDir after build."
}

Write-Success "Wheel built: $($whlFile.Name)  ($([math]::Round($whlFile.Length / 1KB, 1)) KB)"

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Step 2 — Authenticate to Fabric API
# ─────────────────────────────────────────────────────────────────────────────
Write-Step 'Authenticating to Microsoft Fabric API'

if ($TenantId -and $ClientId -and $ClientSecret) {
    # ── Service-principal (CI/CD) path ────────────────────────────────────────
    Write-Info 'Using service-principal credentials'
    $credential = [PSCredential]::new($ClientId, $ClientSecret)
    Connect-AzAccount -ServicePrincipal -TenantId $TenantId -Credential $credential | Out-Null
}
else {
    # ── Interactive / existing session path ───────────────────────────────────
    $currentContext = Get-AzContext -ErrorAction SilentlyContinue
    if ($null -eq $currentContext) {
        Write-Info 'No active Az session found — launching interactive login'
        Connect-AzAccount | Out-Null
    }
    else {
        Write-Info "Using existing Az session: $($currentContext.Account.Id)"
    }
}

$tokenResponse = Get-AzAccessToken -ResourceUrl $FABRIC_RESOURCE -AsSecureString

# Build auth header — extract plain text safely in PS 7
$plainToken = [PSCredential]::new('token', $tokenResponse.Token).GetNetworkCredential().Password

$script:AuthHeaders = @{
    Authorization = "Bearer $plainToken"
}

Write-Success 'Authenticated successfully'

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Step 3 — Get or create the Fabric Environment
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Resolving Fabric Environment '$EnvironmentName' in workspace $WorkspaceId"

$envListUri = "$FABRIC_API_BASE/workspaces/$WorkspaceId/environments"
$envList    = Invoke-FabricApi -Uri $envListUri -Method 'GET'

$existingEnv = $envList.value | Where-Object { $_.displayName -eq $EnvironmentName } |
               Select-Object -First 1

if ($null -ne $existingEnv) {
    $environmentId = $existingEnv.id
    Write-Info "Found existing Environment: $EnvironmentName  (id=$environmentId)"

    # Check if a publish is already in progress
    $publishState = $existingEnv.properties?.publishDetails?.state
    if ($publishState -in @('Running', 'Waiting')) {
        throw "Environment '$EnvironmentName' has a publish already in progress (state=$publishState).  Wait for it to complete and retry."
    }
}
else {
    Write-Info "Environment not found — creating '$EnvironmentName'"

    if ($PSCmdlet.ShouldProcess($WorkspaceId, "Create Fabric Environment '$EnvironmentName'")) {
        $createBody = @{
            displayName = $EnvironmentName
            description = $EnvironmentDescription
        }
        $newEnv        = Invoke-FabricApi -Uri $envListUri -Method 'POST' -Body $createBody
        $environmentId = $newEnv.id
        Write-Success "Environment created  (id=$environmentId)"
    }
}

Write-Success "Environment resolved  (id=$environmentId)"

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Step 4 — Upload wheel to staging
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Uploading $($whlFile.Name) to Environment staging area"

$uploadUri = "$FABRIC_API_BASE/workspaces/$WorkspaceId/environments/$environmentId/staging/libraries"

if ($PSCmdlet.ShouldProcess($uploadUri, "Upload wheel $($whlFile.Name)")) {
    # Multipart/form-data — PS 7 builds the boundary automatically when -Form is used.
    # Do NOT include Content-Type in the header; let Invoke-RestMethod set it.
    $uploadForm = @{
        file = Get-Item -Path $whlFile.FullName
    }

    # Remove Content-Type from headers for multipart (it must be auto-generated)
    $multipartHeaders = @{
        Authorization = $script:AuthHeaders.Authorization
    }

    $uploadParams = @{
        Uri         = $uploadUri
        Method      = 'POST'
        Headers     = $multipartHeaders
        Form        = $uploadForm
        ErrorAction = 'Stop'
    }

    try {
        Invoke-RestMethod @uploadParams | Out-Null
    }
    catch [System.Net.Http.HttpRequestException] {
        $statusCode = $_.Exception.Response?.StatusCode
        $detail     = $_.ErrorDetails.Message
        throw "Wheel upload failed  Status=$statusCode`n$detail"
    }

    Write-Success "Wheel uploaded to staging: $($whlFile.Name)"
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Step 5 — Publish the Environment
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Publishing Environment '$EnvironmentName'"

$publishUri = "$FABRIC_API_BASE/workspaces/$WorkspaceId/environments/$environmentId/staging/publish?beta=false"

if ($PSCmdlet.ShouldProcess($publishUri, 'Publish Fabric Environment')) {
    $publishResponse = Invoke-FabricApi -Uri $publishUri -Method 'POST'

    $initialState = $publishResponse.publishDetails?.state ?? 'Submitted'
    Write-Info "Publish triggered  (initial state: $initialState)"
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Step 6 — Poll publish status
# ─────────────────────────────────────────────────────────────────────────────
Write-Step 'Polling publish status'

$getEnvUri   = "$FABRIC_API_BASE/workspaces/$WorkspaceId/environments/$environmentId"
$terminalStates = @('Success', 'Failed', 'Cancelled')
$elapsed     = 0
$finalState  = $null

while ($elapsed -lt $PollTimeoutSeconds) {
    Start-Sleep -Seconds $PollIntervalSeconds
    $elapsed += $PollIntervalSeconds

    $envStatus    = Invoke-FabricApi -Uri $getEnvUri -Method 'GET'
    $publishState = $envStatus.properties?.publishDetails?.state

    $libState  = $envStatus.properties?.publishDetails?.componentPublishInfo?.sparkLibraries?.state
    $compState = $envStatus.properties?.publishDetails?.componentPublishInfo?.sparkSettings?.state

    Write-Info ("Elapsed: {0,3}s  publish={1,-12}  sparkLibraries={2}  sparkSettings={3}" -f
        $elapsed, $publishState, $libState, $compState)

    if ($publishState -in $terminalStates) {
        $finalState = $publishState
        break
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Result
# ─────────────────────────────────────────────────────────────────────────────
if ($null -eq $finalState) {
    Write-Warn "Publish did not reach a terminal state within ${PollTimeoutSeconds}s."
    Write-Warn "Check the Environment in the Fabric portal for current status."
}
elseif ($finalState -eq 'Success') {
    Write-Host ''
    Write-Success '══════════════════════════════════════════════════════'
    Write-Success " Deployment complete: $EnvironmentName"
    Write-Success " Wheel version      : $PackageVersion"
    Write-Success " Environment ID     : $environmentId"
    Write-Success " Workspace ID       : $WorkspaceId"
    Write-Success '══════════════════════════════════════════════════════'
    Write-Host ''
    Write-Host '  Notebook import (no sys.path bootstrap needed):' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '      import fabric_error_framework as ef' -ForegroundColor Yellow
    Write-Host "      ef.NOTEBOOK_NAME = notebookutils.runtime.context['notebookName']" -ForegroundColor Yellow
    Write-Host "      ef.ENVIRONMENT   = 'prod'" -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Attach the environment to notebooks via:' -ForegroundColor Cyan
    Write-Host '      Notebook → Home → Environment → udp-shared-env' -ForegroundColor Yellow
    Write-Host '  Or set as workspace default in:' -ForegroundColor Cyan
    Write-Host '      Workspace Settings → Spark → Default Environment' -ForegroundColor Yellow
}
else {
    throw "Environment publish ended with state '$finalState'.  " +
          "Check the Fabric portal for detailed error information."
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Cleanup
# ─────────────────────────────────────────────────────────────────────────────
if (-not $KeepBuildDirectory -and (Test-Path $BuildDirectory)) {
    Remove-Item $BuildDirectory -Recurse -Force
    Write-Info "Build directory removed: $BuildDirectory"
}
elseif ($KeepBuildDirectory) {
    Write-Info "Build directory retained: $BuildDirectory"
}