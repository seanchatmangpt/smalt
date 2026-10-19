"""Typed error classification — the lane's ONLY except-table.

Every `except` in the suite names a row from this table; bare
`except Exception` is forbidden. expect_http_error is a context manager that
admits exactly the typed (status, code) row and lets everything else raise.
"""
import contextlib
import json

from azure.core.exceptions import (
    HttpResponseError,
    ResourceExistsError,
    ResourceNotFoundError,
)


def error_code(exc):
    """Extract the ARM error.code from an azure-core exception."""
    err = getattr(exc, "error", None)
    code = getattr(err, "code", None) if err is not None else None
    if code:
        return code
    resp = getattr(exc, "response", None)
    if resp is not None:
        try:
            return json.loads(resp.text()).get("error", {}).get("code")
        except (ValueError, TypeError):
            return None
    return None


@contextlib.contextmanager
def expect_http_error(status, code=None):
    """Admit ONLY HttpResponseError(status[, code]); anything else propagates.
    A no-raise block is a FAIL (the negative must actually fire)."""
    try:
        yield
    except HttpResponseError as e:
        assert e.status_code == status, (
            f"expected HTTP {status}, got {e.status_code}: {str(e)[:200]}"
        )
        if code is not None:
            got = error_code(e)
            assert got == code, f"expected error.code {code!r}, got {got!r}: {str(e)[:240]}"
    else:
        raise AssertionError(
            f"expected HttpResponseError {status}/{code} — nothing raised (no-raise negative is a FAIL)"
        )


# Native-exception table (typed rows; suite code imports these names directly).
EXCEPTION_TABLE = {
    "arm_not_found": ResourceNotFoundError,
    "arm_exists": ResourceExistsError,
    "arm_http": HttpResponseError,
}


def sb_reason(exc):
    from azure.servicebus.exceptions import ServiceBusError

    if not isinstance(exc, ServiceBusError):
        raise AssertionError(f"expected ServiceBusError, got {type(exc).__name__}: {exc}")
    return getattr(exc, "reason", None)
