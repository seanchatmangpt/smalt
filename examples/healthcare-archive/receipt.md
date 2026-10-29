# Receipt — lane ex3: healthcare-archive example

Standing: **ALIVE** (15/17 GREEN, 2 typed XFAIL, 0 FAIL — exit 0; two
consecutive back-to-back runs green: `/tmp/ex3-runA.log`, `/tmp/ex3-runB.log`)

Date: 2026-10-19
Subject: `/Users/sac/smalt/examples/healthcare-archive/` (index.ts, run.sh,
README.md); no files outside the lane dir touched. Substrate: lane-private
v-block `v6` (enforce, ports 39760-39765) via scripts/substrate-ctl;
reuses a healthy shared substrate when present.

Command: `cd /Users/sac/smalt/examples/healthcare-archive && ./run.sh`
Exit code: **0**

Checks summary:
- Blob WORM leg (7 GREEN): container create, upload, snapshot mint
  (`x-ms-snapshot`), legal hold on, overwrite-under-hold typed
  `409 ContainerLocked`, delete-under-hold `409 ContainerLocked`,
  snapshot read-back after base tamper returns the exact frozen bytes
  (KD-60 `?sharesnapshot` read arm), 30-day immutability policy PUT/GET.
- KV leg (2 GREEN + 2 XFAIL): secret set/delete GREEN; `/deletedsecrets`
  plane NOT landed on this substrate build — typed XFAIL
  (skip-until-deleted-keys-landed, KD-102), recover arm not run. Loud,
  never a fake pass.
- Ledger leg (4 GREEN): 3 appends 201, duplicate contents typed
  `409 LedgerItemAlreadyExists`, Merkle chain re-verified CLIENT-SIDE
  (data_hash = sha256(sorted-key JSON of contents);
  merkle_root = sha256(prev_hash <> data_hash) as HEX-STRING concat —
  matching lib/smalt/security/ledger_writer.ex hash/1), prev_hash linkage;
  latest + by-id reads 200.
- Ledger entries are run-stamped: the substrate's real duplicate detection
  refused an earlier run's identical contents with 409 — the WORM is real.

Deviations / honest notes:
- Official-SDK note: @azure/storage-blob 12.34 hard-refuses bearer-over-http
  (RestError witnessed), TLS twin serves no blob routes (404 RouteNotFound),
  SharedKey not admitted in enforce mode — blob leg rides real-wire REST
  (newcaps/py-validated shapes). KV/ledger SDKs not vendored — raw REST.
- Substrate flake witnessed mid-lane: shared substrate on default ports went
  down/up across lanes; one run against a degraded reused substrate got a
  500 on KV DELETE /secrets (not reproducible on a fresh boot — runA/runB).
- 2 XFAIL are typed in-flight surfaces, exit stays 0 with the loud NOTE.

Embedded final run output (runA, exit 0):

