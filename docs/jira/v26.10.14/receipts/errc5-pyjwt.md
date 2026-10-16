# Receipt: errc5-pyjwt — ERRC lane 5 (Reduce)

- **Date**: 2026-10-15
- **Subject**: `/Users/sac/smalt/smalt-cli/smalt_cli/gateway/sts.py` — adopt `pyjwt` for HS256 sign/verify, replacing hand-rolled `hmac/hashlib/base64` JWT.
- **Standing**: ALIVE (all tests pass unchanged; cross-checks witnessed)

## Change

`LocalSTS.issue()` now signs via `jwt.encode(claims, key, algorithm="HS256", headers={"typ": "JWT"})`; `LocalSTS.decode()` verifies via `jwt.decode(..., algorithms=["HS256"], options={verify_aud/iss/exp/nbf: False})` plus `jwt.get_unverified_header`. PyJWT exception classes are translated to the exact `ValueError` contract (`"signature verification failed"`, `"malformed token: expected 3 dot-separated segments"`, `"token expired"`, `"token not yet valid"`).

Key preservation details:

- Signature is ALWAYS verified regardless of `verify=` (matches old semantics; `verify` only gates exp/nbf, which remain hand-checked to keep the exact `now >= exp` / `now < nbf` boundary and messages).
- `jwt.InvalidSignatureError` is caught **before** `jwt.DecodeError` (it subclasses it) — first run got this backwards and mis-classified a bad-signature token as malformed; fixed and re-witnessed.
- exp/nbf/aud/iss verification is done locally because PyJWT defaults (`now > exp`, strict aud/iss) differ from the pinned contract.

## Dependencies

- `pyjwt==2.15.1` installed into `smalt-cli/.venv` (py3.14) and `smalt-cli/.venv-cli` (py3.13). No requirements file pins found for these venvs (pyproject dev extra = pytest only) — disclose: pyjwt is NOT yet recorded in any lock/manifest.

## Verification (real output)

- Full suite: `cd smalt-cli && .venv/bin/python -m pytest -q` → **101 passed, 6 warnings in 7.74s** (test_gateway.py's 14 tests pass unchanged; zero test edits required).
- Gateway suite in both venvs: `.venv` → 14 passed; `.venv-cli` → 14 passed.
- Cross-check (one-time, `/tmp/errc5_xcheck.py`): pyjwt-minted token verified via the OLD manual hmac/base64 path in both venvs — signature, header `{"alg":"HS256","typ":"JWT"}`, claims (oid/tid/exp/nbf), and refusal messages all match.
- TS-side cross-check (Node crypto, `test/sdk-full/auth.probe.mjs` pattern, `/tmp/errc5_ts_check.mjs`): Node `createHmac("sha256").digest("base64url")` over header.payload === signature segment — **OK**, 3 segments, base64url, header `{alg: HS256, typ: JWT}`. Envelope shape is unchanged for the TS consumer.
- Loc delta: `sts.py` 113 → 101 lines (+24/−36).

## Divergences (disclosed)

1. **New stderr noise**: PyJWT 2.15 emits `InsecureKeyLengthWarning` for HMAC keys < 32 bytes (default/test secrets are 11–22 bytes). Warnings, not failures — suite stays green. If `-W error` adoption happens later, either lengthen the dev secrets or filter this warning explicitly.
2. PyJWT is not pinned in any dependency manifest (see Dependencies).
3. Test files: unchanged (the "minimal test updates" clause was not needed).

No commits made.
