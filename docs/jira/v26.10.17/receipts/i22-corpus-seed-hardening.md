# i22 — corpus/compliance shared-seed hardening (resilient clear)

Standing: PASS
Context: slice (solo lanes)
Date: 2026-10-18
Lease: `test/corpus/helper.exs`, `test/corpus/shacl_fuzz.exs`, `test/compliance/c1_arm.exs`, `test/compliance/c3_cosmos.exs`, `test/compliance/c4_blob.exs` (setup/seed paths only; no `lib/` changes)

## Defect

Shared-seed vanish class: corpus/compliance loaders seed shared Store rows
that individual faces read. The seeding pattern
`ensure_store_up() → Store.clear()` has the exact i21 race window
(`docs/jira/v26.10.17/receipts/i21-ets-race-fix.md`): between the
store-ready wait and `clear/0` (which does `:ets.delete_all_objects` +
`seed_default_subscription/0` `:ets.insert`), an async sibling suite tearing
the shared app tree down kills the named ETS tables and the insert raises
`ArgumentError "table identifier does not refer to an existing ETS table"`.

Raced sites audited:

- `Smalt.Corpus.Helper.ensure_store/0` — bare ensure+clear (feeds 8 corpus
  families: api_version_admission, head_database_account_names,
  eh_created_at, tags_normalization, blob_container_reput,
  cosmos_arm_container, secret_cross_plane_seed, vault_enrichment).
- `Smalt.Corpus.ShaclFuzz` setup — inlined bare ensure+clear (the
  shacl_fuzz/tags/error-corpus consumer named in the order).
- `test/compliance/c1_arm.exs`, `c3_cosmos.exs`, `c4_blob.exs` setups —
  bare `ensure_store() + Store.clear()` (c1 adds a subscription
  `Store.put` in the same racy window).
- c6_oauth/c7_events/c5_servicebus use `ensure_store_up()` without a
  following clear/insert — no racy window, left unchanged.

## Fix (test-side only, i21 pattern)

Bounded typed retry `resilient_clear` everywhere a clear/seed follows an
ensure-store: re-runs ensure + clear (+ post-seed thunk) rescuing ONLY
`ArgumentError` with the exact dead-table message, 10 ms backoff, 50-retry
bound, past the bound raises loudly ("shared Store unavailable after 50
retries (i22 corpus-seed hardening)") — never a silent pass.

- `Smalt.Corpus.Helper.resilient_clear/0` (public; feeds all 8
  `ensure_store()` corpus families) + `ShaclFuzz` setup now calls it.
- c1/c3/c4 each get a private `resilient_clear` (c1's takes the
  subscription-seed thunk so the put is inside the retried window).
- Local `ensure_store` defp bodies preserved (c1/c4 monitor-based, c3
  start_link/already_started).

## Verification (MIX_BUILD_ROOT=_build-ft-r11, real output)

`mix compile` green (exit 0) first.

`mix test test/corpus_test.exs`, 3 consecutive runs:

```
26 tests, 0 failures
26 tests, 0 failures
26 tests, 0 failures
```

`mix test test/compliance_test.exs`, 2 consecutive runs:

```
157 tests, 0 failures (16 excluded)
157 tests, 0 failures (16 excluded)
```

Paired (both loaders, one ExUnit run, seed varies per run):

```
183 tests, 0 failures (16 excluded)
```

## Replay

```
cd /Users/sac/smalt
MIX_BUILD_ROOT=_build-ft-r11 mix test test/corpus_test.exs
MIX_BUILD_ROOT=_build-ft-r11 mix test test/compliance_test.exs
MIX_BUILD_ROOT=_build-ft-r11 mix test test/corpus_test.exs test/compliance_test.exs
```
