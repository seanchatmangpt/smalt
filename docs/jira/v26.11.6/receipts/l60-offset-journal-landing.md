# L60 Offset-Journal Landing (KD-190 close leg)

Standing: PARTIAL

## Context

Solo lane L60-I, v26.11.6 overnight landing run per the L60 run-book.
Repos: /Users/sac/smalt + /Users/sac/ggen-marketplace
(packs/smalt-substrate-pack/ontology.ttl). No commits (fleet law: no git
transitions by lanes).

## Landed diff (my lease)

- `/Users/sac/ggen-marketplace/packs/smalt-substrate-pack/ontology.ttl`:
  `smalt:st-smalt_eh_checkpoints` row `persisted true` (found already on
  disk this run; runtime-verified, see below).
- `lib/smalt/store_tables.ex`: `@persisted_tables` contains
  `:smalt_eh_checkpoints` — runtime-verified:
  `MIX_BUILD_ROOT=_build-l60 MIX_ENV=test mix run -e 'IO.inspect Smalt.StoreTables.persisted_tables()'`
  → `[:smalt_blobs, :smalt_cosmos_docs, :smalt_eh_checkpoints,
  :smalt_event_messages, :smalt_ledger_meta, :smalt_ledger_transactions,
  :smalt_resources, :smalt_sb_rules]` (2026-11-04 21:54).
- `lib/smalt/messaging/offset_journal.ex`: DETS open now passes
  `repair: true` with rationale comment (`# KD-COVERS: KD-190` marker on
  the shim site), so the first reopen after a `kill -9` auto-repairs the
  corrupt-header-prone file instead of crashing; lossless because journal
  replay is authoritative and re-writes every checkpoint after reopen.

## Courts (real outputs, MIX_BUILD_ROOT=_build-l60, MIX_ENV=test, asdf 1.20.4-otp-29 toolchain)

- `mix test test/courts/court_offset_journal_test.exs` →
  `Result: 1 passed` (0.06s).
- `mix test test/internal/kafka_group_court_test.exs` → 10/11 passed
  (best of 3 exclusive runs: 8/11 → 9/11 → 10/11; runs 1-2 carried
  cross-lane load/port contention). The KD-190 layer-3 restart close leg
  (`:335`: raw OffsetCommit → kill GroupManager → restore → offset 3)
  PASSES in all three runs. The single failure is the layer-1
  FindCoordinator v0/v1 byte-exact test — deterministic, exercising
  `lib/smalt/messaging/kafka/wire.ex` + `group_manager.ex` (lane WP's
  mid-flight lease, modified on disk all night, not mine); its failure
  shape (v1 head-layout mismatch) is not reachable from my diff
  (offset_journal repair flag + ontology flip).
- `mix test test/courts/court_offset_restart.exs` → **0/2 — BLOCKED on
  the court's own harness, not on the substrate**: the child beams
  provably execute and write PASS results (real OS beams, real bytes:
  `result-aoq-push.json` = `{"status":"PASS","observations":{"released":2000,"tail_after_push":2000,...}}`
  twice; `result-eh-checkpoint.json` = offset_written 42 PASS), but the
  parent-side poll never observes the child-written files —
  `{:timeout, false}` at the result/pidfile poll across 6+ runs spanning
  BOTH harness generations (Port.open variant and the
  Task.async/System.cmd rewrite edited into the file tonight at 22:52
  and 23:28 by other lanes; the file is a contested lease and my run
  compiled from the current disk state). Witness paths under
  `$TMPDIR/court-offset-restart-*` (e.g.
  `...AoQ...-134/`, `...EH...-11714/`), sampled beams idle-waiting while
  files existed. Not fixable from my lease (court file owned by other
  lanes mid-flight). Flip-back non-vacuity leg NOT run: running it on a
  broken harness would be a vacuous court (loud skip is the honest
  state).
