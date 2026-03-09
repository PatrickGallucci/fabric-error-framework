# ============================================================================
# fabric_error_codes.py
#
# Centralized error severity levels and error code registry.
# Separated from fabric_error_framework.py so new codes can be added
# without touching the framework logic.
#
# Upload to Notebook Resource Explorer alongside fabric_error_framework.py.
# Do not import this file directly in notebooks — import fabric_error_framework
# which re-exports ErrorSeverity and ErrorCode for callers.
#
# Adding a new code:
#   1. Choose the correct category prefix (SRC, TRN, VAL, SNK, CFG, NET, SEC, SYS, ALT)
#   2. Assign the next sequential number in that category's range
#   3. Choose a severity from ErrorSeverity
#   4. Add the tuple below — no other files need to change
# ============================================================================

from enum import Enum


class ErrorSeverity:
    """
    Severity levels for error classification.

    CRITICAL  Pipeline must stop; requires immediate attention.
    HIGH      Step failed; pipeline may continue with degraded results.
    MEDIUM    Non-fatal issue; data quality warning.
    LOW       Informational; logged but no action needed.
    """
    CRITICAL = "CRITICAL"
    HIGH     = "HIGH"
    MEDIUM   = "MEDIUM"
    LOW      = "LOW"


class ErrorCode(Enum):
    """
    Centralized error code registry.
    Format: CATEGORY_NNNN

    Each member is a 3-tuple: (code_string, description, severity)

    Categories and ranges:
        SRC  = Source / Ingestion errors       (1000-1999)
        TRN  = Transformation errors           (2000-2999)
        VAL  = Validation / Data Quality       (3000-3999)
        SNK  = Sink / Write errors             (4000-4999)
        CFG  = Configuration errors            (5000-5999)
        NET  = Network / Connectivity          (6000-6999)
        SEC  = Security / Auth errors          (7000-7999)
        SYS  = System / Infrastructure         (8000-8999)
        ALT  = Alerting errors (meta)          (9000-9999)
    """

    # -----------------------------------------------------------------------
    # SRC — Source / Ingestion  (1000-1999)
    # -----------------------------------------------------------------------
    SRC_1000 = ("SRC-1000", "Source file not found",                 ErrorSeverity.CRITICAL)
    SRC_1001 = ("SRC-1001", "Source file schema mismatch",           ErrorSeverity.HIGH)
    SRC_1002 = ("SRC-1002", "Source file is empty",                  ErrorSeverity.HIGH)
    SRC_1003 = ("SRC-1003", "Source read timeout",                   ErrorSeverity.HIGH)
    SRC_1004 = ("SRC-1004", "Unsupported source file format",        ErrorSeverity.MEDIUM)

    # -----------------------------------------------------------------------
    # TRN — Transformation  (2000-2999)
    # -----------------------------------------------------------------------
    TRN_2000 = ("TRN-2000", "Transformation failed - general",       ErrorSeverity.CRITICAL)
    TRN_2001 = ("TRN-2001", "Column not found in DataFrame",         ErrorSeverity.HIGH)
    TRN_2002 = ("TRN-2002", "Data type cast failure",                ErrorSeverity.MEDIUM)
    TRN_2003 = ("TRN-2003", "Null values exceed threshold",          ErrorSeverity.MEDIUM)

    # -----------------------------------------------------------------------
    # VAL — Validation / Data Quality  (3000-3999)
    # -----------------------------------------------------------------------
    VAL_3000 = ("VAL-3000", "Row count validation failed",           ErrorSeverity.HIGH)
    VAL_3001 = ("VAL-3001", "Duplicate primary keys detected",       ErrorSeverity.HIGH)
    VAL_3002 = ("VAL-3002", "Referential integrity check failed",    ErrorSeverity.MEDIUM)
    VAL_3003 = ("VAL-3003", "Business rule validation failed",       ErrorSeverity.MEDIUM)

    # -----------------------------------------------------------------------
    # SNK — Sink / Write  (4000-4999)
    # -----------------------------------------------------------------------
    SNK_4000 = ("SNK-4000", "Lakehouse write failed",                ErrorSeverity.CRITICAL)
    SNK_4001 = ("SNK-4001", "Delta merge conflict",                  ErrorSeverity.HIGH)
    SNK_4002 = ("SNK-4002", "Partition overwrite failed",            ErrorSeverity.HIGH)

    # -----------------------------------------------------------------------
    # CFG — Configuration  (5000-5999)
    # -----------------------------------------------------------------------
    CFG_5000 = ("CFG-5000", "Missing required configuration",        ErrorSeverity.CRITICAL)
    CFG_5001 = ("CFG-5001", "Invalid parameter value",               ErrorSeverity.HIGH)

    # -----------------------------------------------------------------------
    # NET — Network / Connectivity  (6000-6999)
    # -----------------------------------------------------------------------
    NET_6000 = ("NET-6000", "External API unreachable",              ErrorSeverity.HIGH)
    NET_6001 = ("NET-6001", "Connection timeout",                    ErrorSeverity.HIGH)

    # -----------------------------------------------------------------------
    # SEC — Security / Auth  (7000-7999)
    # -----------------------------------------------------------------------
    SEC_7000 = ("SEC-7000", "Key Vault secret retrieval failed",     ErrorSeverity.CRITICAL)
    SEC_7001 = ("SEC-7001", "Insufficient permissions",              ErrorSeverity.CRITICAL)

    # -----------------------------------------------------------------------
    # SYS — System / Infrastructure  (8000-8999)
    # -----------------------------------------------------------------------
    SYS_8000 = ("SYS-8000", "Out of memory - executor",             ErrorSeverity.CRITICAL)
    SYS_8001 = ("SYS-8001", "Spark session lost",                   ErrorSeverity.CRITICAL)
    SYS_8002 = ("SYS-8002", "Unexpected system error",              ErrorSeverity.CRITICAL)

    # -----------------------------------------------------------------------
    # ALT — Alerting meta-errors  (9000-9999)
    # -----------------------------------------------------------------------
    ALT_9000 = ("ALT-9000", "Teams webhook delivery failed",        ErrorSeverity.LOW)

    def __init__(self, code: str, description: str, severity: str):
        self.code        = code
        self.description = description
        self.severity    = severity