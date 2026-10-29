# BK-CENS5 — census reconcile wave 5: JA10 dead allowlist entry closed; fence verified clean

**Standing:** ALIVE
Context: solo

Lane: BK-CENS5, `MIX_BUILD_ROOT=_build-bkcens5` (lease). Files owned/edited: `test/integration/ja10_transparency_court.exs`
(JA10 leg-2 allowlist only), this receipt.

## Census (real output, this session)

The two witnessed drifts (BK-MON2 r/bkmon2, BK-ST4W r/bkst4w):

1. **store4_no_boot_test.exs unregistered** — ALREADY CLOSED at lane start:
   HEAD's census registers it (`internal_tier_census_test.exs:94`, comment
   names BK-ST4W + the BK-SEAL5 registration under the compile-freeze SLA).
   Census verified green with no edit from this lane:
   `MIX_BUILD_ROOT=_build-bkcens5 scripts/fast_test.sh test/internal/internal_tier_census_test.exs`
   → `Result: 6 passed` (twice: lane start 07:00Z and post-fix 07:15Z).
2. **JA10 dead allowlist entry (`Smalt.Store`)** — CONFIRMED and CLOSED.

## JA10 dead-law fix (no behavior loosening)

`test/integration/ja10_transparency_court.exs` leg 2's anti-vacuity clause
asserts every `@named_label_exceptions` entry is an OBSERVED unlabeled live
registered name. `Smalt.Store` was dead law: no process registers the bare
atom. Ground truth was taken from the live tree, not guessed: a throwaway
probe (scratch test, deleted after use — population fence untouched) walked
the real self-booted supervision tree and printed every unlabeled named
worker. Observed set: `Smalt.Store.{Boot, Heir, Partition0..15}` (the live
ensemble registers the family, not the bare atom), plus
`Smalt.Messaging.Kafka.Sink`, `Smalt.Messaging.EventHubs.Server`,
`Smalt.Messaging.EhGeoDr`, `Smalt.ConfidentialLedger.{Sink, Service}`,
`Smalt.WebPubSub` — none previously allowlisted. Edit: the dead `Smalt.Store`
row replaced by the 18-entry Store family; the 6 other newly observed names
added. 5 pre-existing live entries (RollingCounters, Monitor.Metrics,
StsGate, WasmEngine.Supervisor.Owner) unchanged. Guard strength unchanged:
leg 2 still requires every entry to have an observed unlabeled referent and
be a live registered process; the final unexpected-unlabeled assert is
untouched.

## Verification (real output, this session)

1. JA10 court after the edit:
   `MIX_BUILD_ROOT=_build-bkcens5 mix test test/integration/ja10_transparency_court.exs`
   → EXIT=0, `Result: 5 passed`; leg2 census `736 labeled / 712
   supervisor-exempt / 28 named-exception` — the 28 named-exception lines
   name exactly the 28 allowlist entries (anti-vacuity intact: dead law
   check passes only because every entry is observed).
2. store4 pin:
   `MIX_BUILD_ROOT=_build-bkcens5 scripts/fast_test.sh test/internal/store4_no_boot_test.exs`
   → `Result: 1 passed`.
3. Census re-run → `Result: 6 passed`.
4. **Fence sweep + both foreign failures closed**: the exact BK-MON2
   disclosed suite re-run:
   `mix test test/internal/plane_blast_radius_test.exs test/integration/ja10_transparency_court.exs test/internal/internal_tier_census_test.exs`
   → `Result: 17 passed` (BK-MON2 witnessed 15/17 with these two as foreign
   failures; now 17/17). Population fence (test/internal = 91 files, all
   registered) green — no OTHER unregistered files exist.

## Disclosure

- The census file needed NO edit this lane — the store4 registration landed
  under BK-SEAL5's name before this lane started. This lane's only tree edit
  is the JA10 allowlist fix.
- A scratch probe test briefly existed at
  `test/internal/zz_bkcens5_probe_test.exs` to ground the allowlist names;
  deleted before any census run (the two census runs in this receipt both
  executed with it absent).
- `M Smalt...: scripts/kd_receipt_fence.py` modification and untracked
  `receipts/bkmcpw-attr-fix.md` visible in the lane's git status are OTHER
  lanes' in-flight files; not staged by this lane.
- Lane build root `_build-bkcens5` is a lease (coordinator `just lane-clean`
  at integration).

## Receipt

- Subject: BK-CENS5, repo /Users/sac/smalt @ main (coordinator owns git;
  staged: ja10 allowlist fix + this receipt, explicit paths)
- Falsifiers: JA10 dead-law clause re-witnessed green against the 28-entry
  allowlist; census population fence green (no unregistered drift)
- Verification ladder: census (6) → store4 pin (1) → JA10 court (5) →
  combined 17/17

## Landing provenance (post-commit disclosure)

Coordinator checkpoint race split this lane's landing: commit 5e85cbc0 named
this lane's two explicit paths but ALSO carried a foreign in-flight file
(`scripts/kafka_replay/bkkfkskep_wplib.py`, BK-KFKSKEP's, landed verbatim,
content untouched) and an earlier checkpoint had swept this lane's deleted
scratch probe (`test/internal/zz_bkcens5_probe_test.exs`) into HEAD — so
this lane's deletion shows as a working-tree `D`. This disclosure commit
lands that deletion (fix-forward, no resets, no history rewrite). Attribute
`bkkfkskep_wplib.py` to BK-KFKSKEP.
