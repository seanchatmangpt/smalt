# BK-GWSQ — GWS-SANDBOX-GATES discharge attempt (quiet-window rerun)

**Standing**: ALIVE (3/3 green; see honest-typing caveats C1/C2)
**Context**: solo
**Date**: 2026-10-22 (UTC)
**Lane**: BK-GWSQ · Repo: `/Users/sac/smalt`
**Discharges**: the BLOCKED-ON-CONTENTION typed in
`docs/jira/v26.10.22/receipts/bkgwsskep-wave-audit.md` § GWS-SANDBOX-GATES
(4 stalls, ~30 min each, attributed to substrate contention).

## Quiet census (pre-run, 08:43–08:44 PDT)

- `uptime`: load averages **5.04 5.02 7.71** (1/5/15min) — NOT idle, but the
  lowest window of the session; falling.
- Beam census: ~30 live beams; **9443/9444 held by beam 68017** (wasmex NIF
  loaded from shared `_build/dev`), **sandbox boot block 39610–39619 held by
  beam 3089** (BKPROFV-ANON, LISTEN sockets present ⇒ live lane, not orphan).
- Typed observation: the court (`test/integration/wasm_sandbox_court.exs`)
  binds **no TCP ports** — packet-4 OS-port IPC only, boot on ephemeral test
  ports (`config/test.exs` ephemeral assignment). The bkst4w-era stall
  mechanism (fresh-build-root compile under load + port holders) therefore did
  not gate this leg. One transient `timeout 120 mix run … pb4_merkle_dual`
  probe in flight at census time.

## Execution

Fresh lane build root `_build-bkgwsq` (test env), `MIX_ENV=test` ephemeral
boot. Compile of the fresh root: **< 90 s, exit 0, 87 libs** — directly
refuting the "stalls ~30 min in compile" mechanism on this window.

```
=== RUN 1 08:53 load 8.24/7.58/8.18 ===
Finished in 1.7 seconds (0.00s async, 1.7s sync)
Result: 6 passed          RUN1-EXIT=0      (log: /tmp/bkgwsq_run1.log)
=== RUN 2 08:53 load ~7-9 ===
Finished in 1.7 seconds (0.00s async, 1.7s sync)
Result: 6 passed          RUN2-EXIT=0      (log: /tmp/bkgwsq_run2.log)
=== RUN 3 08:53 load ~7-9 ===
Finished in 1.7 seconds (0.00s async, 1.7s sync)
Result: 6 passed          RUN3-EXIT=0      (log: /tmp/bkgwsq_run3.log)
```

Each run = all 6 gates (clean-eval 429 envelope, 65 MiB memory wall,
killed-worker respawn, pool_exhausted, hung-guest fail-closed timeout,
guest-trap exit-86 containment). Full logs preserved at `/tmp/bkgwsq_run{1,2,3}.log`.

**Verdict: GWS-SANDBOX-GATES discharge typed ALIVE (3/3 green); the
contention flake did not reproduce.** The wave row re-anchors.

## Honest typing

- **C1 (quiet claim bounded)**: the window was the session's quietest
  (load ~5 falling) but not idle — load never dropped below ~4.5 and other
  lanes' beams kept spawning through the window (87892/88420/89120 at 08:45,
  more after). Post-run load **9.35 7.20 7.73** — the run itself minted no
  observable load (each run is 1.7 s of work; the rise tracks concurrent lane
  traffic, not this lane). The discharge therefore shows the court passes
  reliably on a *low-load* window with an isolated lane build root; it does
  not prove the original stalls were purely load (C2 bounds that).
- **C2 (subject drift mid-window)**: an in-flight edit to the court file by
  another lane (gate-6 `refute alive?` → bounded-poll variant, file mtime
  08:51:36) landed **before all three runs** — so 3/3 green is typed against
  the *modified* subject (current working tree, HEAD + that lane's unstaged
  edit), not the HEAD blob. The edit is disclosed here per compile-freeze
  disclosure law; BK-GWSQ staged only this receipt. If the gate-6 edit is
  reverted upstream, a one-run re-witness re-anchors the HEAD blob.
- **C3 (harness artifact, not a court flake)**: the first run-1 attempt
  (background pipe through `tail -4`) appeared hung ~5 min with the beam idle
  in `select`; killing the pipe and rerunning foreground with file-redirect
  completed in 1.7 s. Typed as a shell-pipe fd artifact, **not** a court or
  code failure — relevant to the earlier audit lanes' "stalled ~30 min"
  observations, whose harness shape (background + pipe) matched this artifact.
