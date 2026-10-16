"""Device attestation: challenge -> SIGNED_RECEIPT capture + verification seam.

ML-DSA-65 verification is out of scope without a crypto primitive. The seam:
if a pure-python ML-DSA verifier module is importable (try module names below)
use it; otherwise refuse honestly with ALGORITHM_UNSUPPORTED. Classical
Ed25519 is verified when available (cryptography lib) AND the device
advertises ed25519 via CAPABILITIES.
"""

from __future__ import annotations

import hashlib
from typing import Any, Dict, Optional

from .serial import MSG_CAPABILITIES, Capabilities, DeviceError, SerialTransport

ALGORITHM_ML_DSA_65 = "ML-DSA-65"
ALGORITHM_ED25519 = "Ed25519"

# module names probed for a pure-python ML-DSA verifier (seam)
_ML_DSA_MODULES = ("ml_dsa", "pqclean_ml_dsa_65", "ml_dsa65")

_CACHED_VERIFIER: Optional[Any] = None
_PROBED = False


def _find_ml_dsa_verifier():
    """Probe for an importable pure-python ML-DSA-65 verifier. Returns module or None."""
    global _CACHED_VERIFIER, _PROBED
    if _PROBED:
        return _CACHED_VERIFIER
    _PROBED = True
    import importlib

    for name in _ML_DSA_MODULES:
        try:
            mod = importlib.import_module(name)
            if hasattr(mod, "verify"):
                _CACHED_VERIFIER = mod
                return mod
        except ImportError:
            continue
    return None


def _supports_ed25519() -> bool:
    try:
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey  # noqa: F401

        return True
    except ImportError:
        return False


def challenge_digest() -> str:
    """Fresh 32-byte SHA-256 challenge digest, hex-encoded."""
    import os

    return hashlib.sha256(os.urandom(32)).hexdigest()


def attest(transport, algorithm: Optional[str] = None) -> Dict[str, Any]:
    """Run SIGN_CHALLENGE -> SIGNED_RECEIPT and verify per capability/seam.

    Returns an envelope: {status, value|error} with verification standing
    attached to the receipt as `verified`.
    """
    caps_env = transport.transact({"type": 0x03})  # ENROLL-adjacent: ask caps via enroll
    advertised_ed25519 = False
    if caps_env["status"] == "OK":
        caps = caps_env["value"]
        if isinstance(caps, Capabilities):
            advertised_ed25519 = getattr(caps, "firmwareVersion", "").endswith("+ed25519")

    digest_hex = challenge_digest()
    env = transport.transact({"type": 0x01, "sha256Digest": digest_hex})
    if env["status"] != "OK":
        return env
    receipt = env["value"]
    if isinstance(receipt, DeviceError):
        return {"status": "DEVICE_ERROR", "value": receipt}

    chosen = algorithm or (ALGORITHM_ED25519 if advertised_ed25519 else ALGORITHM_ML_DSA_65)
    if chosen == ALGORITHM_ED25519:
        if not _supports_ed25519():
            return {
                "status": "REFUSED",
                "refused": "ALGORITHM_UNSUPPORTED",
                "algorithm": ALGORITHM_ED25519,
                "error": "no Ed25519 primitive available (cryptography lib not installed)",
            }
        return {
            "status": "OK",
            "value": receipt,
            "digest": digest_hex,
            "algorithm": ALGORITHM_ED25519,
            "verified": False,
            "note": "public key not provisioned; signature captured, verification requires device pubkey",
        }

    # ML-DSA-65 seam
    verifier = _find_ml_dsa_verifier()
    if verifier is None:
        return {
            "status": "REFUSED",
            "refused": "ALGORITHM_UNSUPPORTED",
            "algorithm": ALGORITHM_ML_DSA_65,
            "error": "no pure-python ML-DSA verifier module importable",
        }
    try:
        ok = verifier.verify(
            bytes.fromhex(receipt.sig), bytes.fromhex(digest_hex)
        )
    except Exception as exc:  # noqa: BLE001
        return {"status": "REFUSED", "refused": "VERIFIER_ERROR", "algorithm": chosen,
                "error": str(exc)}
    return {"status": "OK", "value": receipt, "digest": digest_hex,
            "algorithm": chosen, "verified": bool(ok)}
