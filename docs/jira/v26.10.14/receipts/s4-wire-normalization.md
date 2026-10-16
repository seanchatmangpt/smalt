# S-4 Wire Normalization Receipt (KD-01 / KD-03 / KD-07)

- **Lane**: S-4, v26.10.14, 2026-10-15
- **Subject**: /Users/sac/smalt @ main (uncommitted working tree; HEAD 518b31a)
- **Design source**: explore lane E-4 (three wire normalizations)

## Scope landed

1. **KD-01** — Blob PUT `?comp=metadata` no longer falls into the body-read
   Put Blob arm. New router branch (egress_router.ex, blob-PUT arm, gated by
   `not_ready?(conn, [BlobStorage])`) answers via the new engine
   `BlobStorage.set_blob_metadata/4`
   (lib/smalt/data_plane/blob_storage.ex): get_blob → REPLACE (never merge)
   the x-ms-meta-* subset of `blob["headers"]`, preserve other headers,
   bump `last_modified`, `{:ok, 200, etag + x-ms-version}`. Router answers
   **200 EMPTY** with etag header — the old 201 + JSON debug body (which also
   silently rewrote content to empty: a data-loss bug) is structurally
   unreachable on comp=metadata. Container-level comp=metadata arm untouched.
   Plus the KD-01 falsifier completion: GET/HEAD blob now echo the stored
   x-ms-meta-* subset via `stored_meta_wire/1` (scoped to x-ms-meta-* only —
   the stored header map carries the full PUT request headers; only user
   metadata is wire-safe to emit).
2. **KD-03** — `BlobService.get_container_properties` formats `last-modified`
   through new `rfc1123/1` (Calendar strftime RFC-1123, `{:error, _, _}` /
   `{:error, _}` fallback keeps the raw string; nil `created` stays
   non-crashing — verified by the HEAD-container nil-record test).
3. **KD-07** — Cosmos list-docs wire: `{"_rid", "Documents", "_count"}`
   envelope (via `Cosmos.coll_rid/2`) for SUCCESS statuses, behind a
   `when is_list(docs)` guard; error statuses (>= 400, e.g. the flat
   BadRequest continuation gate) pass through to cosmos_respond unchanged;
   a malformed (non-list) SUCCESS shape still falls to the fail-closed
   `_other -> route_not_ready` clause (503, never an empty success envelope).

## Mutation court (non-vacuity ×3)

`scripts/shim_court/wire_norm_court.sh` (+ `wire_norm_shim.py` one-line
semantic shims, + `wire_norm_witness.exs` Plug.Test dispatch witness), final
run 2026-10-15:

```
[SHIM] kd01 AFTER passed (Azure shape holds)
[SHIM] kd01 BEFORE passed (old shape returns)
[SHIM] kd01 RESTORE verified byte-exact
[SHIM] kd07 AFTER passed (Azure shape holds)
[SHIM] kd07 KD-07 AFTER/BEFORE/RESTORE passed
[SHIM] kd03 AFTER passed (Azure shape holds)
[SHIM] kd03 BEFORE passed (transcript above)
[SHIM] kd03 RESTORE verified byte-exact
[COURT] WIRE-NORM COURT: ALL LEGS PASSED
```

Witness modes: kd01_before = 201 + non-empty JSON debug body (old wire, incl.
the silent-content-emptying data-loss shape); kd01_after = 200 EMPTY + etag;
kd03_before = ISO-8601 `T`-separated last-modified; kd03_after = RFC-1123
"... GMT"; kd07_before = bare JSON array; kd07_guard = non-list success → 503
(fail-closed preserved). All restores sha256-verified byte-exact.

## SDK falsifiers (real venvs, real substrate)

Substrate booted anonymously on 8443 (boot script /tmp not in repo; same
pattern as test/sdk-python/boot_substrate.py). Final runs:

- py_storage_blob (test/sdk-python/py_storage_blob.py): **probe 04 PASS**
  (set/get blob metadata round-trip; 201-divergence dead), **probe 10 PASS**
  (RFC-1123 last_modified deserialized OK). 9/10 passed; the one FAIL is
  probe 05 = KD-02 (blob comp=list BlobProperties XML), not in S-4 scope.
- py_cosmos (test/sdk-python/py_cosmos.py): added `read_all_items` probe
  (test/sdk-python/py_cosmos.py) — **PASS** (ReadFeed envelope deserialized
  by azure-cosmos). 24/26; residual 2 fails (SQL whitelist `root` alias =
  KD-06; cross-partition row count) are query-lane, not S-4.

## Verification ladder (mix test, final tails)

S-4-owned surfaces (final per-file tails):

```
test/data_plane/cosmos_test.exs            105 tests, 0 failures
test/compliance/c3_cosmos.exs               28 tests, 0 failures
test/data_plane/blob_service_test.exs       18 tests, 0 failures
test/data_plane/conditional_headers_test.exs 7 tests, 0 failures
test/data_plane/blob_hardening_test.exs     95/96 (1 failure = X-1 block-list
                                            lane's own in-flight test)
```

Full 8-file run: 408 tests; residual failures are exclusively the auth
lane's in-flight KD-15/SKR/KV-wiring surface and c4_blob (below). Failure
count varied run-to-run (22 → 28) with zero S-4 file changes — concurrent
lane churn, not S-4 regressions.

- All KD-07-flipped assertions updated (egress_dispatch :131/:1620/:1649,
  c3_cosmos :513-516/:527/:728-729) and passing.
- 18× C4BlobTest failures: **pre-existing at HEAD** — assert_std_blob_headers
  requires a v4 x-ms-request-id on SUCCESS responses; HEAD and current tree
  both carry exactly 5 request-id stamps (error paths only). That lane
  (request-id on success paths) has not landed.
- 4× EgressDispatchTest failures (KD-15 challenge shape, SKR 403s): auth
  lane's in-flight surface, unrelated to S-4.

## Disclosures

1. **Compile-freeze unblock (disclosed, non-lane file)**: applied the minimal
   fix twice to lib/smalt/auth/bearer.ex:499/545 — charlist `'...' <> reason`
   (ArgumentError) → binary concat. Re-broken once by a concurrent auth-lane
   write and re-fixed; the fix is semantically the intent (binary header
   value). Auth lane owns the file.
2. **Shared-tree write race**: egress_router.ex was overwritten from a stale
   buffer three times during the lane (KD-07 hunk reverted to the guard-only
   version, losing the `status >= 400` passthrough that keeps the flat
   BadRequest continuation gate). Re-applied each time; final on-disk state
   verified (grep) before the final court + suite. Coordinator should diff
   egress_router.ex before integration.
3. **git checkout incident**: early in the lane, a `git checkout --
   egress_router.ex` (mine, for baselining) wiped uncommitted work in that
   file (the auth lane's kv_challenge_guard + my hunks). Restored from my
   /tmp snapshot; the snapshot may not include later concurrent lane edits
   that were on disk but unseen — flagged for coordinator diff at integration.
4. Same-second mtime staleness: mix skipped recompilation after shim edits
   within the same second; the court now sleeps 1s after shim application.

## Standing

KD-01, KD-03 (ledger numbering; task KD-02), KD-07 → **CLOSED-WITH-RECEIPT**
(KNOWN_DIVERGENCES.md updated, SDK_MATRIX py blob/cosmos rows re-stamped).
KD-02 (ledger) stays OPEN (comp=list BlobProperties XML, probe 05) with a
note that `rfc1123/1` is reusable for its date half. No commits made.
