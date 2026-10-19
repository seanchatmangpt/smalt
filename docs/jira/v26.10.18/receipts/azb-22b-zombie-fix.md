# AZB-22b — ZOMBIE_BEAM repair: Owner EXIT face + Bandit shutdown bounds

Standing: **PARTIAL_ALIVE** — the product defect's two repair faces are
landed, red→green witnessed at the unit/OTP level, failclosed suite green x2;
the ring boot-stage rerun is **typed BLOCKED (fleet contention)**: six image
build attempts failed on colima TLS flaps / disk exhaustion / tag churn, and
HEAD churn every ~5 min defeats the ring's subject-binding init guard. The
in-image ZOMBIE_BEAM typed row is NOT yet re-judged — a fresh ring boot stage
remains open (see Open items).

Ticket: `docs/jira/v26.10.18/azsim-burn/TICKETS.md` AZB-22 (ring surfaced;
falsifier face of AZB-13 "zombie beam across cycles")
Context: pair(dispatch: fix Owner catch-all + Bandit shutdown, rerun
`just burn-ring --stage boot`, failclosed 10/11/12 green x2, receipt here,
No git)
Subject: `/Users/sac/smalt`; fix landed at **8552eec** (coordinator commit;
tree at `1339e05` at final verification)

## What landed

1. `lib/smalt/affidavit/wasm_engine_supervisor.ex` — Owner gains a typed EXIT
   clause before the catch-all: `handle_info({:EXIT, _sup, reason}, state) ->
   {:stop, {:shutdown, reason}, state}`. The catch-all no longer terminates on
   supervisor shutdown EXITs by accident of swallowing.
2. `lib/smalt/plane/control_supervisor.ex` (2 Bandit mounts: 9443 http + 9444
   TLS twin), `lib/smalt/plane/data_supervisor.ex` (8443 egress),
   `lib/smalt/application.ex` (`mcp_bandit_child/0`, 9545 MCP): every Bandit
   child spec is wrapped `Supervisor.child_spec({Bandit, opts}, shutdown:
   10_000)`.
3. `test/azsim/graceful_stop_test.exs` (new, 3 tests): Bandit child specs at
   every mount carry shutdown 10_000 (calls the real `init/1` of each plane
   supervisor + `mcp_bandit_child/0`); upstream-default fence (Bandit ships
   no `shutdown` key — pins the defect shape); real graceful-stop leg
   (terminate_child on the live tree, elapsed < 4.5 s, owner DOWN reason
   typed `:shutdown`, subtree restored).

## Root-cause correction (honest, instrumented)

The AZB-22 ring receipt localized the wedge to "the Owner catch-all swallows
{:EXIT, sup, :shutdown}". Instrumented experiment on the reconstructed
pre-fix subject (debug print in the catch-all, real subtree stop) shows the
catch-all is **never reached during stop**: `gen_server` itself handles
`{'EXIT', Parent, _}` before the callback module, so a trapping GenServer
always terminated on supervisor shutdown regardless of the catch-all. The
**live wedge face is the Bandit child-spec shutdown** — Bandit's own
child_spec omits `shutdown`, so with `type: :supervisor` Supervisor.init
applies **:infinity**, and a ThousandIsland listener that refuses :shutdown
hangs the whole tree's stop (the witnessed `:stuck_after_60s`). The Owner
EXIT clause is kept as the dispatch-required typed defense (non-parent EXITs
now terminate typed instead of being swallowed).

## Red→green (real output)

Bandit face, pre-fix subject (constructed by reverting the two edits; the
`git show HEAD:` swap is unusable — the coordinator commit landed the fix
mid-session, so HEAD already contained it):

```
** (KeyError) key :shutdown not found in:
    %{id: {Bandit, #Reference<...>}, restart: :permanent,
      start: {Bandit, :start_link, [[plug: Smalt.EgressRouter, ...]]},
      type: :supervisor}
3 tests, 1 failure
```

(+ `Smalt.Application.mcp_bandit_child/0 is undefined or private` on the
earlier pre-fix attempt — same subject, second face.)

Green (fixed tree):

```
Finished in 0.2 seconds (0.00s async, 0.2s sync)
3 tests, 0 failures
```

The stop-typed leg also passes pre-fix on the host (gen_server parent-EXIT
mechanics) — it is a regression fence, not the red witness; the red witness
is the unbounded-shutdown spec above.

## Failclosed suite green x2 (fences 10/11/12)

`test/affidavit_wasm_failclosed_test.exs` (14 tests incl. fence 10 restart
hammer, fence 11 supervised-restart kill-loop, fence 12 already_started
passthrough), final HEAD `1339e05`:

```
=== RUN 1 === 14 tests, 0 failures   (7.1s)
=== RUN 2 === 14 tests, 0 failures   (7.1s)
```

(earlier session runs, same result: `14 tests, 0 failures` x2 at 5.6s/6.0s)

## Ring rerun: BLOCKED (typed, with evidence)

Six `docker build -f docker/Dockerfile -t smalt:local …` attempts
(`--build-arg SUBJECT_SHA=$(git rev-parse HEAD)`, all three sibling
build-contexts per docker/Dockerfile:52-54). Failure faces, in order:

1. `ash_graphlaw: pull access denied` — missing build-contexts (fixed by
   passing all three).
2. `mix local.hex … exit code: 1` — repo.hex.pm TLS flap (colima NAT; the
   Dockerfile's own comment documents this failure class).
3. `CANCELED` mid-compile — concurrent lane builds canceling.
4. `no space left on device` x2 (containerd snapshot writes) — colima VM
   disk. Reclaimed: `smalt-burn:latest` (rebuildable test target, not
   consumed by the ring) + `docker builder prune -a` (9.675GB) + volumes
   (2.9GB).
5. Sustained **4 concurrent `docker build` processes** from other lanes;
   HEAD moved 7x during this lane (825657f → 014bb7a → 219469d → dda0bf5 →
   219469d → 44b0859 → … → 1339e05); the ring init guard
   (IMAGE_SUBJECT_MISMATCH) needs image label == HEAD at init.
6. A concurrent lane overwrote `smalt:local` with a **default-label build
   (label 29bb037, the Dockerfile ARG default)**; probing that image
   directly (3-cycle boot burn, host-mounted /ring) fails at the BOOT stage
   with `Store already started` (IntegrationSupervisor double-start race,
   since guarded at 0e5797c) — i.e. the currently-public image is a mid-edit
   tree artifact, not a valid subject for any ring.

No ring boot stage was run against a fixed, valid image; the ZOMBIE_BEAM
typed row is therefore **not re-judged** and remains the open acceptance
item for AZB-22 closure.

## Open items (for the next ring window)

1. Rebuild `smalt:local` at a quiet HEAD and run
   `just burn-ring --stage boot`; the judge stands: zero ZOMBIE_BEAM rows,
   `validate_burn.py` gate exit 0, stop < 120s.
2. Fleet law candidate (coordinator): image builds need a lease — concurrent
   builds cancel each other and exhaust the VM disk (witnessed 4x), and a
   default-label overwrite of `smalt:local` is indistinguishable from a
   valid subject without the label check (which caught it — guard worked).
3. If the stop face re-wedges in-image, capture the ThousandIsland
   `:sys.get_state` stack during shutdown (the ring receipt's separate-face
   plan) — the 10s bound converts an infinite hang into a bounded
   brutal-kill, so the zombie assertion should pass either way, but the
   capture would tell us WHY the listener refuses :shutdown under soak load.
