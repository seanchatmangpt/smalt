# i22 — shacl-fuzz snapshot hardening (faces :79 / :98 / :146)

Standing: PARTIAL_ALIVE — mechanism reproduced and repaired for the
snapshot-race class (probe T1 red → T2 green, real Store, hot foreign writer);
the file is 3/3 green paired with compliance. The full-suite-load faces
(attempt-4, 2655-test tree) remain load-attributed; the repair removes the
witnessed interference term, not every possible full-suite face.

Lane: i22-shacl-fuzz-fix (Context: pair). Repo /Users/sac/smalt,
MIX_BUILD_ROOT=_build-ft-r7. No git operations.

## Faces and mechanism classification

Faces (all witnessed in r246 attempt 4, all solo-green):
- `test/corpus/shacl_fuzz.exs:79` (L2 admission test)
- `test/corpus/shacl_fuzz.exs:98` (1,000-payload fuzz sweep)
- `test/corpus/shacl_fuzz.exs:146` (pinned regression rows)

Classification: **shared-Store row race from the concurrent async:true pool,
read through an unscoped single-read snapshot** — NOT timing/slack in the
device-under-test and NOT a substrate state fault.

- Every corpus/compliance module is `async: false` (serial queue, verified by
  grep), so they cannot be each other's writer. The concurrent writers during
  a corpus leg are the async:true pool; `test/amqp/fuzz_test.exs`
  (async: true, 1,000-PUT sweeps over the same five families) writes foreign
  rows into the SAME `:smalt_resources` table while ShaclFuzz holds its
  snapshots. Topology converged on this independently (coordinator note).
- `snapshot/0` took an UNFILTERED single read of
  `{Store.keys(:smalt_resources), Store.keys(:smalt_resource_groups)}`, so a
  foreign insert landing between `pre` and `post` on a refused request was
  misread as an L3 violation (faces :98/:146). Face :79's setup assert (RG
  seeds, :69) is the same interference arriving through the seed window, since
  hardened separately by the corpus-seed lane's `resilient_clear` (disclosure
  below).
- Secondary envelope (i20b receipt): `Store.keys/1` rides the default 5000ms
  GenServer cliff; measured 350x sync-latency tail under saturation. The
  snapshot retry also rescues that typed exit and the dead-table
  ArgumentError window.

## Reproduction (required pre-fix paired leg)

Task-required repro: `mix test test/corpus_test.exs test/compliance_test.exs`
(the correct pairing — running `test/corpus/shacl_fuzz.exs` directly bypasses
the `Code.require_file` of `test/corpus/helper.exs` and fails with
`Smalt.Corpus.Helper is not available`; the correct loader is corpus_test.exs).

- 3 paired legs PRE-fix: **0 failures, 0 shacl_fuzz faces in all 3** —
  NOT-REPRODUCIBLE at this pairing pressure. Standing down on the pairing was
  the default; the coordinator's mid-task direction instead authorized the
  typed hardening of my own file's snapshot windows, citing the mechanism
  (fuzz_test flip being out of lease).
- RED was then witnessed by direct mechanism probe (below), which reproduces
  the exact interference term the full suite supplies.

## Probe evidence (real output, 3 tests, 0 failures)

/tmp probe (`I22.SnapshotProbe`, real Store, hot foreign writer inserting
`/subscriptions/other-sub/writer-N` keys, 200 windows per leg):

```
[i22-probe] T1 old-snapshot false L3 windows: 6/20
[i22-probe] T3 new-snapshot real-violation catches: 200/20
[i22-probe] T2 new-snapshot false L3 windows: 0/20
3 tests, 0 failures
```

(T1: the OLD unscoped single-read snapshot misread foreign inserts as L3
violations in 6/200 windows — the mechanism reproduced against the real
Store. T2: the NEW subscription-scoped + quiesce-retry snapshot: 0/200 under
the same writer. T3: a real same-scope key injected mid-window is still
caught 200/200 — the L3 law bites through the new snapshot; not loosened.)

Probe-bug disclosure: the first two probe runs reported T1=20/20 and T2=20/20
— invalid: `with_writer/1` returned `Process.exit`'s `:ok` (truthy), so
`Enum.count` counted every window regardless of outcome. Fixed to return
`fun.()`'s result; the 6/200 figure is the valid red witness.

## Fix (test/corpus/shacl_fuzz.exs only)

`snapshot/0` → subscription-scoped quiesce read:

1. **Scope**: keys filtered to `String.contains?(downcase(k),
   "/subscriptions/fuzz-sub/")`. The pipeline writes only keys derived from
   the request path, so every key our refused request could touch is inside
   the scope; foreign async writers cannot write our subscription. The L3 law
   is intact within the scope (probe T3).
2. **Quiesce**: two consecutive agreeing reads (quiet path = one extra :ets
   scan, no sleep — the first 25ms-per-snapshot variant blew the 60s ExUnit
   timeout, 1 failure x3 legs, then restructured); sleep only after a torn
   read; bounded at 20 retries with a loud raise past the bound.
3. **Typed rescues**: dead-table ArgumentError (same face the corpus-seed
   lane's resilient_clear rescues) and `{:timeout, {GenServer, :call, ...,
   5000}}` exits (i20b cliff) retry with 25ms backoff.

## Verification

- Solo: `mix test test/corpus_test.exs` → `26 tests, 0 failures` EXIT=0.
- Paired green legs (fixed file): corpus_test + compliance_test x3 →
  `183 tests, 0 failures (16 excluded)` EXIT=0 all three
  (/tmp/i22-green2-leg{1,2,3}.log).
- Pre-fix paired legs: 0 failures x3 (NOT-REPRODUCIBLE at pairing pressure;
  red carried by probe T1 instead).

## Foreign-lane disclosures (compile-freeze / shared seams)

- `test/corpus/shacl_fuzz.exs` setup line and `test/corpus/helper.exs`
  (`resilient_clear/0`, i22 corpus-seed hardening) were landed by a concurrent
  lane DURING my first paired runs; my run-2 faces
  (`resilient_clear/0 is undefined`) were that lane's mid-edit state, not
  mine. `test/compliance/c1_arm.exs` was likewise mid-edit (truncated defp,
  TokenMissingError) for ~6 minutes; I polled 6x60s instead of touching it
  under the SLA; the owner completed it.
- No edits by this lane outside `test/corpus/shacl_fuzz.exs` and this receipt.
  Scratch: /tmp/i22_snapshot_probe_test.exs, /tmp/i22-*.log (cleaned).

## Falsifiers / open

1. Full-suite (2,655-test) faces may still rotate: the probe removes the
   foreign-writer interference term for shacl_fuzz only. Close condition: a
   full suite leg with zero shacl_fuzz faces.
2. If an L3 false-positive ever recurs, next suspect is a writer INSIDE
   fuzz-sub's keyspace (none exists today — the subscription is
   shacl-fuzz-exclusive).
