# Receipt: AZB-15 Plane subtree DR kills (enterprise disaster scenarios)

Context: solo (dr_scenarios_test.exs 4/0)

- **Ticket**: AZB-15 (`docs/jira/v26.10.18/azsim-burn/TICKETS.md`, binding).
  The dispatch named `azb-15-plane-dr.md`; the ticket's Receipt path
  (`azb-15-dr-subtrees.md`) is binding and used here.
- **Subject (this session's working diff)**:
  - `lib/smalt/plane/identity/sts_gate.ex` — the identity subtree owns a real,
    killable child (`Smalt.Plane.Identity.StsGate`); `mint_allowed?/0` reads
    LIVE supervision state (child entry `:undefined` pid = kill window ⇒ 503;
    child absent = split boot / wire tree ⇒ open; app stopped ⇒ open). An
    earlier boot-marker design was REJECTED with a witnessed regression
    (arm_wire_test mint → 503, 2 failures) and replaced before landing.
  - `test/azsim/dr_scenarios_test.exs` — the 4-scenario DR court.
- **Commit**: coordinator-owned git; AZB-09/AZB-10 deps landed at HEAD
  (467d7d1 lineage). The first slice of this lane's files (identity_supervisor
  child, ARM-router mint gate, egress_router with_route store-down extension)
  was swept into a coordinator commit mid-session; the remaining working diff
  is exactly the files named above.
- **Status**: ALIVE (all Accept gates executed, falsifier + anti-vacuity
  witnessed; real output inline)

## Landed

1. **Identity subtree got real ownership of the STS mint gate** (defect fix):
   pre-fix, `Smalt.Plane.IdentitySupervisor` had an EMPTY child list — the
   ticket's scenario 3 kill was vacuous by construction (kill changes
   nothing). The mint path (`Smalt.ArmGateway.Router.handle_token/2`) now
   consults `Smalt.Plane.Identity.StsGate.mint_allowed?/0`: identity subtree
   configured+dead ⇒ typed 503 `StsUnavailable` (Retry-After: 1); cached-valid
   tokens keep passing because bearer validation is local (Joken, shared
   secret) — no runtime call into the identity plane.
2. **DR court** (`test/azsim/dr_scenarios_test.exs`, async:false, default
   `mix test` tier, 4 tests × 10 iterations, 40 kill/restart cycles):

   | # | Scenario | Kill window (declared blast radius) | Unkilled planes |
   |---|---|---|---|
   | 1 | Cosmos partition split | `terminate_child(DataSupervisor, Smalt.Store)` mid-query-stream ⇒ typed retryable 503 `RouteNotReady` (10/10), never untyped 500; whole-subtree edge ⇒ connection refused; restart ⇒ first-200 | control/integration/identity all serving |
   | 1b | (metric) | time-to-first-200: min/med/max 2323/2796/3110 µs, med reductions 110215 | |
   | 2 | Service Bus outage | `terminate_child(Smalt.Supervisor, IntegrationSupervisor)` ⇒ broker-side Connection dies ⇒ client socket `{:error, :closed}` (the `amqp:connection:forced` transport shape) 10/10; restart ⇒ fresh handshake over real TCP; settled message enqueued pre-kill survives (QueueStore rows live in the data-plane Store) — zero loss 10/10 | data/control/identity |
   | 3 | STS outage | `terminate_child(Smalt.Supervisor, IdentitySupervisor)` ⇒ NEW mints 503 `StsUnavailable` 10/10; cached token (minted pre-kill, enforce mode) STILL accepted by data plane 10/10 | data/control/integration |
   | 3b | (metric) | mint recovery (restart→200) deadline-bounded, observed < 1 poll round | |
   | 4 | ARM outage | `terminate_child(Smalt.Supervisor, ControlSupervisor)` ⇒ ARM port down (connection refused); data plane 200s CONTINUE 10/10; integration TCP keeps accepting | data/integration |
   | 4b | (metric) | ARM re-accept: min/med/max 491/539/581 µs | |

   Cross-plane assertion after every scenario: all four plane supervisors
   alive, data serving (typed), identity gate open.

## Accept evidence (real output)

- `MIX_BUILD_ROOT=_build-lane-azb15 mix test test/azsim/dr_scenarios_test.exs`
  → `4 tests, 0 failures` in 0.9 s:

```
[AZB-15] scenario-1-cosmos: n=10 recovery_us(min/med/max)=2323/2796/3110 recovery_reductions(med)=110215 kill_statuses=%{503 => 10}
[AZB-15] scenario-2-servicebus: n=10 ... (0 losses / 10)
[AZB-15] scenario-3-sts: n=10 ... (503 typed 10/10, cached-token 200 10/10)
[AZB-15] scenario-4-arm: n=10 recovery_us(min/med/max)=491/539/581
```

- Broad regression (same build):
  `mix test test/azsim/{dr_scenarios,plane_supervision,topology,data_plane,
  integration_plane,identity_plane,control_plane,graceful_stop,dets_recovery}_test.exs
  test/auth_enforce_test.exs test/smalt_arm_gateway_test.exs test/wire/
  test/eventgrid_arm_test.exs test/eventgrid_conformance_test.exs
  test/egress_dispatch_test.exs test/metadata_endpoints_test.exs`
  → `386 tests, 0 failures`.
