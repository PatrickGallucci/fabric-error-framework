# ============================================================================
# fabric_error_framework.py
#
# Unified error handling framework for Microsoft Fabric Notebooks.
# Upload to the Notebook Resource Explorer alongside fabric_error_codes.py.
#
# Import pattern (add to the first cell of every notebook):
#
#   import sys
#   sys.path.insert(0, notebookutils.nbResPath)
#
#   import fabric_error_framework as ef
#   ef.NOTEBOOK_NAME = notebookutils.runtime.context["notebookName"]
#   ef.ENVIRONMENT   = "prod"
#
# Usage:
#   try:
#       df = spark.read.format("delta").load("abfss://...")
#   except Exception as ex:
#       ef.handle_error(spark, ef.ErrorCode.SRC_1000, ex, cell_name="ingest_raw")
# ============================================================================

# ============================================================================
# Standard Library Imports
# ============================================================================
import logging
import sys
import time
import traceback
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from functools import wraps

# ============================================================================
# Ensure the Notebook Resource folder is on sys.path so fabric_error_codes
# can be resolved whether this file is imported interactively or via pipeline.
# notebookutils.nbResPath resolves to the resource folder at runtime; the
# fallback keeps unit tests runnable outside of Fabric.
# ============================================================================
try:
    _resource_path = notebookutils.nbResPath  # type: ignore[name-defined]
    if _resource_path not in sys.path:
        sys.path.insert(0, _resource_path)
except NameError:
    pass  # Running outside Fabric (e.g. pytest); caller manages sys.path

# ============================================================================
# Import error registry — the only cross-file dependency
# ============================================================================
from fabric_error_codes import ErrorCode, ErrorSeverity  # noqa: E402

# Re-export so callers only need to import this one module
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

# ============================================================================
# PySpark Imports
# ============================================================================
from pyspark.sql import SparkSession
from pyspark.sql.types import (
    IntegerType,
    StringType,
    StructField,
    StructType,
)

# ============================================================================
# Constants  — override at the module level in the calling notebook
# ============================================================================
NOTEBOOK_NAME:       str = "fabric_notebook"
ENVIRONMENT:         str = "dev"
ERROR_TABLE_NAME:    str = "notebook_error_log"
MAX_RETRIES:         int = 3
RETRY_DELAY_SECONDS: int = 5

RUN_ID: str = str(uuid.uuid4())[:8]

# ============================================================================
# Logging Setup  — must be defined before any function that references py_logger
# ============================================================================

py_logger = logging.getLogger(NOTEBOOK_NAME)
py_logger.setLevel(logging.DEBUG)

if not py_logger.handlers:
    _handler = logging.StreamHandler()
    _handler.setFormatter(
        logging.Formatter(
            "%(asctime)s | %(name)s | %(levelname)s | %(message)s",
            datefmt="%Y-%m-%dT%H:%M:%S",
        )
    )
    py_logger.addHandler(_handler)


def get_spark_logger(spark_session: SparkSession):
    """
    Retrieve log4j logger from the active Spark context.
    Best practice per Microsoft Fabric docs — use log4j over print().
    Returns None if unavailable (e.g. unit-test context).
    """
    try:
        log4j = spark_session._jvm.org.apache.log4j
        return log4j.LogManager.getLogger(NOTEBOOK_NAME)
    except Exception:
        py_logger.warning("log4j logger unavailable, falling back to Python logging only")
        return None


# ============================================================================
# FabricError — structured error object for logging and alerting
# ============================================================================

@dataclass
class FabricError:
    """Structured error object for logging and alerting."""
    error_code:            ErrorCode
    message:               str
    notebook_name:         str
    environment:           str
    cell_name:             str = ""
    stack_trace:           str = ""
    record_count_affected: int = 0
    timestamp:             str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    run_id:                str = ""

    @property
    def severity(self) -> str:
        return self.error_code.severity

    @property
    def code(self) -> str:
        return self.error_code.code

    def to_dict(self) -> dict:
        return {
            "error_code":             self.code,
            "error_description":      self.error_code.description,
            "severity":               self.severity,
            "message":                self.message,
            "notebook_name":          self.notebook_name,
            "environment":            self.environment,
            "cell_name":              self.cell_name,
            "stack_trace":            self.stack_trace[:4000],  # Truncate for storage
            "record_count_affected":  self.record_count_affected,
            "timestamp":              self.timestamp,
            "run_id":                 self.run_id,
        }


# ============================================================================
# Error Logging — Delta table schema and writer
# ============================================================================

