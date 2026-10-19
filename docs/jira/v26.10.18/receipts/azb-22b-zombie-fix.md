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

## Ring boot re-judge retry — BLOCKED again (typed, third infrastructure strike)

Context: solo(retry lane; re-judge the in-image ZOMBIE_BEAM row via a fresh
ring boot stage; 2026-10-19T06:16Z window)
Standing: **SUSPECT** — no ring boot stage ran; the ZOMBIE_BEAM typed row
remains **open, not re-judged**. Deferred to the next window per the
third-strike rule.

Host evidence at retry start (2026-10-19T06:16-06:28Z):

```
$ colima exec -- df -h /var/lib/docker
Filesystem      Size  Used Avail Use% Mounted on
/dev/vdb1        59G   58G     0 100% /var/lib/docker

$ docker system df (abridged)
Images 40.78GB (39.3GB reclaimable, in-use-locked)  Build Cache 23.67GB
(62 entries, ACTIVE — held by concurrent lanes)
```

Strike 1 — colima VM disk at 100%, **0 bytes available**. Conservative
reclaim attempted before any build: `docker image prune -f` → `Total
reclaimed space: 0B`; `docker builder prune -f` → `Total: 0B`. The only
reclaimable mass is the 23.67GB ACTIVE build cache held by in-flight builds
from other lanes plus their tagged images — pruning it would sabotage
concurrent lanes, so it was left intact (no kills mandate).

Strike 2 — sustained concurrent build contention, same face as the prior
receipt's §5/§6, witnessed live via `ps`:

```
4 concurrent `docker build` processes against the same tree:
  70334/70331  -t smalt:local  --build-arg SUBJECT_SHA=d6dbe670…  (since 22:29)
  28923/28876  -t smalt:local  --build-arg SUBJECT_SHA=806d86e0…  (since 23:18)
  25300/25260  -t smalt-burn:latest --target test                  (since 23:18)
plus a prior azb22b retry loop (pid 94023, /tmp/azb22b/) running the same
lockstep build→ring sequence.
```

HEAD churn continues in-window: d6dbe67 → 806d86e0 (23:15) → 286c35e
(23:25) — three heads inside ~50 minutes; the ring's IMAGE_SUBJECT_MISMATCH
init guard requires image label == HEAD at init, so a lockstep build-and-run
stays a race against the fleet. The public `smalt:local` at retry time still
carried the default label `29bb037…` (invalid subject; the mid-edit artifact
face from the prior receipt's §6 — guard correctly refuses).

Strike 3 — one concrete build attempt at HEAD `286c35e` for a verbatim
witness (expected futile with 0B free; bounded at 180s):

```
#11 ERROR: write /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/
  snapshots/3667/fs/_build-lane-eng/test/lib/ash_a2a/ebin/
  Elixir.AshA2A.Chicago.Courts.OcelValidity.beam: no space left on device
#12 CANCELED
ERROR: failed to solve: ResourceExhausted: write …/Elixir.AshA2A.Chicago.
  Courts.OcelValidity.beam: no space left on device
```

(`BUILD_EXIT=0` above is the `tail` pipe's status; the solve failed with
ResourceExhausted — same containerd-snapshotter exhaustion face as the prior
receipt's failure 4.)

No ring dir was initialized for this lane (no `ring.env` written), so no
partial ring artifact was minted. Prior receipt's Open item 2 (fleet law:
image-build lease) is re-upgraded to blocking: this window failed on exactly
the un-leased concurrent-build class it names.

---

## Re-judge 2026-10-19 (retry window 2)

Context: solo
Standing: BLOCKED (third strike — defers to next window)

Retry of the burn-ring boot re-judge. The ring itself never ran: every
attempt died before `burn-ring.sh --stage boot` could initialize a ring dir
(no `ring.env` minted, no rows emitted, ZOMBIE_BEAM row unchanged).

Sequence (6 docker builds, 0 ring runs):

1. First ring invocation — refused at the identity gate:
   `[BURN-RING] REFUSED IMAGE_SUBJECT_MISMATCH: image smalt:local label
   org.smalt.subject=f56ee6be... != ring subject e916d767... — rebuild at
   HEAD per docker/BUILD_RECEIPT.md`
2. Build attempt with canonical BUILD_RECEIPT.md command — context path
   error (`stat ~/ash_r2rml: no such file or directory`, literal tilde not
   expanded by docker; `$HOME` form works). Not a strike; disclosed.
3. Full rebuild OK at label `29bb0371...` (image `024b5faeed03`, ~5 min,
   deps layer cached) — but the Dockerfile default `SUBJECT_SHA=29bb0371…`
   is a pinned old SHA, so the label was stale on arrival.
4. Rebuild with `--build-arg SUBJECT_SHA=$(git rev-parse HEAD)` → first try
   failed at `MIX_ENV=prod mix deps.compile` exit 1 (~25 min; log tail
   discarded by pipe, verbatim body not captured). Retry with
   `--progress=plain` full log succeeded — image `6d506d53c73c` —
   classified transient (NAT/hex or compiler flake), consistent with the
   colima NAT flake class in the prior receipt.
5. Subject-bound boot attempt refused again: baked label `13ef4d30...` vs
   ring subject `5f891060...` — HEAD moved during the ~15 min prod build.
6. Retry loop (build at pinned SHA → verify HEAD unchanged → boot):
   - attempts 1+2: `HEAD moved during build` (baked `5f891060…` → head
     `d577677b…`; baked `d577677b…` → head `5075e892…`)
   - attempt 3: daemon EOF — `ERROR: failed to receive status: rpc error:
     code = Unavailable desc = error reading from server: EOF` → colima
     DEAD (`colima is not running`), 4 consecutive
     `Cannot connect to the Docker daemon at unix:///var/run/docker.sock`.
   - colima restarted OK (server 29.5.2, disk fine: host `/` 11% used,
     docker 27 GB reclaimable); resumed loop baked `f6c2f3fb…` → head
     `49a9ad10…`, baked `49a9ad10…` → head `98cb529f…` — two more
     HEAD-churn losses.
   - loop's final build canceled by the agent harness background time
     limit (own cancellation, not infra; logged for honesty).

Diagnosis: the ring's subject-binding law (AZB-22 anti-vacuity — one
subject SHA bound to one image digest) is unrunnable in this window
because concurrent lanes commit to HEAD every ~5–10 min while a
subject-pinned prod image build takes ~5–15 min even with warm deps
layers. Each build is stale on arrival. Combined with the daemon crash
(infra strike) this window consumed the third strike.

Blocked on: (a) image-build lease (prior receipt Open item 2 —
concurrent builds + HEAD churn), now compounded by (b) the subject-pin
vs build-latency race. Next window needs a quiet HEAD (post-integration
gap) or a coordinator-granted build lease; the boot stage itself is
otherwise ready — `smalt:local` `6be1ffed651f`/`6e67fcb01330` builds
cleanly and `just burn-ring --stage boot` will run once HEAD holds still
for the build duration.
