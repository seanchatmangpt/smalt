# Receipt — R163 (probe api-version parity, JS + PY)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 wave)
- **Standing:** PARTIAL_ALIVE (static parity verified; live probes not re-run)
- **Date:** 2026-10-16 (W7 docs lane)

## Subject

Session-listed as "probe api-version parity, JS+PY". The api-version pinning in
both probe families is verified statically below; the live probes need a booted
substrate (b6 also needs its venv) and were not re-run by this lane.

## Verification (2026-10-16, W7 docs lane, unedited output)

```
$ grep -n "api-version\|api_version" scripts/bench/b6_lro_sdk.py | head -5
13:  a  100 concurrent generic NSG PUTs (api-version 2021-04-01) via
193:            f"/providers/{provider}/{rtype}/{name}?api-version={API}",
202:            CRED, SUB, base_url=BASE, api_version=API,
458:        CRED, SUB, base_url=BASE, api_version=API,
$ grep -rn "api-version" test/data_plane/sdk_probe.mjs
(no output — JS probe drives Cosmos via the SDK, which pins its own
 x-ms-version; no literal api-version query in the JS probe file)
```

Standing PARTIAL_ALIVE: PY-side pinning witnessed; JS-side parity rides the SDK's
own version header, so a literal-parity grep is not the right witness for that
leg — recorded rather than forced.

## W10 re-run (2026-10-16, docs lane W10)

Live probe legs attempted; both loud-skip on this machine (recorded, not faked):

```
$ node test/data_plane/sdk_probe.mjs
[sdk_probe] set SMALT_SDK_ROOT
JS_EXIT=3
$ .venv/bin/python -c "import azure.monitor.query"
zsh: no such file or directory: ./.venv/bin/python
```

The substrate is UP (9443/9444/5672/5673, pid 882) but the JS probe demands a
local SDK checkout root and the PY probe's venv is absent from the repo root,
so live parity remains un-witnessed by this lane. Static PY pinning re-verified:

```
$ grep -n "api-version" scripts/bench/b6_lro_sdk.py | head -3
13:  a  100 concurrent generic NSG PUTs (api-version 2021-04-01) via
193:            f"/providers/{provider}/{rtype}/{name}?api-version={API}")
572:                       f"/subscriptions/{SUB}/resourceGroups/{RG}?api-version={API}")
```

Standing: PARTIAL_ALIVE (static parity witnessed; live probes loud-skip).
