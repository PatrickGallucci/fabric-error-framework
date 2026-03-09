# Fabric Error Framework — Sample Notebook

A hands-on usage guide for the
[`fabric_error_framework`](../fabric_error_framework.py) library. This
notebook demonstrates every public API surface of the error handling framework
across six structured sections, culminating in a complete Bronze → Silver →
Gold medallion pipeline with per-layer error handling.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Notebook Structure](#notebook-structure)
- [Section Walkthrough](#section-walkthrough)
  - [Section 1 — Setup](#section-1--setup)
  - [Section 2 — Basic handle\_error Usage](#section-2--basic-handle_error-usage)
  - [Section 3 — retry\_on\_transient Decorator](#section-3--retry_on_transient-decorator)
  - [Section 4 — Severity Routing Reference](#section-4--severity-routing-reference)
  - [Section 5 — Full Medallion Pipeline](#section-5--full-medallion-pipeline)
  - [Section 6 — Querying the Error Log](#section-6--querying-the-error-log)
- [Running the Notebook](#running-the-notebook)
- [Expected Outputs](#expected-outputs)
- [Delta Tables Created](#delta-tables-created)
- [Adapting for Your Pipeline](#adapting-for-your-pipeline)
- [Related Files](#related-files)

---

## Overview

This notebook is the reference implementation and living documentation for the
Fabric error handling framework. Each section is self-contained and can be run
independently after the bootstrap cell in Section 1 has executed.

**What you will learn:**

- How to configure the framework for a specific notebook and environment
- How severity levels (`CRITICAL`, `HIGH`, `MEDIUM`, `LOW`) control pipeline
  flow
- How to use the `retry_on_transient` decorator to handle flaky source reads
- How to apply per-layer error handling across a medallion architecture
- How to query the Delta error log table for observability and audit trails

---

## Prerequisites

| Requirement | Detail |
|---|---|
| Microsoft Fabric Runtime | 1.2+ (Spark 3.4 / Python 3.11) |
| Notebook Resource files | `fabric_error_codes.py` and `fabric_error_framework.py` uploaded to the workspace Notebook Resource Explorer |
| Default Lakehouse | Attached to the notebook — required for Delta table writes |
| `delta-spark` | Included in Fabric Runtime 1.2+ |

> **Important:** Both `fabric_error_codes.py` and `fabric_error_framework.py`
> must be uploaded to the **Notebook Resource Explorer** before running this
> notebook. The bootstrap cell in Section 1 resolves them via
> `notebookutils.nbResPath`.

---

## Notebook Structure

```text
fabric_error_framework_sample.ipynb
│
├── Section 1 — Setup
│   ├── Cell 1a: sys.path bootstrap (notebookutils.nbResPath)
│   └── Cell 1b: Import framework and configure module constants
│
├── Section 2 — Basic handle_error Usage
│   ├── Cell 2a: MEDIUM severity — non-fatal, pipeline continues
│   ├── Cell 2b: HIGH severity   — step failed, pipeline continues
│   └── Cell 2c: CRITICAL severity — pipeline halts, exception re-raised
│
├── Section 3 — retry_on_transient Decorator
│   ├── Cell 3a: Successful retry on 3rd attempt (IOError simulation)
│   └── Cell 3b: All retries exhausted, falls through to handle_error
│
├── Section 4 — Severity Routing Reference
│   └── Cell 4a: Loop over all four severity levels for visual comparison
│
├── Section 5 — Full Medallion Pipeline
│   ├── Cell 5a: Shared schema and table name constants
│   ├── Cell 5b: Bronze — raw CSV ingestion with retry + empty file check
│   ├── Cell 5c: Silver — cleansing, null threshold check, deduplication
│   ├── Cell 5d: Gold — aggregation + idempotent Delta MERGE
│   └── Cell 5e: Pipeline orchestration (ingest → transform → aggregate)
│
└── Section 6 — Querying the Error Log
    ├── Cell 6a: All errors for the current run_id
    ├── Cell 6b: CRITICAL errors in the last 24 hours
    └── Cell 6c: Error frequency by code with total records affected
```

---

## Section Walkthrough

### Section 1 — Setup

Two setup cells that must run before any other section.

**Cell 1a** — registers `notebookutils.nbResPath` on `sys.path` so Python can
resolve `fabric_error_codes` and `fabric_error_framework` as sibling modules.
A `try/except NameError` guard makes the cell safe to run outside of a Fabric
runtime (e.g. during local unit testing).

**Cell 1b** — imports the framework as `ef` and sets the three module-level
constants that are stamped on every error log record:

```python
import fabric_error_framework as ef

ef.NOTEBOOK_NAME    = notebookutils.runtime.context['notebookName']
ef.ENVIRONMENT      = 'dev'
ef.ERROR_TABLE_NAME = 'notebook_error_log'
```

The `RUN_ID` constant (`ef.RUN_ID`) is auto-generated at import time as an
8-character UUID prefix and is printed at startup for run correlation.

---

### Section 2 — Basic `handle_error` Usage

Three cells that demonstrate how the same `handle_error()` call behaves
differently depending on the severity of the `ErrorCode` passed.

#### Cell 2a — MEDIUM: non-fatal, pipeline continues

Simulates a data type cast failure (`TRN_2002`) on 142 affected records.
`raise_on_critical=False` is set explicitly, though it has no effect here
because `TRN_2002` is `MEDIUM`. The returned `FabricError` object is used
to print a summary.

```python
err = ef.handle_error(
    spark,
    ef.ErrorCode.TRN_2002,
    ex,
    cell_name='cast_sale_amount',
    record_count_affected=142,
    raise_on_critical=False,
)
```

#### Cell 2b — HIGH: step failed, pipeline continues

Simulates a row count check where the target drops below 95% of the source
(`VAL_3000`). The `record_count_affected` is calculated as the delta between
source and target counts (1,500 records). Pipeline continues.

#### Cell 2c — CRITICAL: pipeline halts

Simulates a Key Vault secret retrieval failure (`SEC_7000`). The default
`raise_on_critical=True` causes `handle_error` to log the error and then
re-raise the original `PermissionError`. An outer `try/except` catches the
re-raised exception to demonstrate the halted state without crashing the
demo cell.

---

### Section 3 — `retry_on_transient` Decorator

Two cells showing the decorator's success and failure paths.

#### Cell 3a — Successful retry on 3rd attempt

A function decorated with `@ef.retry_on_transient(max_retries=3, delay_seconds=1)`
raises `IOError` on the first two attempts and succeeds on the third. Output
shows the attempt counter incrementing and the final successful row count.

```python
@ef.retry_on_transient(max_retries=3, delay_seconds=1)
def read_source_file(path: str):
    ...
    if _attempt_counter < 3:
        raise IOError(f'Connection reset by peer (attempt {_attempt_counter})')
    return spark.range(100).toDF('id')
```

#### Cell 3b — All retries exhausted

A function raises `ConnectionError` on every attempt. After exhausting all
retries, the exception propagates to the outer `try/except`, which calls
`handle_error()` with `ef.ErrorCode.NET_6000` and `raise_on_critical=False`
(`NET_6000` is `HIGH`). Demonstrates the complete failure-to-logging path.

---

### Section 4 — Severity Routing Reference

A single reference cell that loops over one representative `ErrorCode` per
severity level and calls `handle_error()` for each, printing the code,
severity, and description side by side.

| Severity | Code used | `raise_on_critical` |
|---|---|---|
| CRITICAL | `SYS_8002` | `False` (demo only) |
| HIGH | `NET_6001` | `False` |
| MEDIUM | `TRN_2003` | `False` |
| LOW | `ALT_9000` | `False` |

> **Note:** All four are forced to `raise_on_critical=False` in this demo
> cell so the loop completes. In production, `CRITICAL` errors should always
> use the default (`True`).

---

### Section 5 — Full Medallion Pipeline

The centrepiece of the notebook. Four functions implement a complete
Bronze → Silver → Gold pipeline against a shared sales schema.

#### Shared Schema and Constants

```python
SALES_SCHEMA = StructType([
    StructField('order_id',    StringType(),    False),
    StructField('customer_id', StringType(),    True),
    StructField('product_id',  StringType(),    True),
    StructField('amount',      DoubleType(),    True),
    StructField('order_ts',    TimestampType(), True),
])

BRONZE_TABLE = 'bronze_sales_raw'
SILVER_TABLE = 'silver_sales_cleansed'
GOLD_TABLE   = 'gold_sales_summary'
```

#### `ingest_bronze()` — Bronze Layer

Decorated with `@ef.retry_on_transient(max_retries=3, delay_seconds=5)`.

- Reads raw CSV from ADLS with schema enforcement
- Validates the file is not empty (raises `SRC_1002` if empty)
- Stamps `ingested_at` metadata column
- Appends to `bronze_sales_raw` Delta table
- Falls back to `SRC_1000` for all other exceptions

#### `transform_silver()` — Silver Layer

- Reads from `bronze_sales_raw`
- Filters null and negative `amount` values; logs `TRN_2003` as a
  non-fatal warning if the null rate is between 2%–10%
- Raises `VAL_3000` (CRITICAL) if the null rate exceeds 10%
- Deduplicates on `order_id` using a `Window` function (keep latest
  `ingested_at`)
- Rounds `amount` to 2 decimal places and derives `order_date`
- Overwrites `silver_sales_cleansed`

#### `aggregate_gold()` — Gold Layer

- Reads from `silver_sales_cleansed`
- Aggregates by `order_date` and `product_id`:
  `total_sales`, `order_count`, `avg_order_value`
- Uses an idempotent Delta `MERGE` if the table already exists;
  falls back to an initial overwrite write otherwise
- Handles all exceptions with `SNK_4001` (Delta merge conflict, `HIGH`)

#### Pipeline Orchestration

```python
bronze_count = ingest_bronze(SOURCE_PATH)
transform_silver()
aggregate_gold()
```

The `ef.RUN_ID` is printed at the start and end of the run for correlation
with the error log.

---

### Section 6 — Querying the Error Log

Three ready-to-use PySpark queries against the `notebook_error_log` Delta
table written by the framework.

#### Query 1 — All errors for this run

Filters by `ef.RUN_ID` and selects the most useful columns for immediate
triage: `timestamp`, `error_code`, `severity`, `cell_name`,
`record_count_affected`, `message`.

#### Query 2 — CRITICAL errors in the last 24 hours

```python
df_errors.filter(
    (F.col('severity') == 'CRITICAL') &
    (F.col('timestamp') >= F.date_sub(F.current_date(), 1))
)
```

Useful as the basis for a scheduled alerting pipeline or Power BI
operational dashboard.

#### Query 3 — Error frequency by code

Groups by `error_code`, `severity`, and `environment` to show occurrence
counts, total records affected, and the last-seen timestamp. Use this query
to identify systemic issues and set alerting thresholds.

---

## Running the Notebook

1. Upload `fabric_error_codes.py` and `fabric_error_framework.py` to the
   **Notebook Resource Explorer** of the target workspace.
1. Attach a **default Lakehouse** to the notebook session.
1. Run **Section 1** cells in order (1a then 1b).
1. Run any subsequent section independently, or use **Run All** to execute
   the full notebook top to bottom.
1. After Section 5 completes, run Section 6 to inspect the error log.

> **Tip:** Change `ef.ENVIRONMENT = 'dev'` to `'prod'` when promoting the
> pattern to production pipelines. The environment value is stamped on every
> error record and is filterable in the error log queries.

---

## Expected Outputs

| Section | Expected console output |
|---|---|
| 1b | Framework loaded, notebook name, environment, run ID |
| 2a | `Handled [TRN-2002] severity=MEDIUM — continuing pipeline` |
| 2b | `Handled [VAL-3000] severity=HIGH` |
| 2c | `Pipeline halted as expected: Access denied to secret...` |
| 3a | Three attempt lines followed by `Read succeeded — 100 rows` |
| 3b | Two attempt lines followed by error log confirmation |
| 4a | Four-row severity routing table printed to console |
| 5e | Bronze / Silver / Gold progress lines + `Pipeline complete` |
| 6a–6c | Fabric `display()` tables in the notebook output |

---

## Delta Tables Created

Running this notebook end-to-end creates the following managed Delta tables
in the attached default Lakehouse:

| Table | Layer | Write mode | Description |
|---|---|---|---|
| `bronze_sales_raw` | Bronze | Append | Raw CSV rows with `ingested_at` metadata |
| `silver_sales_cleansed` | Silver | Overwrite | Cleansed, deduplicated sales records |
| `gold_sales_summary` | Gold | MERGE / Overwrite | Daily sales aggregates by product |
| `notebook_error_log` | Cross-cutting | Append | Structured error records from all `handle_error()` calls |

---

## Adapting for Your Pipeline

### Change the source path

Update `SOURCE_PATH` in the orchestration cell to point to your ADLS
container and file path:

```python
SOURCE_PATH = 'abfss://<container>@<account>.dfs.core.windows.net/<path>'
```

### Change the error table location

Override `ef.ERROR_TABLE_NAME` in the bootstrap cell to write errors to a
shared observability Lakehouse rather than the default one:

```python
ef.ERROR_TABLE_NAME = 'ops.notebook_error_log'
```

### Add custom error codes

Add new codes to `fabric_error_codes.py` without modifying the framework.
See the
[framework README](../fabric_error_framework.py)
for the category prefix and numeric range conventions.

### Wire in Teams alerting

Wrap `handle_error()` calls with your notification logic using the returned
`FabricError` object:

```python
error = ef.handle_error(spark, ef.ErrorCode.SNK_4000, ex,
                        cell_name='write_gold')
if error.severity == 'CRITICAL':
    post_teams_webhook(error.to_dict())
```

---

## Related Files

| File | Description |
|---|---|
| `fabric_error_codes.py` | Centralized error code registry and severity levels |
| `fabric_error_framework.py` | Framework logic — handlers, Delta logging, retry decorator |
| `fabric_error_framework_sample.ipynb` | This notebook |

---

*Kernel: Synapse PySpark — Microsoft Fabric Runtime 1.2+*
