# fabric-error-framework

> Unified error handling framework for Microsoft Fabric Notebooks.

![Platform](https://img.shields.io/badge/platform-Microsoft%20Fabric-0078D4)
![Runtime](https://img.shields.io/badge/runtime-1.2%2B%20%7C%20Spark%203.4-E25A1C)
![Python](https://img.shields.io/badge/python-3.11-3776AB)
![License](https://img.shields.io/badge/license-MIT-green)

A lightweight, two-file Python library that brings structured, observable,
and resilient error handling to Microsoft Fabric Notebook pipelines. Drop
both files into the Notebook Resource Explorer and get categorized error
codes, severity-driven pipeline control, automatic Delta Lakehouse logging,
and decorator-based retry logic — with zero external dependencies beyond
the Fabric runtime.

---

## Why This Exists

Fabric Notebooks default to ad-hoc `print()` statements and bare `except`
blocks. At enterprise scale this means:

- No consistent error taxonomy across notebooks and teams
- No queryable audit trail for compliance or triage
- Silent data quality degradations that compound across pipeline layers
- Transient failures that kill pipelines instead of retrying automatically

This framework solves all four problems in under 500 lines of pure Python.

---

## Repository Structure

```text
fabric-error-framework/
│
├── fabric_error_codes.py              # Error registry — add new codes here
├── fabric_error_framework.py          # Framework logic — handlers, retry,
│                                      #   Delta logging
│
├── fabric_error_framework_sample.ipynb  # Usage guide notebook (6 sections,
│                                        #   Bronze→Silver→Gold demo)
│
├── docs/
│   ├── README_framework.md            # Full API reference for the library
│   └── README_sample_notebook.md      # Cell-by-cell notebook walkthrough
│
└── README.md                          # This file
```

> **Separation of concerns:** `fabric_error_codes.py` contains only the
> error registry. New codes can be added without touching the framework
> logic, retry decorator, or Delta writer — and without risk in code review.

---

## Quick Start

### Step 1 — Upload to Notebook Resource Explorer

Upload both files to the **Notebook Resource Explorer** in your Fabric
workspace:

- `fabric_error_codes.py`
- `fabric_error_framework.py`

### Step 2 — Bootstrap every notebook

Add this as the **first cell** of any notebook that uses the framework:

```python
import sys

try:
    _res_path = notebookutils.nbResPath
    if _res_path not in sys.path:
        sys.path.insert(0, _res_path)
except NameError:
    pass  # Running outside Fabric (pytest, local dev)

import fabric_error_framework as ef

ef.NOTEBOOK_NAME    = notebookutils.runtime.context["notebookName"]
ef.ENVIRONMENT      = "prod"               # "dev" | "test" | "prod"
ef.ERROR_TABLE_NAME = "notebook_error_log" # Managed Delta table
```

### Step 3 — Wrap pipeline steps

```python
try:
    df = spark.read.format("delta").load("abfss://container@account...")
except Exception as ex:
    ef.handle_error(
        spark      = spark,
        error_code = ef.ErrorCode.SRC_1000,
        exception  = ex,
        cell_name  = "ingest_bronze",
    )
```

`CRITICAL` errors log to Delta and re-raise, halting the pipeline.
All other severities log and return a `FabricError` object for inspection.

---

## Core Concepts

### Two-File Design

```text
fabric_error_codes.py          fabric_error_framework.py
─────────────────────          ─────────────────────────
ErrorSeverity constants    ──► imported by framework
ErrorCode enum registry    ──► re-exported to callers
                               │
                               ├── FabricError dataclass
                               ├── handle_error()
                               ├── log_error_to_lakehouse()
                               ├── retry_on_transient()
                               └── get_spark_logger()
```

Callers `import fabric_error_framework as ef` only. The framework
re-exports `ErrorCode` and `ErrorSeverity` so notebooks need a single
import statement.

### Severity Levels

| Severity | Pipeline behaviour | `raise_on_critical` |
|---|---|---|
| `CRITICAL` | Halts immediately; exception re-raised | `True` (default) |
| `HIGH` | Step failed; pipeline continues degraded | `False` |
| `MEDIUM` | Non-fatal; data quality warning logged | `False` |
| `LOW` | Informational only | `False` |

### Error Code Categories

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

See [`docs/README_framework.md`](docs/README_framework.md) for the full
registry table with descriptions and severities.

---

## Key Features

### Structured error logging to Delta

Every `handle_error()` call appends a structured record to the configured
Delta error table — automatically creating the table if it does not exist.

```python
# Schema written to notebook_error_log
error_code            STRING    NOT NULL
error_description     STRING
severity              STRING    NOT NULL
message               STRING
notebook_name         STRING
environment           STRING
cell_name             STRING
stack_trace           STRING    # Truncated to 4,000 chars
record_count_affected INTEGER
timestamp             STRING    # UTC ISO-8601
run_id                STRING    # 8-char UUID prefix
```

### Run correlation with `RUN_ID`

A unique `RUN_ID` is generated at import time and stamped on every error
record, making it straightforward to isolate all errors from a specific
pipeline execution:

```python
display(
    spark.table("notebook_error_log")
         .filter(F.col("run_id") == ef.RUN_ID)
         .orderBy("timestamp")
)
```

### Retry decorator with linear backoff

```python
@ef.retry_on_transient(max_retries=3, delay_seconds=5)
def read_source_file(path: str) -> DataFrame:
    return spark.read.format("delta").load(path)
```

Retries on `ConnectionError`, `TimeoutError`, and `IOError` by default.
Wait time scales linearly: `delay_seconds × attempt_number`.

### Dual logging (Python + Spark log4j)

`handle_error()` writes to both the Python `logging` module (driver-side)
and the Spark `log4j` logger (visible in the Fabric Monitoring Hub),
ensuring no errors are invisible regardless of where in the cluster they
originate.

---

## Medallion Pipeline Integration

The framework is designed to be applied at each layer of the medallion
architecture with layer-appropriate error codes:

```text
ADLS Source
    │
    ▼
┌──────────────────────────────────────────┐
│  BRONZE — ingest_bronze()                │
│  @retry_on_transient(max_retries=3)      │
│  ErrorCode.SRC_1000 / SRC_1002           │
└──────────────────┬───────────────────────┘
                   │ append
                   ▼
┌──────────────────────────────────────────┐
│  SILVER — transform_silver()             │
│  Null threshold → TRN_2003 (MEDIUM)      │
│  Row count fail → VAL_3000 (HIGH)        │
│  General fail   → TRN_2000 (CRITICAL)    │
└──────────────────┬───────────────────────┘
                   │ overwrite
                   ▼
┌──────────────────────────────────────────┐
│  GOLD — aggregate_gold()                 │
│  Idempotent Delta MERGE                  │
│  ErrorCode.SNK_4001 (HIGH)               │
└──────────────────┬───────────────────────┘
                   │
                   ▼
            notebook_error_log
            (Delta — all layers)
```

A complete, runnable implementation of this pattern is in
[`fabric_error_framework_sample.ipynb`](fabric_error_framework_sample.ipynb).

---

## Observability Queries

After running a pipeline, query the error log directly from a notebook
or the Fabric SQL Analytics Endpoint:

```sql
-- CRITICAL and HIGH errors in production — last 7 days
SELECT
    run_id,
    notebook_name,
    error_code,
    severity,
    cell_name,
    record_count_affected,
    message,
    timestamp
FROM notebook_error_log
WHERE environment = 'prod'
  AND severity IN ('CRITICAL', 'HIGH')
  AND timestamp >= DATEADD(DAY, -7, CURRENT_TIMESTAMP)
ORDER BY timestamp DESC;

-- Error frequency by code — identify systemic issues
SELECT
    error_code,
    severity,
    COUNT(*)                      AS occurrences,
    SUM(record_count_affected)    AS total_records_affected,
    MAX(timestamp)                AS last_seen
FROM notebook_error_log
GROUP BY error_code, severity
ORDER BY occurrences DESC;
```

---

## Adding New Error Codes

Edit **only** `fabric_error_codes.py`. No changes to the framework are
required.

1. Choose the correct category prefix and the next sequential number in
   that range.
1. Add the enum member as a `(code_string, description, severity)` tuple.
1. Upload the updated file to the Notebook Resource Explorer.

```python
# Example — new Silver-layer transformation error
TRN_2004 = (
    "TRN-2004",
    "Lookback window exceeded threshold",
    ErrorSeverity.HIGH,
)
```

---

## Running Tests

The framework guards against `notebookutils` being unavailable, making it
fully testable with standard pytest outside of Fabric.

Install dependencies:

```bash
pip install pytest pyspark delta-spark
```

Run the test suite:

```bash
pytest tests/ -v
```

Example test:

```python
from fabric_error_codes import ErrorCode, ErrorSeverity

def test_critical_codes_have_correct_severity():
    critical_codes = [
        ErrorCode.SRC_1000,
        ErrorCode.SNK_4000,
        ErrorCode.SEC_7000,
        ErrorCode.SYS_8001,
    ]
    for code in critical_codes:
        assert code.severity == ErrorSeverity.CRITICAL, (
            f"{code.name} should be CRITICAL"
        )

def test_error_code_string_format():
    assert ErrorCode.TRN_2001.code == "TRN-2001"
    assert ErrorCode.VAL_3000.code == "VAL-3000"
```

---

## Documentation

| Document | Description |
|---|---|
| [`docs/README_framework.md`](docs/README_framework.md) | Full API reference: `handle_error()`, `retry_on_transient()`, `FabricError`, configuration constants, Delta schema, extension guide |
| [`docs/README_sample_notebook.md`](docs/README_sample_notebook.md) | Cell-by-cell walkthrough of the sample notebook — all 6 sections explained with expected outputs |

---

## Requirements

| Component | Version |
|---|---|
| Microsoft Fabric Runtime | 1.2+ |
| Apache Spark | 3.4+ (included in Runtime 1.2) |
| Python | 3.11+ (included in Runtime 1.2) |
| Delta Lake | Included in Runtime 1.2 |
| `notebookutils` | Provided by Fabric environment |
| External packages | **None** |

---

## Contributing

Contributions are welcome. Please follow these guidelines:

1. Fork the repository and create a `feature/<your-change>` branch off
   `main`.
1. For new error codes, edit only `fabric_error_codes.py` and update
   the registry tables in `docs/README_framework.md`.
1. For framework changes, add or update tests in `tests/` and verify
   no existing tests are broken.
1. Keep lines under 80 characters and follow the existing docstring
   and comment style.
1. Open a pull request against `main` with a concise description of
   the change and its motivation.

---

## License

MIT — see [LICENSE](LICENSE) for details.

---

*Microsoft Fabric Runtime 1.2+ · Spark 3.4 · Python 3.11*