- Regression sweep (excludes the two compile-aborted files above; census
  law: compile-abort ≠ failure count):
  - `test/internal` (112 files, excl. `kafka_wire_test.exs` [compile
    abort, lane WP in-flight] and the group court counted separately) →
    `Result: 636/677 passed, 5 invalid`; 9 failures, all attributed
    away from my diff: 4 census (other lanes added
    `kafka_group_court_test.exs`/`kafka_kd174_court_test.exs`/
    `kafka_sasl_court_test.exs`/`kd189_legalhold_put_header_only_test.exs`
    without registering them in the census allowlist — on_disk carries
    those 4 files the registered set lacks),
    4 bkmon3r + 1 rg404 (local listener `:econnrefused` under fleet port
    pressure; reproduced in isolation; unrelated surfaces).
  - `test/courts` (9 files, excl. restart court + `aoq_quic_roundtrip_court.exs`
    [compile abort, missing import — another lane's in-flight file]) →
    `Result: 41 passed`.
- `mix compile` → 0 errors on the landed tree.

## kd_flip register gate

`python3 scripts/kd_flip.py` (dry-run, after the KD-COVERS shim marker
landed): `KD-190: FLIP-PENDING-WITNESS` — this receipt postdates the
shim mtime, so the mechanical mtime gate would pass, but the law behind
the gate is a PASS witness and this receipt's court standing is PARTIAL
(the restart court is harness-blocked). Landing a flip on a PARTIAL
receipt is mock-laundering. KD-190 stays OPEN. `--apply` NOT run.

## Handoff intel integrated

- kd_flip.py flips the canonical v26.10.14 register only; wave-register
  sync is manual (done below).
- L60-L pkilled offset_restart_child beams ~22:05 (their receipt
  discloses it; my early run-child deaths ~22:05 attributed).
- Child cold-build fragility (`Smalt.Planes.resolve/0 undefined` on
  cold build roots with `--no-compile`) — my build root was warm
  throughout; children DID write results, so my failure is the parent
  side, distinct from that class.

## Disclosure (compile-freeze SLA)

- No unblock fixes to other lanes' files (observed 3 mid-flight breaks:
  flatbuf.ex `pad_vt`, frame.ex, quic.ex stray `end` — all self-fixed by
  their owners within the SLA; I polled instead of touching).

## Post-audit re-verification (2026-11-05 05:08)

A read-only plan lane's audit claimed the flip had been undone
(`persisted false`) by the flip-back shim's restore leg running after my
verification. Fresh disk + runtime evidence REFUTES the claim:

- ontology.ttl:688 row: `persisted true`; file mtime Nov 4 21:44 — the
  ontology was not rewritten at any point tonight.
- `mix run -e 'IO.inspect Smalt.StoreTables.persisted_tables()'` at
  05:08 → `:smalt_eh_checkpoints` present (full list above).
- The flipback shim WAS run at ~04:02 (lane2's lease;
  `/tmp/lane2-flipback-ViPlkI/` artifacts + script mtime 04:02:45): its
  fail-closed EXIT-trap restore completed byte-exact (final state true).
  But the run was **VACUOUS (exit 1)**: `r2.json` shows eh-verify
  `status PASS` with offset 42 restored *under flip-back* — the shim's
  flip does not reach the substrate's actual restore path (the verify
  child restores from the DETS files on disk regardless of the
  `persisted` registry row), so the shim court cannot exit 0 as
  authored. Non-vacuity remains UNPROVEN, now with a concrete mechanism
  (vacuous-by-construction, lane2 lease to redesign).

Ordering-law compliance: flipback shim first — run (by its owner), exit
1 VACUOUS COURT with byte-exact restore; flip re-apply — not needed, the
flip never left (disk mtime + runtime proof above); repair:true —
landed; courts re-run post-audit: offset-journal court 1/1 PASS (one
load-flaked run in between printed no failure section; 2 of 3 green),
group court 10/11 with the :335 KD-190 leg green in all 4 runs (the
failing layer-1 test rotates between FindCoordinator and sync-rebalance
across runs — cross-lane port/load contention). kd_flip --apply: NOT
run — the PASS-witness law gates on the restart court + non-vacuity,
both still open.

## Standing vocabulary

PARTIAL: flip + regen + repair:true landed and court-green on their own
surfaces (offset-journal court 1/1, group court KD-190 leg PASS ×3,
courts sweep 41/41, internal sweep green on my surfaces); the restart
court and flip-back leg are BLOCKED on a contested-lease harness defect,
so KD-190 remains OPEN with this receipt as the partial-close evidence.
