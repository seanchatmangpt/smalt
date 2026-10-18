# i22 — tags_normalization.exs:49 resource PUT tags:null flake (attempt 4 leg 2)

standing: NOT-REPRODUCIBLE (stand-down per WO dispatch) + course-correction fix landed (fuzz atom_count fence)

## Face

`test/corpus/tags_normalization.exs:49` — "resource PUT with tags:null echoes
tags:null (storage account readback)" failed in r246 attempt-4 leg 2 (solo-green
premise: passes solo).

## Reproduction (pairing, dispatch-mandated 3 legs)

Pairing exactly as dispatched — tags_normalization (via its loader
`test/corpus_test.exs`; direct-file runs fail compile: `Smalt.Corpus.Helper is
not loaded`) paired with `test/compliance_test.exs` +
`test/amqp/management_rpc_test.exs`, `MIX_BUILD_ROOT=_build-ft-r9`,
`scripts/fast_test.sh`:

```
=== leg 1 === 216 tests, 0 failures (19 excluded)  wall: 102s
=== leg 2 === 216 tests, 0 failures (19 excluded)  wall: 30s
=== leg 3 === 216 tests, 0 failures (19 excluded)  wall: 46s
```

Solo control: `scripts/fast_test.sh test/corpus_test.exs` → `26 tests, 0
failures` (5.0s wall).

## Classification

NOT-REPRODUCIBLE 3x. Per the dispatch's else branch, checked the stand-down
condition: the module setup DOES seed through `ensure_store()`
(`SmaltTest.Lifecycle.ensure_store_up()` + `Store.clear()`), so the
"Store.put without ensure-store" harden-setup branch does not apply. No
code change to the tags face; the historic async-wiper class is already
root-caused and fixed (management_rpc async:false, commit 6d84ca7,
receipts/i21d-store-clear-async.md — 4/4 post-fix full-suite green).

Residual: classify as rotating load jitter (same class the r246 ledger
already assigns to the remaining faces, carried as WO-A into v26.10.18).

## Course correction (coordinator mid-task, mechanism lane 2): fuzz_test atom_count fence

`test/amqp/fuzz_test.exs` — the atom_count measurement fence in the 5000-key
atom-flood test (former lines 612-620) was a 3-window `Enum.any?(&(&1 <= 10))`
`before/after :erlang.system_info(:atom_count)` measurement inside an
async:true module; concurrent lazy-init atom minting perturbs every window,
flipping the test on runtime init rather than decode-path behavior.

Fix: dropped the measurement fence; KEPT the structural asserts (map_size
5001 + `is_binary` key check + 50k-key scale fence) — the sound, race-free
proof of zero atom minting by the decode path. Module async flag NOT flipped
(structural proof makes it unnecessary; file is a documented async:true
Store-clean module). Replacement comment cites the forensics.

Verification: `scripts/fast_test.sh test/amqp/fuzz_test.exs` → `34 tests, 0
failures` (12.2s async, build root _build-ft-e0bc4237).

## Replay

```
MIX_BUILD_ROOT=_build-ft-r9 scripts/fast_test.sh \
  test/corpus_test.exs test/compliance_test.exs test/amqp/management_rpc_test.exs
MIX_BUILD_ROOT=_build-ft-r9 scripts/fast_test.sh test/amqp/fuzz_test.exs
```
