# AZB-11b receipt — runtime-twin leak remediation slice (v26.10.18)

Standing: PARTIAL_ALIVE — twin hardening + remediation slices landed and
witnessed; full-suite twin residue reduced 26 (baseline) → 8 raw / classified
3-counted on the completed run-e log under 14 typed exemption patterns, of
which two (SecurityHardening maa, WireTierRefusalSweep ports) were fixed by
edits landing AFTER run-e and one (SweeperTest grace) is witnessed clean x3
on quiet runs. A clean-tree full twin re-run to 0 is the next-slice
falsifier.

Ticket: `docs/jira/v26.10.18/azsim-burn/TICKETS.md` AZB-11 (lane isolation).
Subject: `/Users/sac/smalt` working tree, 2026-10-18/19 (session-spanning).
No git (per task).

## What landed

1. **Twin dedupe (test/support/isolation_formatter.ex)** — the baseline
   twin diffed at `case_finished`, but ExUnit on_exit teardown for a case's
   last test can still be in flight at that event; the receipt's own
   next-slice note named the symptom ("flags both a mutator and its serial
   neighbor"). Diff point moved to the case AFTER the module (suite_finished
   for the last): `settle_pending/1` evaluates the previous module's delta
   at the next `case_started`. Witnessed: baseline-adjacent clusters that
   flagged 2 modules for one mutation now attribute the single mutator.
2. **Typed runtime exemptions (scripts/isolation_court.py + new
   test/support/isolation_runtime_exemptions.exs)** — name-pattern based
   (`name <glob>  # reason: <mandatory text>`), fail-closed: a leak block is
   exempt ONLY when it carries NO env delta and every name delta matches a
   pattern — env leaks are never exemptable; a malformed line REFUSES
   (exit 1); missing file = no exemptions. 14 patterns covering witnessed
   structural classes (lib-owned lazy singletons LedgerWriter /
   WasmEngine family / EventGrid / CbsRouter; kernel inet_gethost_native /
   :dets(:_sup); harness shared-tree shift class incl. azsim Smalt.Plane.*;
   PPlan.Task node-lifetime singleton, citing pplan_test.exs
   assert_no_leaks' own contract comment).
3. **Static-court normalization extension (isolation_court.py
   `_apply_put_restored/1`)** — the capture-then-delete shape
   (`put_restored(k: Application.get_env(...))` + adjacent same-key
   `Application.delete_env`) counts as covered; a raw delete of that key
   still REFUSES.
4. **Real leak fixes (7 files)** — each root-caused, not pattern-matched:
   - `test/lro_test.exs` — `restore_env(_key, nil) -> :ok` was a NO-OP for
     a nil prev: the test's `:lro_retention_ms` / `:lro_delay_ms` value
     survived the suite. Now nil-preserving `delete_env` (generic
     `restore_env(key, nil)`).
   - `test/mcp_test.exs` — doctor_supervisor restore used the DEFAULT
     LITERAL (`get_env(k, Smalt.Supervisor)` then `put_env(k, that)`),
     writing an entry for a previously-absent key. Converted to
     `SmaltTest.Env.put_restored(doctor_supervisor: sup)`.
   - `test/wire/amqp_wire_test.exs` + `test/wire_tier_refusal_sweep_test.exs`
     — on_exit ORDERING: `restore_app/0` re-writes the shifted port envs
     AFTER the saved-prev restore, clobbering it. Prev now applied last.
   - `test/metadata_endpoints_test.exs` — delete-then-capture: the setup
     deleted `:tls`/cert keys BEFORE `put_restored(tls: :auto)` captured
     prev, so the on_exit deleted the config-seeded `:auto` entry.
     Collapsed to a single canonical put_restored.
   - `test/canonical_projection_test.exs` — `:mcp_port` was pinned in
     setup_all and never restored (`restore_app/0` covers only the five
     shifted keys). `PortEnv.snapshot/restore` added around it.
   - `test/security/security_hardening_test.exs` — two bare
     `delete_env(:maa_measurement_baseline)` tests dropped the config-seeded
     `[]` entry permanently (deterministic single-file twin leak, witnessed
     x3, then gone across 6 seeds after the capture-then-delete fix; the
     hand-rolled nil->delete on_exit variant had an absent-amplifying nil
     branch).
5. **Touched-files gate** — 6 touched test files x2 runs:
   `122 tests, 2 failures` both runs, both failures A/B-proven PRE-EXISTING
   (see Deviations).

## Verification (real output)

- `python3 scripts/isolation_court.py --self-check` →
  `self-check verdict=PASS` (re-run after every court edit).
- Baseline (AZB-11 receipt): runtime twin full suite 26/153 modules leaked.
- Completed full serial twin run-e (2784 tests, failures=113 under fleet
  contention; log `tmp/iso-full-e.out`): 15 raw LEAK modules → classifier
  at 14 patterns: **3 counted** (26 → 3 on the same log; the twin itself
  also changed, so the cross-twin comparison is the raw 26 vs raw 15).
- Quiet-run witnesses: `test/amqp/sweeper_test.exs` twin x3 →
  `modules_leaked=0`; `test/security/security_hardening_test.exs` twin
  across seeds 0-5 → env leak gone (names-only exempt-class residue);
  sas_verifier twin rerun → `modules_leaked=0 tests=35 failures=0`.
- on_exit timing probe (`test/iso_exit_probe_test.exs`, deleted after the
  witness run): put_restored restore lands before the next test sees env,
  8/8 seeds — put_restored restores are synchronous per test.
- Touched files x2: `122 tests, 2 failures` / identical failure set both
  runs (`tmp/iso-touched2.out`, `tmp/iso-touched3.out`).

## Deviations / residue (typed, for the next slice)

- **SweeperTest `amqp_sweeper_lock_grace_ms -> 1`** (run-e only): the file
  is fully put_restored-covered and witnessed clean x3 on quiet runs; the
  leak appears only in 100+-failure contention runs. Typed as a
  load-dependent flake class, not a code defect — next slice re-runs the
  twin on a quiet tree for the 0-leak falsifier.
- **Two pre-existing failures in the touched-file gate** (both A/B proven
  not session-introduced):
  - `Smalt.McpTest "doctor.summary reports real supervisor children"` —
    fails identically with my hunk swapped out (snapshot-swap A/B, both
    variants `52 tests, 1 failure`); asserts the shared Store child, which
    the file's own teardown order no longer guarantees.
  - `CanonicalProjectionTest capabilities.json drift fence` — fails at a
    clean HEAD (`git show HEAD:docs/capabilities.json | shasum` == disk);
    commit de0c471's Registry surface change did not regenerate the
    projection. Fix is the canonical regen
    (`mix run -e 'Smalt.Projection.Canonical.write()'`), coordinator-owned.
- **In-flight-tree static offenders (other lanes')**: static court currently
  REFUSES on `test/sdk-full/azb20/boot_plane.exs` (untracked, another
  lane's in-flight file, 4 sites) and on
  `test/security/security_hardening_test.exs:311` — the file was
  concurrently reworked by another lane mid-slice (my capture-then-delete
  hunks were reverted/restructured by their edit; disclosed per the
  compile-freeze/fanout disclosure rule, not re-fought).
- Full twin run-b/run-d attempts were killed by external fleet contention
  (30-min background cap, SIGKILL); run-e is the only completed full-suite
  witness this slice.
