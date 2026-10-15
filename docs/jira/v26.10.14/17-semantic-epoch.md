# V261014-17 — Semantic epoch: doc-fact reconciliation + assumption comments

- **Release:** v26.10.14
- **Scope:** docs + comments only. No production code changes.
- **Size:** tiny (2 file edits, 1 comment insertion)

## Background

The semantic-epoch projection surface is complete and hardened: drift law is `standing > no_pack > digest > ok` (`lib/smalt/projection/semantic_epoch.ex:262-283`); the ledger fold is lenient while ledger refusals stay typed; the identity fence (`lib/smalt/registry/identity.ex:47-60`) has 5 consumers. The digest-drift test was already re-cut this session to pin **derivation correctness** (`test/semantic_epoch_test.exs:90-110`: per-row `expected = if digest == lock, do: :ok, else: :digest_drift`, plus an `Enum.any?` pair requiring both classes) — keep that test as-is.

Ledger census (verified at authoring time): the live pack digest is `83a3bb18af8844aaf2b25639c448eb4e2aba2415319fa1998a95071a4a39177f`, read from `packs."smalt-substrate-pack".sha256` inside `ggen_igniter.pack.lock` — **not** the hash of the lock file itself. The 8 in-sync `alive` receipts are post-re-lock (carry `83a3bb18…`); the 19 `4fe9d26c…` receipts are pre-re-lock era — **historical, not live drift**; the live invariant is fenced by `test/smalt_registry_replay_identity_test.exs:56-70`. Because the ledger legitimately carries both eras, both drift classes exist among stamped alive rows — exactly what the `Enum.any?` pair pins.

## Tasks

### 1. Stale doc fact — `docs/PACK_INTEGRATION/semantic-epoch.md` (~line 44)

Current text cites pack digest `3f7d1f3a…` against lock `70a135be…` and claims "this surfaces a real drift row." Both digests are one epoch behind. Rewrite to current facts:

- live lock digest: recomputed from the lock file at landing time —
  `python3 -c "import json;print(json.load(open('ggen_igniter.pack.lock'))['packs']['smalt-substrate-pack']['sha256'])"` — do NOT copy the hex from this work order;
- the real ledger carries a mixed history (in-sync `:ok` rows from the current era + pre-re-lock `4fe9d26c…`-class rows), so both `:ok` and `:digest_drift` classes are present on the live tree.

### 2. Inventory reconciliation — `docs/TEST_ISOLATION.md` (:62, :78)

The doc counts `test/pplan_test.exs` in the "`Store.clear()` in setup" inventory, but the suite contains no `Store.clear/0` call — its setup installs a generalized spawn-leak tracer (`test/pplan_test.exs:26-35`, `:erlang.trace` + `on_exit` `assert_no_leaks`). One-line reconciliation: remove `test/pplan_test.exs` from the count (25 → 24) and the file list at :78; adjust the :62 clause accordingly; optionally add a parenthetical noting pplan_test is covered by the leak-tracer section instead.

### 3. Assumption comment — `test/semantic_epoch_test.exs` (~:105-110)

The `any?(:ok)` + `any?(:digest_drift)` pair assumes both drift classes persist. If a future ledger cleanup (e.g. pre-re-lock receipt retirement) drops the old-era receipts, the `:digest_drift` half vacates and the assert fails spuriously. Extend the existing comment with one sentence: the assertion pair depends on the ledger continuing to carry receipts from both lock eras, and a deliberate ledger cleanup must update this pin (or narrow it to the surviving classes) in the same change.

### 4. No action — re-lock procedure

Future re-locks use the documented one-liner `mix ggen_igniter.pack.lock` (test failure message :63-69); the test derives the expected digest from the lock file at runtime (`lock_digest/0`, :527-532), so re-locks require no test edits.

## Post-landing verification

```
mix test test/semantic_epoch_test.exs
mix test test/smalt_registry_replay_identity_test.exs
```

(The second spawns `mix run` subprocesses under `MIX_ENV=dev`, tagged `@tag :replay_identity`; slower.) Acceptance: both green; the digest cited in the doc matches the recomputed `packs.smalt-substrate-pack.sha256` on disk at landing time.

## Explicitly out of scope

- Any change to the drift law, fold, or identity fence.
- Any ledger mutation (deleting pre-re-lock receipts).
- Re-running the pack lock.