```
    [run.sh] lane-private substrate block=v6 pid=39742 ports=39760 39761 39762 39763 39764 39765
    (node:41139) [MODULE_TYPELESS_PACKAGE_JSON] Warning: Module type of file:///Users/sac/smalt/examples/healthcare-archive/index.ts is not specified and it doesn't parse as CommonJS.
    Reparsing as ES module because module syntax was detected. This incurs a performance overhead.
    To eliminate this warning, add "type": "module" to /Users/sac/smalt/package.json.
    (Use `node --trace-warnings ...` to show where the warning was created)
    [GREEN] blob-container-create — container ex3-health-mvg7sbac-records created (201)
    [GREEN] blob-upload — patient export uploaded (93 bytes BlockBlob)
    [GREEN] snapshot-create — snapshot 2026-10-20T05:00:00.568647Z frozen (x-ms-snapshot minted)
    [GREEN] worm-legalhold-on — legal hold set (comp=legalhold x-ms-legal-hold=true)
    [GREEN] worm-overwrite-refused — overwrite under hold -> 409 {"error":{"code":"ContainerLocked","message":"Blob modification refused: container has an active legal hold (ContainerLo
    [GREEN] worm-delete-refused — delete under hold -> 409 {"error":{"code":"ContainerLocked","message":"Blob modification refused: container has an active legal hold (ContainerLo
    [GREEN] snapshot-immutable — GET ?sharesnapshot -> 200, body={"patientId":"P-0001","mrn":"MRN-8842","exportedAt":"2026-10-20T05:00:00.397Z","records":42}
     == frozen V1 bytes (base tamper invisible)"
    [GREEN] worm-immutability-policy — PUT=200 GET=200 policy={"locked":false,"period_days":30,"until":"2026-11-19T05:00:00.668Z"}
    [GREEN] kv-secret-set — PUT /secrets -> 200
    [GREEN] kv-secret-delete — DELETE /secrets -> 200
    [XFAIL] kv-deleted-secret-visible — GET /deletedsecrets -> 404: deleted-secrets plane not landed on this substrate build — typed XFAIL, skip-until-deleted-keys-landed (KD-102)
    [XFAIL] kv-secret-recover — recover arm not run: depends on the deleted-secrets plane
    [GREEN] ledger-append-201 — 3 appends admitted (first tx 1.1)
    [GREEN] ledger-duplicate-409 — re-append of identical contents -> 409 {"error":{"code":"LedgerItemAlreadyExists","message":"Ledger item already exists."}}
    [GREEN] ledger-merkle-chain-verified — 3 receipts: data_hash, merkle_root, linkage recomputed client-side
    [GREEN] ledger-latest-tx — GET /app/transactions/latest -> 200 tx=3.1
    [GREEN] ledger-tx-by-id — GET /app/transactions/1.1 -> 200
    
    == healthcare-archive: 15/17 GREEN, 2 XFAIL, 0 FAIL ==
      [GREEN] blob-container-create — container ex3-health-mvg7sbac-records created (201)
      [GREEN] blob-upload — patient export uploaded (93 bytes BlockBlob)
      [GREEN] snapshot-create — snapshot 2026-10-20T05:00:00.568647Z frozen (x-ms-snapshot minted)
      [GREEN] worm-legalhold-on — legal hold set (comp=legalhold x-ms-legal-hold=true)
      [GREEN] worm-overwrite-refused — overwrite under hold -> 409 {"error":{"code":"ContainerLocked","message":"Blob modification refused: container has an active legal hold (ContainerLo
      [GREEN] worm-delete-refused — delete under hold -> 409 {"error":{"code":"ContainerLocked","message":"Blob modification refused: container has an active legal hold (ContainerLo
      [GREEN] snapshot-immutable — GET ?sharesnapshot -> 200, body={"patientId":"P-0001","mrn":"MRN-8842","exportedAt":"2026-10-20T05:00:00.397Z","records":42}
     == frozen V1 bytes (base tamper invisible)"
      [GREEN] worm-immutability-policy — PUT=200 GET=200 policy={"locked":false,"period_days":30,"until":"2026-11-19T05:00:00.668Z"}
      [GREEN] kv-secret-set — PUT /secrets -> 200
      [GREEN] kv-secret-delete — DELETE /secrets -> 200
      [XFAIL] kv-deleted-secret-visible — GET /deletedsecrets -> 404: deleted-secrets plane not landed on this substrate build — typed XFAIL, skip-until-deleted-keys-landed (KD-102)
      [XFAIL] kv-secret-recover — recover arm not run: depends on the deleted-secrets plane
      [GREEN] ledger-append-201 — 3 appends admitted (first tx 1.1)
      [GREEN] ledger-duplicate-409 — re-append of identical contents -> 409 {"error":{"code":"LedgerItemAlreadyExists","message":"Ledger item already exists."}}
      [GREEN] ledger-merkle-chain-verified — 3 receipts: data_hash, merkle_root, linkage recomputed client-side
      [GREEN] ledger-latest-tx — GET /app/transactions/latest -> 200 tx=3.1
      [GREEN] ledger-tx-by-id — GET /app/transactions/1.1 -> 200
      NOTE: XFAIL = typed in-flight surface, loud, never a fake pass
```

---

## Integration note (coordinator, 2026-10-19 post-landing flip attempt)

Capability commit `8ca1b82` (KV deleted-keys/secrets planes, RBAC+locks)
landed mid-wave; the harness's pre-coded flip assertions were re-run twice
on freshly compiled canonical beams. Verdict: the plane is still not served
(`/deletedkeys`/`deletedsecrets` 404; RG-scope locks 501
LockSurfaceNotImplemented at arm_gateway/router.ex:982) — XFAIL stands,
never faked. Full recover/purge/lock assertions are coded and activate on
the first serving beam. Confounder: an outside actor cycled the shared
substrate during the window (5 beam pids observed); verdicts are
as-of-beam.
