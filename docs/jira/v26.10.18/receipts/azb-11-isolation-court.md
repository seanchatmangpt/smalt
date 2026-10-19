# AZB-11 receipt — isolation court (v26.10.18)

Standing: PARTIAL_ALIVE — static court GREEN (`just isolation-court` exit 0,
Context: solo (compliance_test.exs, 157 tests 0 failures)
fixtures refusing, self-check proving temp-file detection naming file:line);
runtime twin operational with leak detection witnessed (falsifier probe:
bare `Application.put_env` + named `Agent.start_link` ⇒
`ISOLATION-TWIN LEAK module=...` + court exit 1 class); full-suite twin
first run recorded the baseline split (26/153 modules leaked) — remediation
is batched into next slices per the ticket's ≤12-files/slice cap.

Ticket: `docs/jira/v26.10.18/azsim-burn/TICKETS.md` AZB-11 (lane isolation).
Subject: `/Users/sac/smalt` working tree, 2026-10-18.

## What landed

1. **`scripts/isolation_court.py` (new)** — static court extending
   `gates/test_isolation_leak_gate.py` (inherited scanner, not duplicated):
   the env rule is the leak gate's `scan_text/3` with two extensions —
   (a) inline `# isolation-court: exempt <reason>` markers (mandatory
   reason, stripped before scanning, counted in this receipt: **15**);
   (b) `SmaltTest.Env.put_restored/1` counts as fully-covered
   (save-prev + on_exit restore, structural). Plus the start_link rule the
   leak gate does not have: bare `GenServer|Agent|Task.start_link` and any
   `.start_link(..., name: :literal_atom)` in a test body must be
   `start_supervised!/1` (or an error-path assert). In-memory fail-closed
   fixtures (clean-put_restored PASS; bare put_env REFUSE naming the key;
   named start_link REFUSE; exemption honored), `--self-check` proves the
   same on real temp files, `--runtime-only` runs the twin.
2. **`test/support/isolation_formatter.ex` (new)** — runtime twin as an
   ExUnit formatter: snapshots `Process.registered/0` +
   `Application.get_all_env(:smalt)` at `case_started`, diffs at
   `case_finished`, prints `ISOLATION-TWIN LEAK module=<name>` lines and a
   `ISOLATION-TWIN SUMMARY` line. Run serially (`--max-cases 1`) so
   concurrent async modules cannot contaminate each other's diffs.
   Delivers events as casts (handle_cast → handle_event forwarding,
   `{:ok, _}` → `{:noreply, _}` translation); `suite_finished` now carries
   a times map (`{:suite_finished, %{run:, load:, async:}}`) — clause
   matched accordingly.
3. **`justfile.d/25-leak-court.just`** — `just isolation-court` (static)
   and `just isolation-court-runtime` (twin) recipes.
4. **Tree fixes (first slice)** — env rule: 61 static sites over 26 files
   found; **58 fixed** via the house `SmaltTest.Env.put_restored/1`
   (mechanical put_env+on_exit-delete collapse or bare-put conversion) and
   targeted save+restore patches (auth_enforce sts_signing_secret deleted-
   mid-test now saved/restored; broker_facade sweeper tick pin now
   save+on_exit restore; sas_verifier sb_shared_key/sb_endpoint deletions
   now saved/restored; trust_profile :tls after-block restore; hardening
   maa baseline delete now save+on_exit; hw_test 3 named VirtualSerial
   starts converted to `start_supervised!({VirtualSerial, name: ...})`).
   **3 exemptions** (plus the helper-restore markers) carry reasons.
   start_link rule: 3 named-singleton sites fixed in `test/smalt/hw_test.exs`.
5. **Formatter fix loop witnessed** — the twin's first full run crashed on
   unmatched casts, then silently dropped SUMMARY; both were witnessed,
   fixed, and re-witnessed (clean module: `ISOLATION-TWIN SUMMARY
   modules_leaked=0 tests=1 failures=0`).

## Verification (real output)

- `just isolation-court` → `verdict=PASS static=GREEN fixtures=REFUSED-OK`,
  **exit 0** (153 test module files scanned, OFFENDERS: none).
- `--self-check` → `PASS self-check/bare.exs -> REFUSE [(5, 'env mutation
  smalt.:probe_key ...')]`, `PASS self-check/bare_exempt.exs -> PASS`,
  `self-check verdict=PASS`.
- Falsifier witness (probe module `IsolationTwinProbeTest`, deleted after
  the witness run): bare `Application.put_env(:smalt, :twin_probe_key, :leak)`
  → `ISOLATION-TWIN LEAK module=IsolationTwinProbeTest` /
  `env :twin_probe_key -> :leak`; court runtime mode exits 1 (grep-count 1).
- Touched files green: batch 1 (affidavit_ocel, amqp/*): 77 tests 0
  failures; batch 2 (auth_enforce, audit_planes, blob_hardening, metadata,
  hardening, smalt_arm_gateway, trust_profile, hw): 395 tests 0 failures;
  compliance harness (`mix test test/compliance_test.exs`): 157 tests 0
  failures (c1_arm standalone failure is pre-existing harness coupling —
  `Smalt.Corpus.Helper` loads only via the compliance harness; not
  session-introduced).
- Runtime twin full suite (serial, `--max-cases 1`), first run:
  `runtime twin: 26 module(s) leaked; mix exit=2` — raw log
  `tmp/isolation-court-runtime.out`. Top leak keys: `:sb_shared_key` (6),
  `:maa_measurement_baseline` (5), port envs (~11), shared-tree
  registered-name boot pairs (2) — the pair-class is harness lifecycle
  (lazy shared-tree boot shifts the whole registered set at the first
  module that triggers it), the env classes are real next-slice work.

## Deviations / next slice

- Accept clause "full suite green ×2 with runtime twin enabled" is NOT yet
  met: first twin run = 26 leaking modules + suite exit 2. Remediation is
  batched (≤12 files/slice per the ticket); this slice landed the court,
  the twin, and 58/61 env sites + 3/3 in-scope start_link sites. Next
  slice: the 26-module twin split (dedupe the neighbor-flag pairs first —
  the twin currently flags both a mutator and its serial neighbor).
- `test/support/budget_formatter.ex` was concurrently edited by another
  lane mid-run (seen in diff stat); the transient c1_arm syntax error at
  15:16Z was another lane's in-flight edit and cleared without action.