def get_error_log_schema() -> StructType:
    """Schema for the notebook_error_log Delta table."""
    return StructType([
        StructField("error_code",            StringType(),  False),
        StructField("error_description",     StringType(),  True),
        StructField("severity",              StringType(),  False),
        StructField("message",               StringType(),  True),
        StructField("notebook_name",         StringType(),  True),
        StructField("environment",           StringType(),  True),
        StructField("cell_name",             StringType(),  True),
        StructField("stack_trace",           StringType(),  True),
        StructField("record_count_affected", IntegerType(), True),
        StructField("timestamp",             StringType(),  True),
        StructField("run_id",                StringType(),  True),
    ])


def log_error_to_lakehouse(spark: SparkSession, error: FabricError) -> None:
    """
    Append a structured error record to the Lakehouse Delta error log table.
    Creates the table if it does not exist.
    """
    try:
        error_df = spark.createDataFrame([error.to_dict()], schema=get_error_log_schema())

        (
            error_df.write
            .format("delta")
            .mode("append")
            .option("mergeSchema", "true")
            .saveAsTable(ERROR_TABLE_NAME)
        )

        py_logger.info(f"Error {error.code} logged to {ERROR_TABLE_NAME}")

    except Exception as log_ex:
        # Do not let logging failures cascade and crash the pipeline.
        py_logger.error(f"Failed to log error to Lakehouse: {log_ex}")


# ============================================================================
# Unified Error Handler
# ============================================================================

def handle_error(
    spark: SparkSession,
    error_code: ErrorCode,
    exception: Exception,
    notebook_name: str = NOTEBOOK_NAME,
    environment: str = ENVIRONMENT,
    cell_name: str = "",
    record_count_affected: int = 0,
    raise_on_critical: bool = True,
) -> FabricError:
    """
    Central error handler. Logs to console, Lakehouse, and raises on CRITICAL.

    Args:
        spark:                  Active SparkSession.
        error_code:             ErrorCode enum value from fabric_error_codes.
        exception:              The caught exception.
        notebook_name:          Calling notebook name (default: module constant).
        environment:            Deployment environment, e.g. "dev" / "prod".
        cell_name:              Descriptive name of the cell or pipeline step.
        record_count_affected:  Number of records impacted (if known).
        raise_on_critical:      Re-raises the exception when severity is CRITICAL.

    Returns:
        FabricError for caller inspection or downstream alerting.
    """
    tb = traceback.format_exc()

    fabric_error = FabricError(
        error_code=error_code,
        message=str(exception),
        notebook_name=notebook_name,
        environment=environment,
        cell_name=cell_name,
        stack_trace=tb,
        record_count_affected=record_count_affected,
        run_id=RUN_ID,
    )

    log_msg = (
        f"[{fabric_error.code}] [{fabric_error.severity}] "
        f"{fabric_error.error_code.description} - {fabric_error.message}"
    )

    # 1. Python driver logger
    py_logger.error(log_msg)

    # 2. Spark log4j logger (driver + executors)
    spark_log = get_spark_logger(spark)
    if spark_log:
        spark_log.error(log_msg)

    # 3. Persist structured record to Lakehouse Delta table
    log_error_to_lakehouse(spark, fabric_error)

    # 4. Re-raise CRITICAL errors to halt the pipeline
    if raise_on_critical and fabric_error.severity == ErrorSeverity.CRITICAL:
        py_logger.critical("CRITICAL error - raising exception to halt pipeline execution")
        raise exception

    return fabric_error


# ============================================================================
# Retry Decorator for Transient Failures
# ============================================================================

def retry_on_transient(
    max_retries: int = MAX_RETRIES,
    delay_seconds: int = RETRY_DELAY_SECONDS,
    transient_exceptions: tuple = (ConnectionError, TimeoutError, IOError),
):
    """
    Decorator that retries a function on transient exceptions with linear backoff.

    Usage:
        @ef.retry_on_transient(max_retries=3, delay_seconds=5)
        def read_source_data(spark):
            ...
    """
    def decorator(func):
        @wraps(func)
        def wrapper(*args, **kwargs):
            last_exception = None
            for attempt in range(1, max_retries + 1):
                try:
                    return func(*args, **kwargs)
                except transient_exceptions as te:
                    last_exception = te
                    wait = delay_seconds * attempt  # Linear backoff
                    py_logger.warning(
                        f"Attempt {attempt}/{max_retries} failed for "
                        f"'{func.__name__}': {te}. Retrying in {wait}s..."
                    )
                    time.sleep(wait)
            # All retries exhausted — propagate the last exception
            raise last_exception
        return wrapper
    return decorator