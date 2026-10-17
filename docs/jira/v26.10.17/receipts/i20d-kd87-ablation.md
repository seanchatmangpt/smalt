# i20d-kd87 — shim-court ablation: in-flight router.ex/bearer.ex vs batch 401s

Standing: **PARTIAL_ALIVE** (verdict reached; ablation executed with byte-exact restore; batch itself is flaky, so single-run attribution is not decidable beyond the variance bound)

## Subject

- Repo: /Users/sac/smalt, branch main, 2026-10-17 15:04-15:13 PDT
- Files under ablation (working diffs vs HEAD):
  - `lib/smalt/arm_gateway/router.ex` (also carries arm_cors + KD-COVERS annotation changes beyond auth)
  - `lib/smalt/auth/bearer.ex`
- Question: do the in-flight diffs cause the batch 401 failures in
  `test/compliance_test.exs` + `test/kd79_blob_apiversion_wire_test.exs`?

## Protocol executed (shim-court shape, no git state changes)

Hashes (sha256):

```
HEAD    router.ex : cd8fd5e190fc5248f03a2ed5d1ac577b86ba8028b907a02bcec4bf96f5033bae
HEAD    bearer.ex : 3b0d2252410378fc2669a4eafa26619e872d407fa72f11bb95b83a6132071464
WORK    router.ex : 967c9567194077d29598d4d385cbf7bbe6cbaade0f61c461f692be50ddefa44f
WORK    bearer.ex : f1d4983ffbf366c2ebc67503d542b01dd5b9f91c8b1c86b3df15a69184f60199
```

1. **Snapshot**: `git show HEAD:...` to /tmp/abl-*-head.ex; cp working to /tmp/abl-*-work.ex. Verified working copies identical to tree.
2. **BEFORE** (working diffs): `MIX_BUILD_ROOT=_build-ft-ablate mix test test/compliance_test.exs test/kd79_blob_apiversion_wire_test.exs` → **161 tests, 19 failures (16 excluded)**. Failure classes: C1Arm row-6b api-version verbs, 17 C4Blob wire failures (x-ms-version, ranges, request-id, container metadata, duplicate PUT 409), matching the known batch-401/parity batch.
3. **SHIM** (`# SHIM-COURT ablation i20d-kd87`): copied HEAD versions over both lib files; hashes confirmed = HEAD hashes.
4. **AFTER** (HEAD files): same command → **161 tests, 16 failures (16 excluded)**. The 401 batch does NOT vanish.
5. **RESTORE**: cp working copies back; sha256 byte-exact verified:

```
967c9567194077d29598d4d385cbf7bbe6cbaade0f61c461f692be50ddefa44f (router.ex)
f1d4983ffbf366c2ebc67503d542b01dd5b9f91c8b1c86b3df15a69184f60199 (bearer.ex)
```

Both match the step-1 working hashes exactly. Subject intact, fail-closed check passed.

## Verdict

**The in-flight diffs are NOT the cause of the batch.** Swapping in HEAD for both files
only moved the count 19 → 16 (−3), far short of clearing the batch, and — decisively —
a post-restore re-run on byte-identical working-copy code returned **12 failures**,
down from 19 on the very same bytes. Within-state variance (19 ↔ 12, range 7) exceeds
the between-state delta (3), so the observed batch is **flaky/nondeterministic**
(ordering-, port-, or timing-dependent), not a product regression in router/bearer.

Attribution caution: the shim reverted the whole working router.ex including the
arm_cors/KD-COVERS annotation changes, so the −3 delta cannot be attributed to the
auth change alone — and given the measured flakiness, even that delta is within noise.

Recommended next probe (not executed): run the same test files under a fixed seed /
serialized async to identify the true flake source (suspect: port reuse or shared
store tables across the C4Blob wire tests), before any parity-defect filing per
[[testing-chicago-style]] (check pinned behavior vs substrate semantics first).

## Falsifier status

- Claim "in-flight router/bearer diffs cause the batch 401s" — **REFUTED** (AFTER with
  HEAD files still 16 failures; identical-bytes variance 19↔12).
- Claim "the batch is deterministic" — **REFUTED** by direct observation.

## Receipts

- /tmp/abl-restored-run.log (post-restore run, 12 failures)
- /tmp/abl-restored-fails.txt (failure name list)
- Build root: _build-ft-ablate (lane-owned; reclaimable via `just lane-clean`)
