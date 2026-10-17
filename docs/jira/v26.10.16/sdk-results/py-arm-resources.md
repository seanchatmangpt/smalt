# SDK lane PY-1 — real azure-mgmt-resources (Python) against the smalt ARM plane

- **Date**: 2026-10-16 · **Lane**: lane333
- **Repo/SHA**: `/Users/sac/smalt` @ `main` `fd9cfea`
- **SDK**: `azure-mgmt-resources` (test/sdk-python/.venv-arm)
- **Runtime**: Python 3.14 venv, macOS arm64 (Darwin 25.2.0)
- **Substrate**: lane333 persistent substrate, anonymous auth, ARM 39796 / ARM-TLS twin 39800, `MIX_BUILD_ROOT=_build-lane333`, under `flock /tmp/smalt-substrate.lock` (fd closed)
- **Probe**: `test/sdk-python/py_arm_resources.py` with `SMALT_ARM_BASE=https://127.0.0.1:39800 NODE_TLS_REJECT_UNAUTHORIZED=0`
- **Verdict**: 12/12 probes PASS, exit 0

## executed commands (receipt)

```bash
SMALT_ARM_BASE=https://127.0.0.1:39800 NODE_TLS_REJECT_UNAUTHORIZED=0 \
  test/sdk-python/.venv-arm/bin/python test/sdk-python/py_arm_resources.py   # exit 0
```

## results (2026-10-16, raw probe output)

```
PASS P0 metadata/endpoints 200 :: status=200
PASS P0b resourceManagerEndpoint present :: http://localhost:9443/
PASS P1 SDK list subscriptions >=1 :: count=1 first=00000000-...
PASS P2a RG create :: name=py-sdk-rg loc=smaltlocal
PASS P2b RG list contains rg :: count=1
PASS P2c RG get :: name=py-sdk-rg
PASS P3 LRO storageAccount create :: name=pysa001
PASS P3b wire GET storageAccount 200 :: status=200
PASS P3c storageAccount delete :: poller succeeded
PASS P4 bad api-version -> 400 :: status=400
PASS P4b error names 2021-04-01 :: InvalidApiVersionParameter
PASS P5 RG delete -> 404 :: status=404
=== 12/12 probes passed ===
```

## notes

- LRO create/delete pollers, metadata endpoints, api-version guards all green
  against the private-port ARM/TLS twin.
