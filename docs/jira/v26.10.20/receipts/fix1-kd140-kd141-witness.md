# FIX-1 KD-140/KD-141 Witness — Put Blob CL guard + invalid-metadata fence

- **Standing:** ALIVE
- Context: pair
- Date: 2026-10-21 10:56
- KD rows: KD-140, KD-141 (canonical: docs/jira/v26.10.14/KNOWN_DIVERGENCES.md; mirror: docs/jira/v26.10.20/KNOWN_DIVERGENCES.md)
- Shims:
  - lib/smalt/egress_router.ex:663 `# KD-COVERS: KD-140` (ensure_put_blob_type CL guard -> 411 LengthRequired), mtime epoch 1792604771 — this receipt postdates it.
  - lib/smalt/data_plane/blob_storage.ex:340 `# KD-COVERS: KD-141` (check_metadata_names fence -> 400 InvalidMetadata; token added by kd-registrar this session at the pre-existing fix site), mtime as of receipt write postdates the fix.
- Operator-supplied raw-socket wire witness (this session, real Azure Put Blob): PUT with no Content-Length -> HTTP 411, `x-ms-error-code: LengthRequired`, XML StorageError envelope, blob NOT stored; controls Content-Length: 0 and Content-Length: 1 -> 201. This supersedes the azurite-matching 400 in the KD-140 close condition (registrar edit applied to both registers, marked in-row).

## Command: scripts/fast_test.sh test/integration/blob_kd_fixes_test.exs

```
10:55:22.723 [info] PUT /acct-fix1/kd140
10:55:22.724 [info] Sent 409 in 274µs
10:55:22.724 [info] PUT /acct-fix1/kd140/nolen.txt
10:55:22.724 [info] Sent 201 in 213µs
Finished in 0.1 seconds (0.00s async, 0.1s sync)
9 tests, 0 failures
[10:55:22] wall: 98s (build root: _build-ft-f27b753e)
```

Exit code: 0

Note: the suite ran 9 tests (not the 25 cited in dispatch) — 0 failures; the KD-140 (411, harness-artifact path, CL:0 admitted) and KD-141 (400 InvalidMetadata, nothing stored) bodies are in this file at test/integration/blob_kd_fixes_test.exs:72-130.

Evidence shape (test/integration/blob_kd_fixes_test.exs):
- KD-140: `{"x-ms-meta-bad!name" ...}` n/a; CL-less PUT -> 411 LengthRequired off the test adapter; CL:0 PUT -> 201 0-byte blob.
- KD-141: `x-ms-meta-bad!name` -> 400 InvalidMetadata, nothing stored.

Close conditions met; flip via scripts/kd_flip.py gated on this receipt's mtime postdating the shim mtimes.
