# Deploy-FabricErrorFramework

A PowerShell 7 script that packages the `fabric_error_framework` Python modules
as a platform-independent wheel (`.whl`) and deploys them to a Microsoft Fabric
Environment — making the package available as a first-class import across every
workspace that attaches the Environment.

```text
fabric_error_codes.py          ┐
fabric_error_framework.py      ┘ ──► .whl ──► Fabric Environment ──► All Workspaces
```

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Parameters](#parameters)
- [Usage](#usage)
  - [Interactive — User Account](#interactive--user-account)
  - [Non-Interactive — Service Principal (CI/CD)](#non-interactive--service-principal-cicd)
  - [Version Bump](#version-bump)
  - [WhatIf / Dry Run](#whatif--dry-run)
- [How It Works](#how-it-works)
- [Notebook Consumption](#notebook-consumption)
- [Azure DevOps Pipeline Integration](#azure-devops-pipeline-integration)
- [Troubleshooting](#troubleshooting)
- [API Reference](#api-reference)
- [Security Considerations](#security-considerations)
- [Contributing](#contributing)

---

## Overview

Sharing a Python helper library across multiple Microsoft Fabric workspaces
requires packaging it as a wheel and attaching it to a shared **Fabric
Environment** item. This script automates the full lifecycle:

1. Scaffolds a proper Python package from two source `.py` files
1. Builds a platform-independent `.whl` using `python -m build`
1. Authenticates to the Fabric REST API via the Az PowerShell module
1. Creates or reuses a named Fabric Environment in a target workspace
1. Uploads the wheel to the Environment's staging area
1. Triggers and monitors the publish operation to completion

Once published, any notebook or Spark Job Definition that attaches
`udp-shared-env` can import the framework with a single line — no `sys.path`
manipulation required.

---

## Architecture

```text
┌─────────────────────────────────────────────────────────────────┐
│  Deploy-FabricErrorFramework.ps1                                │
│                                                                 │
│  Step 1 ─ Scaffold package     Step 4 ─ Upload .whl            │
│           ┌──────────────┐              to staging             │
│           │ __init__.py  │                                      │
│           │ error_codes  │     Step 5 ─ Publish Environment     │
│           │ error_fwk    │                                      │
│           │ pyproject    │     Step 6 ─ Poll publish status     │
│           └──────┬───────┘              until terminal state   │
│                  │                                              │
│  Step 2 ─ python -m build ──► .whl                             │
│                                                                 │
│  Step 3 ─ Get-AzAccessToken  ──► Fabric REST API               │
└─────────────────────────────────────────────────────────────────┘
                                         │
                              ┌──────────▼──────────┐
                              │  Fabric Environment │
                              │  udp-shared-env     │
                              │  ┌───────────────┐  │
                              │  │ .whl (staged) │  │
                              │  │ → published   │  │
                              │  └───────────────┘  │
                              └──────────┬──────────┘
                                         │  attached to
                    ┌────────────────────┼────────────────────┐
                    ▼                    ▼                     ▼
             Workspace A          Workspace B           Workspace C
             (Bronze/Silver)      (Gold/Semantic)       (Data Science)
```

---

## Prerequisites

### System Requirements

| Requirement | Minimum Version | Notes |
|---|---|---|
| PowerShell | 7.0 | Cross-platform (Windows, Linux, macOS) |
| Python | 3.10 | Must be available on `PATH` as `python3` or `python` |
| `build` package | Any | `pip install build` |
| Az.Accounts module | Any | `Install-Module Az.Accounts -Scope CurrentUser` |

### Azure / Fabric Requirements

| Requirement | Details |
|---|---|
| Fabric capacity | Target workspace must be on a Fabric (not Power BI Premium) capacity |
| Workspace role | **Contributor** or higher on the shared platform workspace |
| API permissions | `Environment.ReadWrite.All` or `Item.ReadWrite.All` delegated scope |

### Source Files

The following files must be present in `-SourceDirectory` (defaults to the
script's own directory):

- `fabric_error_codes.py`
- `fabric_error_framework.py`

---

## Installation

```powershell
# 1. Clone or download the script
git clone https://github.com/your-org/unified-data-platform.git
cd unified-data-platform/scripts

# 2. Install Python build tooling
pip install build

# 3. Install the Az.Accounts PowerShell module (once per machine)
Install-Module Az.Accounts -Scope CurrentUser -Force

# 4. (Optional) Verify the script is unblocked on Windows
Unblock-File .\Deploy-FabricErrorFramework.ps1
```

---

## Parameters

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `WorkspaceId` | `string` | **Yes** | — | GUID of the shared platform workspace |
| `EnvironmentName` | `string` | No | `udp-shared-env` | Display name of the Fabric Environment item |
| `EnvironmentDescription` | `string` | No | `Shared UDP Python libraries…` | Description written on first creation |
| `SourceDirectory` | `string` | No | Script directory | Folder containing the two `.py` source files |
| `PackageVersion` | `string` | No | `1.0.0` | Semantic version embedded in the wheel filename |
| `BuildDirectory` | `string` | No | `$env:TEMP/fabric_error_framework_build` | Temporary scaffold and build location |
| `KeepBuildDirectory` | `switch` | No | `$false` | Retain the build scaffold after the wheel is produced |
| `PollIntervalSeconds` | `int` | No | `15` | Seconds between publish-status polls |
| `PollTimeoutSeconds` | `int` | No | `600` | Maximum seconds to wait for publish (1–3600) |
| `TenantId` | `string` | No | — | Azure tenant ID for service-principal auth |
| `ClientId` | `string` | No | — | Service-principal application (client) ID |
| `ClientSecret` | `SecureString` | No | — | Service-principal secret |

> **Note:** `WorkspaceId` must be a valid GUID in the format
> `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`. It can be found in the Fabric
> workspace URL after `/groups/`.

---

## Usage

### Interactive — User Account

```powershell
# Authenticate first (opens browser)
Connect-AzAccount

# Deploy with all defaults
.\Deploy-FabricErrorFramework.ps1 `
    -WorkspaceId 'cfafbeb1-8037-4d0c-896e-a46fb27ff229'
```

### Non-Interactive — Service Principal (CI/CD)

```powershell
$secret = ConvertTo-SecureString $env:FABRIC_CLIENT_SECRET -AsPlainText -Force

.\Deploy-FabricErrorFramework.ps1 `
    -WorkspaceId      'cfafbeb1-8037-4d0c-896e-a46fb27ff229' `
    -EnvironmentName  'udp-shared-env' `
    -PackageVersion   '1.2.0' `
    -TenantId         $env:FABRIC_TENANT_ID `
    -ClientId         $env:FABRIC_CLIENT_ID `
    -ClientSecret     $secret
```

### Version Bump

Supply `-PackageVersion` whenever the source files change. The Fabric
Environment will be updated in-place; existing notebooks do not need to be
modified.

```powershell
.\Deploy-FabricErrorFramework.ps1 `
    -WorkspaceId    'cfafbeb1-8037-4d0c-896e-a46fb27ff229' `
    -PackageVersion '1.3.0'
```

### WhatIf / Dry Run

Use the standard PowerShell `-WhatIf` switch to preview actions without
modifying any Fabric resources.

```powershell
.\Deploy-FabricErrorFramework.ps1 `
    -WorkspaceId 'cfafbeb1-8037-4d0c-896e-a46fb27ff229' `
    -WhatIf
```

### Custom Source Directory

Use `-SourceDirectory` when the `.py` files are in a different location from
the script.

```powershell
.\Deploy-FabricErrorFramework.ps1 `
    -WorkspaceId    'cfafbeb1-8037-4d0c-896e-a46fb27ff229' `
    -SourceDirectory 'C:\repos\udp\src\python'
```

---

## How It Works

### Step 1 — Build Python Wheel

The script scaffolds a minimal Python package in a temporary directory:

```text
fabric_error_framework_build/
├── pyproject.toml
├── README.md
└── fabric_error_framework/
    ├── __init__.py            ← re-exports all public symbols
    ├── fabric_error_codes.py  ← copied from -SourceDirectory
    └── fabric_error_framework.py
```

The `__init__.py` re-exports every public symbol so notebooks continue to use
the same import surface:

```python
import fabric_error_framework as ef
ef.ErrorCode.SRC_1000
ef.handle_error(...)
```

`python -m build --wheel` then produces a platform-independent wheel:

```text
fabric_error_framework-1.0.0-py3-none-any.whl
```

### Step 2 — Authenticate

The script calls `Get-AzAccessToken` against the Fabric API resource
(`https://api.fabric.microsoft.com`). If the `-TenantId`, `-ClientId`, and
`-ClientSecret` parameters are provided it authenticates as a service
principal; otherwise it reuses any active `Connect-AzAccount` session.

### Step 3 — Resolve Environment

The script lists all Environments in the workspace and matches by
`displayName`. If the Environment does not exist it is created. If it does
exist and a publish is already in progress, the script halts with an
informative error rather than corrupting the in-flight operation.

### Step 4 — Upload Wheel

The wheel is uploaded to the Environment staging area using the GA
`Upload Custom Library` endpoint:

```text
POST /v1/workspaces/{workspaceId}/environments/{environmentId}/staging/libraries
Content-Type: multipart/form-data
```

### Step 5 — Publish

The GA `Publish Environment` endpoint is called with `?beta=false` to use the
stable contract:

```text
POST /v1/workspaces/{workspaceId}/environments/{environmentId}/staging/publish
     ?beta=false
```

### Step 6 — Poll

The script polls `GET /v1/workspaces/{wid}/environments/{eid}` every
`-PollIntervalSeconds` seconds and writes a status line showing the overall
publish state alongside per-component states
(`sparkLibraries`, `sparkSettings`).

Terminal states are `Success`, `Failed`, and `Cancelled`.

---

## Notebook Consumption

After a successful deployment, attach the environment to each notebook and
use the clean import:

```python
# ── One-line import — no sys.path bootstrap needed ──────────────────────────
import fabric_error_framework as ef

# Configure module constants
ef.NOTEBOOK_NAME   = notebookutils.runtime.context['notebookName']
ef.ENVIRONMENT     = 'prod'
ef.ERROR_TABLE_NAME = 'notebook_error_log'

# Use the framework
try:
    raise ValueError('Example error')
except Exception as ex:
    ef.handle_error(
        spark,
        ef.ErrorCode.SRC_1000,
        ex,
        cell_name='my_cell',
        raise_on_critical=False,
    )
```

### Attaching the Environment

There are two ways to attach the shared environment to notebooks:

**Per notebook** — select the environment from the notebook toolbar:

```text
Notebook → Home tab → Environment dropdown → udp-shared-env
```

**Workspace default** — applies to all new notebooks automatically:

```text
Workspace Settings → Data Engineering / Science → Spark Settings
    → Default Environment → udp-shared-env
```

---

## Azure DevOps Pipeline Integration

Add the following stage to your release pipeline. Store secrets in a variable
group named `fabric-deployment-secrets`.

```yaml
# azure-pipelines.yml
stages:
  - stage: DeployFabricFramework
    displayName: Deploy Fabric Error Framework
    jobs:
      - deployment: PublishWheel
        displayName: Build and publish .whl to Fabric Environment
        environment: fabric-production
        strategy:
          runOnce:
            deploy:
              steps:
                - task: UsePythonVersion@0
                  displayName: Set Python 3.11
                  inputs:
                    versionSpec: '3.11'

                - script: pip install build
                  displayName: Install build tooling

                - task: PowerShell@2
                  displayName: Deploy fabric_error_framework
                  inputs:
                    targetType: filePath
                    filePath: >-
                      $(Build.SourcesDirectory)/scripts/
                      Deploy-FabricErrorFramework.ps1
                    arguments: >-
                      -WorkspaceId   "$(FabricWorkspaceId)"
                      -PackageVersion "$(Build.BuildNumber)"
                      -TenantId      "$(FabricTenantId)"
                      -ClientId      "$(FabricClientId)"
                      -ClientSecret  (ConvertTo-SecureString
                                        "$(FabricClientSecret)"
                                        -AsPlainText -Force)
                    pwsh: true
                  env:
                    FabricClientSecret: $(FabricClientSecret)
```

### Required Variable Group (`fabric-deployment-secrets`)

| Variable | Secret | Description |
|---|---|---|
| `FabricWorkspaceId` | No | GUID of the shared platform workspace |
| `FabricTenantId` | No | Azure tenant ID |
| `FabricClientId` | No | Service-principal application ID |
| `FabricClientSecret` | **Yes** | Service-principal secret |

---

## Troubleshooting

### `python -m build` is not available

```text
Error: 'python -m build' is not available. Run: pip install build
```

**Fix:**

```powershell
pip install build
# Verify
python -m build --version
```

### Source files not found

```text
Error: Required source file not found: C:\scripts\fabric_error_codes.py
```

**Fix:** Pass the correct path with `-SourceDirectory`:

```powershell
.\Deploy-FabricErrorFramework.ps1 `
    -WorkspaceId    '...' `
    -SourceDirectory 'C:\repos\udp\src'
```

### Publish already in progress

```text
Error: Environment 'udp-shared-env' has a publish already in progress
       (state=Running).
```

**Fix:** Wait for the in-progress publish to reach a terminal state (visible in
the Fabric portal under the Environment item), then re-run the script.

### Publish timed out

```text
Warning: Publish did not reach a terminal state within 600s.
```

Fabric Environment publishes can take 5–15 minutes when large dependency
graphs are resolved. Increase the timeout with `-PollTimeoutSeconds`:

```powershell
.\Deploy-FabricErrorFramework.ps1 `
    -WorkspaceId       '...' `
    -PollTimeoutSeconds 1200
```

### Unauthorized (403) on wheel upload

The calling identity needs **Contributor** or higher on the workspace. Verify
the role assignment in:

```text
Fabric portal → Workspace → Manage access
```

### Wheel file name rejected

The `.whl` filename is derived from `pyproject.toml` and follows PEP 427:

```text
fabric_error_framework-{version}-py3-none-any.whl
```

If `-PackageVersion` contains characters other than digits and dots
(`\d+\.\d+\.\d+`), the parameter validation will reject it before any build
attempt.

---

## API Reference

The script uses the following Microsoft Fabric REST API endpoints. All calls
use the GA contract (`beta=false`) to avoid deprecation impact after
March 31, 2026.

| Operation | Method | Endpoint |
|---|---|---|
| List Environments | `GET` | `/v1/workspaces/{wid}/environments` |
| Create Environment | `POST` | `/v1/workspaces/{wid}/environments` |
| Get Environment | `GET` | `/v1/workspaces/{wid}/environments/{eid}` |
| Upload Custom Library | `POST` | `/v1/workspaces/{wid}/environments/{eid}/staging/libraries` |
| Publish Environment | `POST` | `/v1/workspaces/{wid}/environments/{eid}/staging/publish?beta=false` |

Full API documentation:
[Manage the Environment Through Public APIs](https://learn.microsoft.com/en-us/fabric/data-engineering/environment-public-api)

---

## Security Considerations

### Credential Handling

- The bearer token is retrieved via `Get-AzAccessToken` and stored only in
  memory as a local variable — never written to disk or logs.
- For service-principal auth, `-ClientSecret` is typed as `[SecureString]`.
  Extract the plain text only in-memory using `PSCredential` and discard
  immediately after token acquisition.
- Do **not** pass secrets as plain-text command-line arguments in CI/CD
  pipelines; use secret variables or a key vault task instead.

### Principle of Least Privilege

Grant the deployment service principal only the permissions it needs:

| Scope | Role |
|---|---|
| Shared platform workspace | Contributor |
| All other workspaces | None (read attachment only) |

### Network Outbound Rules

If the Fabric workspace has **outbound access protection** enabled, the
`python -m build` step must run on a trusted compute resource that can
reach PyPI — or the dependencies must be pre-downloaded. The script itself
only calls `api.fabric.microsoft.com` and `login.microsoftonline.com`.

---

## Contributing

1. Fork the repository and create a feature branch from `main`
1. Follow the PowerShell conventions in this repo (`CmdletBinding`,
   `SupportsShouldProcess`, `Write-Verbose` for debug output)
1. Add or update Pester tests in `tests/Deploy-FabricErrorFramework.Tests.ps1`
1. Open a pull request with a clear description of the change and its
   business justification
