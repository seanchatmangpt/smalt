# i21b — leak-court wire/amqp/eventgrid lane (leak7)

standing: PARTIAL_ALIVE (5 lease files covered, 0 lease regressions; tree-wide court still FAIL-TREE-LEAKS on files outside this lane)

## Lease

`test/wire/arm_wire_test.exs`, `test/amqp/flow_credit_test.exs`,
`test/wire/egress_wire_test.exs`, `test/eventgrid_topics_arm_test.exs`,
`test/eventgrid_conformance_test.exs` (leak-court top offenders).

## Delta

Baseline court (pre-lane): OFFENDERS (45 files, 96 mutations uncovered).
Post-lane court (this session, real output):

```
-- OFFENDERS (37 files, 65 mutations uncovered) --
verdict=FAIL-TREE-LEAKS tree=LEAKS offenders=37 fixtures_refused=True
receipt=/Users/sac/smalt/tmp/invariant-gates/test-isolation-leak-gate receipt path elided
```

Lease files in post-lane offender table: **0** (grep for
`wire/(arm_wire|egress_wire)|amqp/flow_credit|eventgrid` over the court output
returned 0 matches). All 11 flagged mutations in this lane's files
(egress_wire 3, flow_credit 4, eventgrid_topics 3, conformance 3) now carry
save-prev + literal per-key on_exit restore.

## Changes

- `test/wire/egress_wire_test.exs` — save-prev map (arm/egress/amqp port) in
  setup; literal per-key nil-aware restore in the existing on_exit, ahead of
  `Lifecycle.restore_app()` (shared-app shifted-ports contract preserved).
- `test/amqp/flow_credit_test.exs` — same pattern for 4 port keys; restores
  ride the per-test `on_exit` next to the existing `sb_shared_key` delete.
- `test/eventgrid_topics_arm_test.exs`, `test/eventgrid_conformance_test.exs`
  — save-prev maps added; restores prepended inside the existing
  `Lifecycle.restore_app` on_exit blocks.
- `test/wire/arm_wire_test.exs` — no edit needed; already
  save-prev/on_exit-restore (used as the in-tree exemplar; verified green).

## Verification (real runs, MIX_BUILD_ROOT=_build-ft-leak7, deps at lock ex4pm 26.10.1)

```
$ mix test test/wire/arm_wire_test.exs
6 tests, 0 failures
$ mix test test/amqp/flow_credit_test.exs --include amqp_wire
7 tests, 0 failures
$ mix test test/wire/egress_wire_test.exs
22 tests, 0 failures          (lease expected 22/0 — match)
$ mix test test/eventgrid_topics_arm_test.exs
9 tests, 0 failures           (lease expected 9/0 — match)
$ mix test test/eventgrid_conformance_test.exs
12 tests, 0 failures
```

## Shared-tree incident (disclosed, resolved by another lane)

Session midpoint: HEAD commit 248e119 (B1 CLOSED) had dropped the ex4pm
`override: true` while hex ash_ex4pm 26.10.4 pins ex4pm == 26.10.1 — the tree
was dep-unresolvable (`mix deps.get` exit 1, resolver log quoted in session).
I applied a temporary `override: true` unblock for my runs, then another lane
landed the proper fix (mix.exs now pins `{:ex4pm, "~> 26.10.1"}` + restored
mix.lock at 26.10.1); my temp override is gone, `deps/ex4pm` refetched at the
locked 26.10.1, and all suites above ran against the reconciled state. My lane
left mix.exs/mix.lock byte-identical to the other lane's landing (my only
mix.exs writes were the since-reverted temp override, disclosed here).

## Cleanup

`_build-ft-leak7` lane build root deleted at lane end (lease-lease law).
