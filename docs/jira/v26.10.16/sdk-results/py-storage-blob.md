# PY-2: Real azure-storage-blob SDK vs smalt blob plane (v26.10.16 re-run)

- Date: 2026-10-16
- Repo: /Users/sac/smalt @ main, v26.10.16 window
- Probe: `test/sdk-python/py_storage_blob.py` (venv `.venv-blob`)
- Port env: probe now reads `SMALT_EGRESS_BASE` (lane-351); run against the
  lane-351 substrate (ports 39360-39364), MIX_ENV=test anonymous auth,
  SharedKey smaltacct / smaltacct-key.
- Exit: 1 (9/10 pass; probe exit reflects the one finding below)

## Verdict: 9/10 — 1 finding (KD-02, reproduced)

Embedded probe output (lane run, egress 39363):

```
PASS 01 create container default-immutable :: created py-imm-1792169250285
PASS 02 create container mutable opt-out (x-ms-immutable-policy: false) :: created opt-out py-mut-1792169250293
PASS 03 upload/download block blob roundtrip :: etag="dae6fdda22cf2070d12041985db4c2fd", 39 bytes roundtrip
PASS 04 set/get blob metadata :: metadata echoed: {'env': 'sdk', 'pylane': 'two'}
FAIL 05 list: delimiter + include=metadata + results_per_page :: DIVERGENCE: List Blobs XML undeserializable by azure-storage-blob 12.31.0 (BlobProperties missing required fields — BlobType/LeaseStatus/Content-Type — and Last-Modified emitted ISO-8601, not RFC-1123): Unable to deserialize response data. Data: [<Element 'Blob' at 0x109fe8220>], [BlobItemInternal]
PASS 06 list junk maxresults -> 400 :: 400 as expected (Value for maxresults is invalid (must be a positive integer))
PASS 07 conditional If-Match stale etag -> 412 :: 412 on stale etag "6654c734ccab8f440ff0825eb443dc7f"
PASS 08 delete blob -> 202 :: delete 202, exists() false
PASS 09 immutable overwrite -> 409 ContainerLocked :: 409 ContainerLocked as expected
PASS 10 get container properties (RFC-1123 Last-Modified) :: last_modified=datetime.datetime(2026, 10, 16, 16, 47, 30, tzinfo=datetime.timezone.utc) (RFC-1123 OK)

9/10 passed
```

## KD deltas

- KD-01 (set blob metadata 200 empty) — closure re-witnessed: probe 04
  set/get metadata PASS, 200 with `x-ms-meta` echo (CLOSED-WITH-RECEIPT row
  already cites this receipt filename).
- KD-03 (container props RFC-1123) — closure re-witnessed: probe 10 PASS,
  `rfc1123/1` path.
- KD-02 (List Blobs BlobProperties missing BlobType/LeaseStatus/Content-Type,
  ISO-8601 Last-Modified) — still OPEN, reproduced 2/2 lane runs, identical
  deserialization error.

## Falsifier replay

```bash
SMALT_EGRESS_BASE=http://127.0.0.1:<egress> \
  test/sdk-python/.venv-blob/bin/python test/sdk-python/py_storage_blob.py
# expect: 9/10; probe 05 deserialization finding per KD-02 until the
# BlobProperties XML is completed.
```
