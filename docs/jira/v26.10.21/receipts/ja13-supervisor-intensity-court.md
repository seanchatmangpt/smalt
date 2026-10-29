# JA-13 Supervisor Restart-Intensity Court — smalt @ main

- **Date**: 2026-10-21
- **Lane**: JA-13
**Standing**: **ALIVE** (5/5 phases, 2 consecutive green runs, exit 0)
- **Court file**: `test/integration/ja13_supervisor_intensity_court.exs`
- **Build root**: `_build-ja13` (lane-isolated)
- **Toolchain**: asdf OTP 29.1.2 / Elixir 1.20.4-otp-29 (the repo pins `elixir ~> 1.20`; ambient OTP 28/Elixir 1.19.5 refuses to build it)
- **Machine**: `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.20.4","otp":"29","darwin":"26.2"}`

## Command

```bash
export PATH="$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$HOME/.asdf/installs/erlang/29.1.2/bin:$PATH"
MIX_BUILD_ROOT=_build-ja13 mix run --no-start test/integration/ja13_supervisor_intensity_court.exs
```

## Output (run 1, run 2 identical shape)

```
otp_release=29 erts=17.1.1 tree_intensity=max_restarts=5/max_seconds=5s (DataSupervisor/IntegrationSupervisor pin)
P1 PASS give_up exit=:shutdown bad_restarts=5
P2 PASS crash_once_recovered served=true restarts=1
P3 PASS one_for_all sibling #PID<0.636.0> -> #PID<0.638.0> sibling_down_reason=:shutdown bomber_down_reason=:killed
P4 PASS storm=%{baseline_roundtrips: 368617, during_roundtrips: 439613} msacc=sched_util_max=53.9%
P5 PASS amqp=%{sb_port: 52043, reborn_port: 52066, old_pid: #PID<0.10740.0>, new_pid: #PID<0.10746.0>, served_after_restart: true}
COURT JA13 PASS (5/5 phases)
```

Run 2: `P4 sched_util_max=48.8%`, `P5 reborn_port 55229` — PASS, exit 0.

## Verdicts

| Phase | Claim | Verdict |
|---|---|---|
| P1 give-up | A child crash loop trips the configured intensity (5 restarts / 5 s — the DataSupervisor/IntegrationSupervisor pin) and the supervisor gives up typed: exit reason `:shutdown` with a non-vacuity counter proving exactly ≥5 crashing restarts before the DOWN. | PASS |
| P2 crash-once-recover | First start crashes deliberately; restarted child answers real calls; supervisor child alive after. | PASS |
| P3 one_for_all escalation | Killing the bomber takes the innocent sibling down (`:shutdown` DOWN on the old pid), both restart, new sibling serves. | PASS |
| P4 storm boundedness | 2 s max-rate restart storm: control probe round-trips EXCEEDED baseline (439613 vs 368617 — fence ≥ baseline/10), all-scheduler wall-time utilization max 53.9% (fence < 99%); storm stopped cleanly after disarm. | PASS |
| P5 AMQP listener cycle | Real `Smalt.AmqpBroker` (IntegrationSupervisor subtree) + real `Smalt.Store` on ephemeral ports: listener serves, is `:kill`ed, supervisor respawns it, respawned listener re-binds a new ephemeral port and accepts TCP again (JA-7 crash→respawn→serve at the supervisor layer). | PASS |

## Findings (honest notes)

1. **OTP 29 give-up reason is plain `:shutdown`.** The classic
   `{:shutdown, :reached_max_restart_intensity}` atom was NOT observed on
   OTP 29 (erts 17.1.1); the supervisor exits with bare `:shutdown`. The
   court therefore proves give-up non-vacuously: a `:persistent_term`
   counter records 5 crashing restarts of `JA13.BadAfterStart` before the
   supervisor's DOWN, so a supervisor that merely stopped could not pass.
   Known gap if anything downstream greps for the intensity atom.
2. **Initial-start crash loops do not reach intensity.** A child that
   crashes during initial start aborts the supervisor's `start_link`
   immediately (linked caller observes the failure) — intensity give-up
   only applies to the restart loop of a RUNNING supervisor. Both P1 and
   P2 had to start through an unlinked spawner and (P2) re-start after the
   deliberate first crash. This is OTP semantics worth registering: a
   supervisor whose child cannot start never spins.
3. **Ephemeral-port respawn re-binds a NEW port** (P5): with
   `sb_port: 0`, the respawned listener legitimately serves on a different
   ephemeral port — the serve check reads the port from the respawned
   listener rather than pinning the old one. Fixed-port respawns (the
   substrate's 5672/5673) re-bind the same port; not exercised here
   because the live substrate holds those ports on this host.
4. **Concurrent-lane interference disclosed**: two retry windows were
   needed because other lanes briefly landed non-compiling edits to
   `lib/smalt/egress/KvRoutes.ex` and `lib/smalt/arm_gateway/router.ex`
   (compile-freeze SLA windows; no JA-13 action taken on their files).

## Session-introduced / pre-existing

- Court file `test/integration/ja13_supervisor_intensity_court.exs` is
  session-introduced (JA-13 lane). No `lib/` changes. Pre-existing
  substrate behavior was only exercised, never modified.

## Gate re-embed (BK-60, 2026-10-21)

Context: solo

NO-CONTEXT was a missing Context line (evidence already embedded: `COURT JA13
PASS (5/5 phases)`, exit 0). Fresh subject re-check, 2026-10-21:

```
$ grep -c 'JA13\.' test/integration/ja13_supervisor_intensity_court.exs && test -f test/integration/ja13_supervisor_intensity_court.exs
12
re-check exit 0
```

Court file present with 12 phase-marker sites. Standing ALIVE unchanged.
