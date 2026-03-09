# Fabric Error Handling Framework

A production-grade, structured error handling framework for Microsoft Fabric
Notebooks. Provides centralized error codes, severity classification, Delta
Lakehouse error logging, and transient-fault retry logic for PySpark data
pipelines running on Microsoft Fabric.

## Table of Contents

- [Overview](#overview)
- [File Structure](#file-structure)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Error Code Registry](#error-code-registry)
- [API Reference](#api-reference)
- [Configuration](#configuration)
- [Usage Patterns](#usage-patterns)
- [Error Log Schema](#error-log-schema)
- [Extending the Framework](#extending-the-framework)
- [Running Unit Tests](#running-unit-tests)
- [Architecture Decisions](#architecture-decisions)
- [Contributing](#contributing)

---

## Overview

This framework addresses a common gap in Fabric Notebook implementations:
ad-hoc `print()` statements and unstructured exception handling that make
triage, auditing, and pipeline monitoring difficult at enterprise scale.

**Key capabilities:**

- Structured error codes with category prefixes and numeric ranges
- Severity-driven pipeline control (`CRITICAL` errors halt execution)
- Dual logging — Python `logging` module and Spark `log4j`
- Automatic persistence of error records to a Delta Lakehouse table
- Decorator-based retry logic with linear backoff for transient faults
- Clean two-file separation: framework logic vs. error code registry

---

## File Structure

```text
├── fabric_error_codes.py       # Error severity levels and code registry
├── fabric_error_framework.py   # Framework logic, handlers, and decorators
└── README.md                   # This file
```

**Separation of concerns:** `fabric_error_codes.py` is intentionally kept
free of framework logic. New error codes can be added by any team member
without risk of modifying retry, logging, or Delta write behaviour.

---

## Prerequisites

| Requirement | Version |
|---|---|
| Microsoft Fabric Runtime | 1.2+ (Spark 3.4 / Python 3.11) |
| PySpark | 3.4+ (included in Fabric Runtime) |
| Delta Lake | Included in Fabric Runtime |
| `notebookutils` | Provided by Fabric environment |

> **Note:** Both files must be uploaded to the **Notebook Resource Explorer**
> of the target Fabric workspace so that `notebookutils.nbResPath` resolves
> them at runtime.

---

## Installation

### Step 1 — Upload to Notebook Resource Explorer

1. Open your Fabric Notebook.
1. In the left pane, select **Notebook Resources**.
1. Upload both files:
   - `fabric_error_codes.py`
   - `fabric_error_framework.py`

### Step 2 — Add the Bootstrap Cell

Add the following to the **first cell** of every notebook that uses this
framework:

```python
import sys
sys.path.insert(0, notebookutils.nbResPath)

import fabric_error_framework as ef

# Identify this notebook in all error log records
ef.NOTEBOOK_NAME = notebookutils.runtime.context["notebookName"]
ef.ENVIRONMENT   = "prod"   # "dev" | "test" | "prod"
```

---

## Quick Start

```python
# Cell: ingest_raw
try:
    df = spark.read.format("delta").load("abfss://container@account.dfs.core.windows.net/raw/")
except Exception as ex:
    ef.handle_error(
        spark       = spark,
        error_code  = ef.ErrorCode.SRC_1000,
        exception   = ex,
        cell_name   = "ingest_raw",
    )
```

A `CRITICAL` severity code (such as `SRC_1000`) will log the error to the
Delta table **and** re-raise the exception, halting the pipeline. Lower
severity codes log and return the `FabricError` object for caller inspection.

---

## Error Code Registry

Error codes follow the pattern `CATEGORY-NNNN` and are defined as `Enum`
members in `fabric_error_codes.py`.

### Categories and Ranges

| Prefix | Category | Range |
|---|---|---|
| `SRC` | Source / Ingestion | 1000–1999 |
| `TRN` | Transformation | 2000–2999 |
| `VAL` | Validation / Data Quality | 3000–3999 |
| `SNK` | Sink / Write | 4000–4999 |
| `CFG` | Configuration | 5000–5999 |
| `NET` | Network / Connectivity | 6000–6999 |
| `SEC` | Security / Auth | 7000–7999 |
| `SYS` | System / Infrastructure | 8000–8999 |
| `ALT` | Alerting meta-errors | 9000–9999 |

### Severity Levels

| Severity | Behaviour |
|---|---|
| `CRITICAL` | Pipeline halts; exception re-raised |
| `HIGH` | Step failed; pipeline continues with degraded results |
| `MEDIUM` | Non-fatal; data quality warning logged |
| `LOW` | Informational; logged only |

### Registered Codes

#### SRC — Source / Ingestion

| Code | Description | Severity |
|---|---|---|
| `SRC_1000` | Source file not found | CRITICAL |
| `SRC_1001` | Source file schema mismatch | HIGH |
| `SRC_1002` | Source file is empty | HIGH |
| `SRC_1003` | Source read timeout | HIGH |
| `SRC_1004` | Unsupported source file format | MEDIUM |

#### TRN — Transformation

| Code | Description | Severity |
|---|---|---|
| `TRN_2000` | Transformation failed - general | CRITICAL |
| `TRN_2001` | Column not found in DataFrame | HIGH |
| `TRN_2002` | Data type cast failure | MEDIUM |
| `TRN_2003` | Null values exceed threshold | MEDIUM |

#### VAL — Validation / Data Quality

| Code | Description | Severity |
|---|---|---|
| `VAL_3000` | Row count validation failed | HIGH |
| `VAL_3001` | Duplicate primary keys detected | HIGH |
| `VAL_3002` | Referential integrity check failed | MEDIUM |
| `VAL_3003` | Business rule validation failed | MEDIUM |

#### SNK — Sink / Write

| Code | Description | Severity |
|---|---|---|
| `SNK_4000` | Lakehouse write failed | CRITICAL |
| `SNK_4001` | Delta merge conflict | HIGH |
| `SNK_4002` | Partition overwrite failed | HIGH |

#### CFG — Configuration

| Code | Description | Severity |
|---|---|---|
| `CFG_5000` | Missing required configuration | CRITICAL |
| `CFG_5001` | Invalid parameter value | HIGH |

#### NET — Network / Connectivity

| Code | Description | Severity |
|---|---|---|
| `NET_6000` | External API unreachable | HIGH |
| `NET_6001` | Connection timeout | HIGH |

#### SEC — Security / Auth

| Code | Description | Severity |
|---|---|---|
| `SEC_7000` | Key Vault secret retrieval failed | CRITICAL |
| `SEC_7001` | Insufficient permissions | CRITICAL |

#### SYS — System / Infrastructure

| Code | Description | Severity |
|---|---|---|
| `SYS_8000` | Out of memory - executor | CRITICAL |
| `SYS_8001` | Spark session lost | CRITICAL |
| `SYS_8002` | Unexpected system error | CRITICAL |

#### ALT — Alerting Meta-Errors

| Code | Description | Severity |
|---|---|---|
| `ALT_9000` | Teams webhook delivery failed | LOW |

---

## API Reference

### `handle_error()`

Central error handler. Logs to console, Spark log4j, and the Lakehouse Delta
error table. Re-raises on `CRITICAL` severity by default.

```python
ef.handle_error(
    spark                  = spark,          # SparkSession (required)
    error_code             = ef.ErrorCode.TRN_2001,  # ErrorCode enum (required)
    exception              = ex,             # Caught exception (required)
    notebook_name          = "my_notebook",  # Default: module constant
    environment            = "prod",         # Default: module constant
    cell_name              = "transform",    # Descriptive step name
    record_count_affected  = 1500,           # Impacted record count
    raise_on_critical      = True,           # Re-raise CRITICAL errors
) -> FabricError
```

**Returns:** `FabricError` dataclass for downstream inspection or alerting.

---

### `retry_on_transient()`

Decorator that retries a function on transient exceptions with linear backoff.
Defaults to `ConnectionError`, `TimeoutError`, and `IOError`.

```python
@ef.retry_on_transient(max_retries=3, delay_seconds=5)
def read_source_data(spark: SparkSession) -> DataFrame:
    return spark.read.format("delta").load("abfss://...")
```

**Parameters:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `max_retries` | `int` | `3` | Maximum retry attempts |
| `delay_seconds` | `int` | `5` | Base delay; multiplied by attempt number |
| `transient_exceptions` | `tuple` | `(ConnectionError, TimeoutError, IOError)` | Exception types to retry |

---

### `log_error_to_lakehouse()`

Appends a structured `FabricError` record to the configured Delta error log
table. Called automatically by `handle_error()`; available for direct use
when constructing custom `FabricError` objects.

```python
ef.log_error_to_lakehouse(spark, fabric_error_instance)
```

---

### `get_spark_logger()`

Returns the Spark log4j logger for the current notebook context. Falls back
to Python `logging` when called outside a Fabric runtime (e.g. during unit
tests).

```python
logger = ef.get_spark_logger(spark)
if logger:
    logger.info("Custom log4j message")
```

---

### `FabricError` Dataclass

```python
@dataclass
class FabricError:
    error_code:            ErrorCode
    message:               str
    notebook_name:         str
    environment:           str
    cell_name:             str = ""
    stack_trace:           str = ""
    record_count_affected: int = 0
    timestamp:             str = ""   # UTC ISO-8601, auto-populated
    run_id:                str = ""   # 8-char UUID segment, auto-populated
```

**Properties:**

- `severity` — String severity from the `ErrorCode` enum (`CRITICAL`, etc.)
- `code` — String code value (e.g. `"TRN-2001"`)
- `to_dict()` — Returns a flat `dict` suitable for Delta row insertion

---

## Configuration

Override module-level constants in the notebook bootstrap cell:

```python
import fabric_error_framework as ef

ef.NOTEBOOK_NAME        = notebookutils.runtime.context["notebookName"]
ef.ENVIRONMENT          = "prod"          # Deployment tier
ef.ERROR_TABLE_NAME     = "notebook_error_log"  # Target Delta table name
ef.MAX_RETRIES          = 3               # Global retry default
ef.RETRY_DELAY_SECONDS  = 5              # Global retry base delay (seconds)
```

| Constant | Default | Description |
|---|---|---|
| `NOTEBOOK_NAME` | `"fabric_notebook"` | Written to every error log record |
| `ENVIRONMENT` | `"dev"` | Written to every error log record |
| `ERROR_TABLE_NAME` | `"notebook_error_log"` | Delta table for error persistence |
| `MAX_RETRIES` | `3` | Default max retries for `retry_on_transient` |
| `RETRY_DELAY_SECONDS` | `5` | Base seconds between retries |
| `RUN_ID` | Auto (UUID prefix) | Correlates all errors within a single run |

---

## Usage Patterns

### Pattern 1 — Standard Exception Handling

```python
try:
    df = spark.read.format("delta").load(source_path)
except Exception as ex:
    ef.handle_error(
        spark      = spark,
        error_code = ef.ErrorCode.SRC_1000,
        exception  = ex,
        cell_name  = "read_bronze_layer",
    )
```

### Pattern 2 — Non-Fatal Validation Warning

```python
duplicate_count = df.groupBy("OrderID").count().filter("count > 1").count()

if duplicate_count > 0:
    ef.handle_error(
        spark                 = spark,
        error_code            = ef.ErrorCode.VAL_3001,
        exception             = ValueError(f"{duplicate_count} duplicate keys"),
        cell_name             = "validate_order_keys",
        record_count_affected = duplicate_count,
    )
    # Pipeline continues — VAL_3001 is HIGH, not CRITICAL
```

### Pattern 3 — Retry Decorator on Source Read

```python
@ef.retry_on_transient(max_retries=4, delay_seconds=10)
def load_api_payload(spark: SparkSession) -> DataFrame:
    return (
        spark.read
             .format("json")
             .load("abfss://landing@account.dfs.core.windows.net/api/")
    )

df = load_api_payload(spark)
```

### Pattern 4 — Suppress Re-Raise for Conditional Logic

```python
error = ef.handle_error(
    spark             = spark,
    error_code        = ef.ErrorCode.SRC_1002,
    exception         = ex,
    cell_name         = "check_source_file",
    raise_on_critical = False,   # Handle CRITICAL without halting
)

if error.severity == "CRITICAL":
    notebookutils.notebook.exit("SOURCE_EMPTY")
```

### Pattern 5 — Inspecting the Returned FabricError

```python
error = ef.handle_error(
    spark      = spark,
    error_code = ef.ErrorCode.TRN_2003,
    exception  = ex,
    cell_name  = "null_check",
)

print(f"Logged code  : {error.code}")
print(f"Severity     : {error.severity}")
print(f"Run ID       : {error.run_id}")
print(f"Timestamp    : {error.timestamp}")
```

---

## Error Log Schema

Errors are persisted to a Delta table (default: `notebook_error_log`) with the
following schema:

| Column | Type | Nullable | Description |
|---|---|---|---|
| `error_code` | STRING | No | Error code (e.g. `"SRC-1000"`) |
| `error_description` | STRING | Yes | Human-readable description |
| `severity` | STRING | No | `CRITICAL` / `HIGH` / `MEDIUM` / `LOW` |
| `message` | STRING | Yes | Exception message |
| `notebook_name` | STRING | Yes | Source notebook |
| `environment` | STRING | Yes | `dev` / `test` / `prod` |
| `cell_name` | STRING | Yes | Pipeline step label |
| `stack_trace` | STRING | Yes | Truncated to 4,000 characters |
| `record_count_affected` | INTEGER | Yes | Impacted record count |
| `timestamp` | STRING | Yes | UTC ISO-8601 timestamp |
| `run_id` | STRING | Yes | 8-char UUID prefix for run correlation |

**Querying errors in Fabric SQL Analytics Endpoint or Notebook:**

```sql
SELECT
    run_id,
    notebook_name,
    error_code,
    severity,
    message,
    timestamp
FROM notebook_error_log
WHERE environment = 'prod'
  AND severity IN ('CRITICAL', 'HIGH')
ORDER BY timestamp DESC;
```

---

## Extending the Framework

### Adding a New Error Code

Edit only `fabric_error_codes.py`. No changes to the framework file are
required.

1. Choose the correct category prefix and next available number in that range.
1. Add a new `Enum` member with the `(code_string, description, severity)` tuple.
1. Upload the updated file to the Notebook Resource Explorer.

```python
# Example: add a new transformation error
TRN_2004 = ("TRN-2004", "Lookback window exceeded threshold", ErrorSeverity.HIGH)
```

### Adding a New Category

1. Define a new prefix (e.g. `EXT` for external service errors).
1. Reserve a numeric range that does not overlap existing categories.
1. Add a comment block in `fabric_error_codes.py` documenting the range.
1. Update this README with the new category in the registry tables.

### Custom Alerting (e.g. Teams Webhook)

`handle_error()` returns a `FabricError` object. Wrap it with your alerting
logic after the call:

```python
error = ef.handle_error(
    spark      = spark,
    error_code = ef.ErrorCode.SNK_4000,
    exception  = ex,
    cell_name  = "write_gold_layer",
)

if error.severity == "CRITICAL":
    post_teams_alert(error.to_dict())   # Your custom alerting function
```

---

## Running Unit Tests

The framework is designed to be testable outside of a Fabric runtime. The
`try/except NameError` guard around `notebookutils` allows import in standard
Python environments.

Install test dependencies:

```bash
pip install pytest pyspark delta-spark
```

Run tests:

```bash
pytest tests/ -v
```

**Example test structure:**

```python
# tests/test_error_codes.py
from fabric_error_codes import ErrorCode, ErrorSeverity

def test_src_1000_is_critical():
    assert ErrorCode.SRC_1000.severity == ErrorSeverity.CRITICAL

def test_val_3002_is_medium():
    assert ErrorCode.VAL_3002.severity == ErrorSeverity.MEDIUM

def test_error_code_format():
    assert ErrorCode.TRN_2001.code == "TRN-2001"
```

---

## Architecture Decisions

### Two-File Design

`fabric_error_codes.py` is separated from `fabric_error_framework.py` so that
the code registry can be updated independently. Teams can add domain-specific
error codes through pull request without any risk of breaking retry logic,
Delta write logic, or the logging pipeline.

### `notebookutils.nbResPath` Path Resolution

The framework inserts the Notebook Resource path into `sys.path` at import
time, ensuring both files resolve correctly whether the notebook is run
interactively, via a pipeline activity, or in a CI test runner.

### Log4j + Python Dual Logging

Fabric Spark notebooks run driver and executor processes. Python `logging`
captures driver-side messages. The Spark `log4j` logger ensures messages also
appear in the unified Fabric monitoring logs, making triage in the Monitoring
Hub more effective.

### Linear Backoff

The retry decorator uses linear (not exponential) backoff
(`delay * attempt_number`) to avoid excessive wait times in high-throughput
pipeline runs while still providing meaningful spacing between retry attempts.

### Stack Trace Truncation

Stack traces are truncated to 4,000 characters before persisting to Delta.
This prevents single large exceptions from causing write failures due to
column size limits in the Lakehouse storage layer.

---

## Contributing

1. Fork the repository and create a `feature/your-change` branch.
1. Follow the existing code style (type hints, docstrings, `#` section headers).
1. Add or update unit tests for any changed behaviour.
1. Update `fabric_error_codes.py` comments if adding a new category range.
1. Open a pull request against `main` with a clear description of the change.

---

*Compatible with Microsoft Fabric Runtime 1.2+ (Spark 3.4 / Python 3.11).*