- `python3 scripts/sleep_gate.py` → `[SLEEP-GATE] PASS — 333 files, 0 unclassified sleep primitives`.
- Zero compiler warnings from this lane's files (files appear nowhere in the
  warning list of the regression run).

## Falsifier check (ticket falsifier: a request on an unkilled plane fails during any scenario)

- Scenario-level: cross-plane assertions (data 200 during ARM kill; cached
  token accepted during STS kill; integration TCP during control kill; data
  typed-503-then-200 with control/integration/identity untouched) all green
  ×10. Zero cross-plane failures outside the declared blast radius.
- Witnessed regressions caught during the lane (fixed forward):
  - Boot-marker gate design leaked into ExUnit wire trees
    (`arm_wire_test` mint → 503 ×2). Replaced by live supervision-state read;
    `test/wire/ + auth_enforce + topology` 386-test regression then green.
  - `terminate_child` on a listener-owning subtree can race its port rebind
    → restart retry is deadline-bounded (`restart_subtree!/1`, backoff 25 ms).

## Anti-vacuity courts (SHIM-COURT protocol, witnessed flips)

BASELINE (post-landed-slice tree):
- sha256 `lib/smalt/auth/bearer.ex` = `eae3eded2da4fb16915a1cae1c7f585a59eed0c5ee85ae727f59b37b6c23496e` (also the pre-session HEAD blob — byte-identical restore)
- sha256 `lib/smalt/data_plane/cosmos.ex` = `82d3e66d3d672486c3920eb0f5b59339ccbe2b549a1bceb180bb87941e5b526a` (byte-identical restore)

- **Court A — scenario 3 has teeth** (the ticket's named anti-vacuity: "wire
  data plane to call identity in-process (shared process)"): shim in
  `lib/smalt/auth/bearer.ex` `verify_bearer/1` — marker `SHIM-COURT (AZB-15
  anti-vacuity)` — ties token VALIDATION to `StsGate.mint_allowed?/0`
  (validation now depends on the identity subtree process).
  BEFORE: scenario 3 green. SHIM run:

```
4 tests, 2 failures
cached-valid token rejected during identity outage (iteration 1): 401 {"error":{"code":"IdentityPlaneDown","message":"SHIM-COURT (AZB-15 anti-vacuity): token validation wired to the identity subtree process"}}
```

  The blast-radius assertion FLIPPED (PASS→FAIL). RESTORE:
  `git show HEAD:lib/smalt/auth/bearer.ex` → sha256 `eae3eded…` byte-exact
  (equal to baseline).
- **Court B — scenario 1 has teeth** (guard-disabled flip): shim
  `Smalt.DataPlane.Cosmos.store_ready?/0` → `true` (marker `SHIM-COURT
  (AZB-15 anti-vacuity witness)`):

```
4 tests, 4 failures
kill-window response was 500 "" — untyped failure
```

  The typed-503 assertion FLIPPED (PASS→FAIL: untyped 500). RESTORE:
  `git show HEAD:lib/smalt/data_plane/cosmos.ex` → sha256 `82d3e66d…`
  byte-exact.
  NOTE: an earlier Court-B attempt shimming `EgressRouter.not_ready?/2` did
  NOT flip (0 failures) — because `Cosmos.store_ready?/0` already guards the
  cosmos surface (the typed guard pre-exists in the landed deps). That
  attempt also witnessed that the first-cut `not_ready?` extension was
  REDUNDANT for the ticket scenarios; it stays only as belt-and-suspenders
  for the unguarded Store-backed routes (kv secrets / appconfig classes);
  disclosed as landed via the coordinator commit.

## Pre-existing failures (not session-introduced, witnessed)

- `test/azsim/azure_common_issues_test.exs` Vectors 1+6 fail IDENTICALLY with
  my working diff AND with it reverted to HEAD (sha-swapped A/B), scoped runs
  `6 tests, 2 failures` both ways. Surfaces (ETag CAS contention, CloudEvent
  routing) are outside this lane's diff. Concurrent-lane in-flight churn was
  observed on the shared tree (e.g. `azure_common_issues_test.exs` requiring
  a not-yet-existing `/burn-evidence/...` support file mid-session; deps/
  deleted and restored via `mix deps.get` mid-session). Not this lane's
  defect; flagged for the coordinator.

## Falsifiers left standing (informational)

- Cross-plane failure on an unkilled plane: NONE observed across 40 cycles.
- The scenario-2 metric rows report 0 because the integration scenario's
  recovery metric is the deadline-bounded reconnect handshake (gated by
  asserts, not wall-clock) — the ticket's "reported not asserted" law holds;
  the two measured metrics (scenarios 1 and 4) are reported above.

## Standing

ALIVE — all four scenarios green ×10 on a live all-planes node, falsifier
checked, both anti-vacuity courts flipped, restores byte-exact.
