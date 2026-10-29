# Receipt: JA-10 — Joe Armstrong transparency court (OTP-29 lane)

Context: solo

**Standing:** **ALIVE — court 5/5, verified twice consecutively (2026-10-22T03:19Z)**

Date: 2026-10-22 · Lane: JA-10 · Build root: `_build-ja10` ·
Toolchain: OTP 29.1.2 + Elixir 1.20.4-otp-29 (the `.tool-versions` pin; lane shell
defaulted to a stray OTP 28 via `.erlmcp` PATH — corrected, same correction the
IMPL-6 receipt records).
Machine: `{"cpu":"Apple M3 Max","cores":16,"otp":"29.1.2","elixir":"1.20.4-otp-29","darwin":"26.2"}`
HEAD at final verification: `5946a807d25ca9146c2320127aca3bc460e868fb`

## Subject

`/Users/sac/smalt/test/integration/ja10_transparency_court.exs` — five legs, all
real collaborators, no mocks, no sleeps (bounded polls and timeout-bounded sys
calls only):

1. **sys:get_state census** — recursive supervision-tree walk from
   `Smalt.Supervisor` (835 members), every member answers `:sys.get_state/2`
   within a 2.5 s per-op bound (Task-wrapped, typed skips only). Observed:
   **835 answered / 0 typed skips**. Census boundary is documented in-file:
   the walk carries child type from the parent's `which_children` (never
   probes a worker — probing kills it), keeps reference-id supervisors (Bandit
   listeners) WITHOUT descending into their per-connection forest, and filters
   the documented transient classes (`Task.Supervised`, Bandit/ThousandIsland
   handlers).
2. **proc_lib label census** — same 835 members: **422 labeled /
   408 supervisor-exempt / 5 named-exception**. The 5 documented exceptions
   (pre-IMPL-6-schema infra workers, adoption pending; the anti-vacuity
   assertion fails the court if an allowlist entry ever has no observed
   unlabeled referent, and any NEW unlabeled worker fails the court):
   `Smalt.Telemetry.RollingCounters`, `Smalt.Monitor.Metrics`, `Smalt.Store`,
   `Smalt.Plane.Identity.StsGate`,
   `Smalt.Affidavit.WasmEngine.Supervisor.Owner`.
3. **crash court** — real `Smalt.ArmGateway.LRO.Sweeper` instance (test-owned,
   `tick_ms: :manual`) killed by a real unknown-call exit; captured crash
   report renders `Process Label:` with `service: :arm` / `role: :lro_sweeper`
   (IMPL-6 AR-OBS-02 pattern re-proven at this lane's toolchain).
4. **telemetry leg** — real `:gen_tcp` HTTP wire request
   `GET /subscriptions/…/locations?api-version=2021-04-01` against the
   self-booted ARM Bandit listener → 200, and `[:bandit, :request, :stop]`
   observed by a test-attached `:telemetry` handler with
   `plug = {Smalt.ArmGateway.Router, []}` and the matching `request_path`.
5. **observer-effect check** — 120 real HTTP requests (24 concurrent) in
   flight while 3 full-tree introspection sweeps run: sweeps complete in
   269–431 ms each with **835/835 answered per sweep**, load completes
   **120/120 with zero transport errors**, all 2xx.

Court gate (run twice, both green):

```
MIX_ENV=test MIX_BUILD_ROOT=_build-ja10 mix test test/integration/ja10_transparency_court.exs --include ja10_transparency_court
→ Result: 5 passed   (0.00s async, ~2s sync; run 1: 03:19:24Z, run 2: 03:19:37Z)
JA10 leg1 census size=835 … 835 answered / 0 typed skips of 835 tree members
JA10 leg2 label census: 422 labeled / 408 supervisor-exempt / 5 named-exception
JA10 leg5 sweeps: [379, 431, 419]ms … [835, 835, 835] answered   (run 1)
JA10 leg5 sweeps: [403, 403, 410]ms … [835, 835, 835] answered   (run 2)
```

## Disclosures (compile-freeze SLA)

- **Compile-unblock fix applied to another lane's in-flight file**
  (`lib/smalt/apim.ex`, the JA-1/JA-4 edit): that edit's
  `GenServer.start_link(__MODULE__, :ok, name: {:local, __MODULE__})` is
  rejected outright by Elixir 1.20.4's `GenServer.do_start/4` — it broke
  every app boot tree-wide (reproduced: `{:error, {:smalt, {{:shutdown,
  {:failed_to_start_child, Smalt.Apim, {:EXIT, {%ArgumentError{message:
  "expected :name option … Got: {:local, Smalt.Apim}"}}}}, …}}`). Minimal
  fix: pass the bare atom (`name: __MODULE__`, identical semantics), with an
  in-place comment naming this receipt. Also observed in that file: a
  duplicate-`init/1` clause warning (`def init/1 was previously defined,
  lib/smalt/apim.ex:59`) — NOT touched; flagged to the owning lane.
  NOTE: the boot failure fired intermittently across my probe runs before the
  fix (first census probe booted fine), so the owner lane may not have hit it.
- **Pre-existing defect witnessed (NOT fixed — outside lane ownership)**:
  `Smalt.HealthPlug` sends the `/healthz` response without `halt()`, so the
  egress pipeline continues into `CORSPlug`, which calls
  `register_before_send/2` on an already-sent conn → `Plug.Conn.
  AlreadySentError` kills the Bandit connection process AFTER the response is
  delivered. Visible on every egress `/healthz` wire request; the court routes
  its wire legs around it and asserts on the clean ARM locations face. Owning
  surface: egress router / health plug (fix: `halt` the conn in the healthz
  clauses, or a completion plug).

## Lane hygiene

- Court file: `test/integration/ja10_transparency_court.exs` (untracked,
  lane-owned). Receipt (this file). No shared-infra edits
  (scripts/bench/, REGISTRY, justfile.d untouched).
- Transient probe file `test/tmp_ja10_probe_test.exs` deleted.
- The earlier IMPL-6 anti-vacuity assertion in an intermediate run flagged
  "allowlist entry … no observed unlabeled referent" — that was the
  `process_info(pid, :label)` `:undefined` handling defect in the court
  itself (the atom `:undefined` is NOT a label), fixed in the court, not
  papered over.
