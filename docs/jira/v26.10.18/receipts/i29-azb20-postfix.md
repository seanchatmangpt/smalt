# i29 — azb-20 postfix re-test (GAP-AZB20-1/4)

- Date: 2026-10-19
- Subject: smalt HEAD `502c4ed` (post 9a351e3), canonical checkout, no lib/ edits by this lane.
- Context: solo(full orchestrator pass + offline audit replay + regression tier, machine shared with court23 quiet window)

## Per-cell verdicts vs the 4 open cells — ALL FOUR STILL OPEN

Root cause re-confirmed on HEAD: `lib/smalt/plane/control_supervisor.ex`
(current source read on disk) has **no `Smalt.Store` child** — the Option-A
mount from GAP-AZB20-1-PLAN.md edit 1 never landed. Edits 2 (crash-path
header plug, `use Plug.ErrorHandler` absent from
`lib/smalt/arm_gateway/router.ex`) and 3 (ARM-router ResourceGraph route;
the route exists only at `lib/smalt/egress_router.ex:1515`) also absent.
9a351e3 landed data-plane-only work (comp whitelist, cosmos bulk, KV
update_key_properties, RG data-plane engine).

1. **Cell 1 / header audit (expect 0 violations): FAIL — 34 violations**
   (control). Recomputed offline from `tmp/azb20/capture-control.jsonl`
   (44 responses) with the exact `recording-proxy.mjs` rules: all 500-class
   crash responses (GET /subscriptions, PUT resourcegroups, NSG PUT/GET)
   missing `x-ms-request-id` — crash path bypasses `arm_request_id`
   `register_before_send` exactly as the plan predicted. Data plane: PASS,
   0 violations.
2. **Cell 2 / arm-resources (expect 404, got 500): FAIL.** Control boot
   answers 500 on `GET /subscriptions`, `PUT .../resourcegroups/...`,
   NSG PUT/GET — Store-unmounted ARM routes raise → adapter-rendered 500.
   `grep "Sent 500"` shows zero-bandit-rendered 500s in the substrate log,
   i.e. all 500s are crash-rendered outside the plug chain.
   `test/sdk-full/.logs/azb20-control-substrate.log`.
3. **Cell 3 / resourcegraph (expect 400 BadQuery, got 404): FAIL.**
   `POST /providers/Microsoft.ResourceGraph/resources` → 404 on the control
   boot (ARM router catch-all). Route exists only on EgressRouter
   (`lib/smalt/egress_router.ex:1515` — note path typo in this line only,
   actual file `lib/smalt/egress_router.ex`), which is not booted on
   control-only planes.
4. **Cell 5 / keyvault+secrets (expect pass, got 503): FAIL.**
   `POST /keys/ts7-rsa/create` → **503 RouteNotReady** (Store tables absent
   on control boot; `TlsTwinDispatch` → EgressRouter not_ready? guard).
   Repeated 503s across /keys, /secrets traffic in
   `test/sdk-full/.logs/azb20-control-substrate.log` (01:18 window).

## Matrix (MIX_BUILD_ROOT=_build-ft-az20, private block 39443-39475)

- control: arm-resources FAIL(1), resourcegraph FAIL(1), keyvault FAIL(1),
  secrets FAIL(1); appconfig/blob/cosmos/ledger/eventgrid/eventhubs/sentinel
  typed PLANE-DOWN(2); **header audit FAIL(1), 34 violations**.
- data: blob PASS, ledger PASS, header audit PASS (0 violations);
  **cosmos FAIL(1)** — new observation, unclassified this lane (probe tail
  lost to run termination; data log shows repeated 404s on /dbs traffic);
  arm-resources/resourcegraph/appconfig HARNESS-SKIP(3); kv/secrets + all
  integration probes typed PLANE-DOWN(2).
- integration / identity: all cells typed PLANE-DOWN(2) as designed
  (no matching listeners).

Run was terminated (SIGTERM) mid-identity-plane by the coordinator stop
order; `tmp/azb20/matrix.json` was NOT rewritten (still 00:22 stale);
console matrix preserved in `tmp/azb20/i29-sdk.log`.

## Regression tier (MIX_BUILD_ROOT=_build-ft-az20reg)

`mix test test/data_plane/ test/arm/ test/wire/ test/azsim/` →
**606 tests, 8 failures (11 excluded)**. Identified heads:
1. `Smalt.Azsim.AdversarialJoeTest` Vector 3 half-open TCP MatchError
2. `SmaltTest.Azsim.TopologyTest` identity-plane STS over the wire
3. `SmaltTest.Azsim.TopologyTest` ARM ResourceWriteSuccess event

Remaining 5 failure heads not captured (grep window); run was concurrent
with the azb20 substrate (possible port/contention coupling), not
classified as pre-existing vs session-introduced. Unclassified, reported
as-is.

## Standing: SUSPECT — cells open, fixes absent from HEAD

Next action stays as planned (GAP-AZB20-1-PLAN.md edits 1-3). No GAP flips.
No bench lane, no lib/ edits, no canonical-port touches by this lane. All
lane substrates torn down (private block verified free).
