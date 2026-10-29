# KD-122 close witness — blob CORS in-browser round trip (coordinator, 2026-10-20)

**Standing:** PASS
Context: solo

Substrate restarted (pid 28225) with the KD-122 shim (`raw_blob_put?` raw-body
exemption, `# KD-COVERS: KD-122` in lib/smalt/egress_router.ex) plus the ACAO
echo on actual (non-OPTIONS) blob responses from matching origins. CORS rule
stored via the real Set Blob Service Properties face:

```
PUT http://127.0.0.1:8443/popcorn?restype=service&comp=properties → 202
OPTIONS /popcorn/c/r.txt (Origin+ACRM) → 200
```

In-browser WASM BEAM witness (headless Chromium, wasm bundle cooked from the
post-fix tree), verbatim SMOKE_RECEIPT, exit 0:

```
SMOKE_RECEIPT: cosmos_sql=OK(where+order+limit correct); sb_rule=OK(sql filter matched); registry=OK(admitted-type + api-version checks pass); blob=OK(popcorn/l3rb1792544601128/receipt.txt:61-roundtrip); live=OK(endpoints,tenants,sts,subscriptions=1); matrix=OK(popcorn/smoke:1-matched)
EXIT=0
```

The `blob=OK(...:61-roundtrip)` is the browser leg's real PUT/GET byte-equality
round trip against a substrate carrying the stored rule — KD-122's exact close
condition. Witness postdates the shim (18:02:37 shim vs 18:03+ witness).
