# BK-CENS2 — census registration round 2

- **Date**: 2026-10-22
- **Lane**: BK-CENS2
- **Context**: solo (shared, actively-edited checkout)
- **Standing**: **ALIVE** — census 6/6 green on the registered population; all 4 dispatched files verified + registered + run green. Two follow-up drifts found by the sweep and registered; one in-flight file name registered to stop fence re-drift.

## Step 1 — files + receipts verified on disk

All 4 dispatched court files exist; all 4 lanes' receipts on disk:

- `test/internal/expl9r1_egress_guard_court_test.exs` + `docs/jira/v26.10.22/receipts/expl9r1-egress-guards.md`
- `test/internal/expl9r2_arm_guard_court_test.exs` + `docs/jira/v26.10.22/receipts/expl9r2-arm-guards.md`
- `test/internal/mcpt1_dispatch_court_test.exs` + `docs/jira/v26.10.22/receipts/mcpt1-descriptor-regen.md`
- `test/internal/kd169r_cred_gate_test.exs` + `docs/jira/v26.10.22/receipts/kd169r-cred-gate.md`

## Step 2 — registrations (tier + typed exemptions)

`test/internal/internal_tier_census_test.exs`:

| file | tier | exemptions | justification |
|---|---|---|---|
| expl9r1_egress_guard_court_test.exs | :wire | [:client_token] | real loopback raw-Erlang-HTTP-client egress court; status checks on the wire |
| expl9r2_arm_guard_court_test.exs | :wire | [:client_token, :arm_literal] | real loopback ARM guard court with subscription-scope URLs against real ARM error bodies |
| mcpt1_dispatch_court_test.exs | :internal | [:client_token, :status_literal] | in-process conn-dispatch court over Smalt.Mcp.Router (conn helper + JSON decode; conn.status dispatch check) |
| kd169r_cred_gate_test.exs | :wire | [:client_token] | real loopback credential-gate court; 401 refusal is a string match, :wire class carries it (BK-CENS pattern) |

Observables allowlist additions: `Smalt.Test.Internal.Expl9r1EgressGuardCourtTest`,
`Smalt.Test.Internal.Expl9r2ArmGuardCourtTest`, `Smalt.Internal.Kd169rCredGateTest`,
`Smalt.Mcp` (prefix covering Descriptor/Router).

## Step 3 — SLEEP-CLASS

Census sleep scan green over the full directory: zero unaudited sleeps in any
new file. No `# SLEEP-CLASS:` annotations were needed (none of the 7 files
contains a `Process.sleep` outside the audited poll helper).

## Step 4 — census green + per-file runs (real output, MIX_BUILD_ROOT=_build-bkcens2)

Census (before state, pre-registration): 1/6 — population fence + scans naming
the unregistered files. After:

```
......
Finished in 0.1 seconds (0.1s async, 0.00s sync)

Result: 6 passed
```

Per-file runs (embedded verbatim tails):

```
expl9r1_egress_guard_court_test.exs      Result: 5 passed
expl9r2_arm_guard_court_test.exs         Result: 8 passed
mcpt1_dispatch_court_test.exs            Result: 9 passed
kd169r_cred_gate_test.exs                Result: 8 passed
expl10r2_court_test.exs                  Result: 11 passed
expl11r1_ledger_range_court_test.exs     Result: 4/5 passed  (1 failure, see below)
expl11r2_wps_service_events_court_test.exs  Result: 1/3 passed  (2 failures, see below)
```

The two failures are NOT this lane's surface and NOT census classes:

- **expl11r1** ("valid range semantics unchanged"): half-open range
  `rangeBegin=3.1` returned `["3.1"]`, court expected `["3.1","4.1"]` —
  an EXPL11-R1 repair-semantics question owned by that lane (lib/smalt/confidential_ledger
  repair in flight; EXPL-11 receipt classifies F1 repair landed, this
  half-open case is mid-tuning).
- **expl11r2** (in-flight EXPL11-R2 court, no receipt yet): F2a witness
  `delivery_status` stays `"pending"` (expected "refused") and F3b crashes
  `Smalt.WebPubSub` with a FunctionClauseError on
  `{:delivery_result, id, false, "no_handler"}` (3-arity cast has no
  matching clause in `lib/smalt/webpubsub/service.ex:99` — repair not yet
  landed in lib/). Both point at the EXPL11-R2 lane's unlanded repair, not
  at registration.

Also witnessed during this session (pre-existing, transient): a compile
freeze on `lib/smalt/webpubsub/service.ex` (`prune_members/3` undefined,
EXPL11-R2 mid-edit) self-cleared within the ~10-min SLA window. No edit
applied by this lane.

## Step 5 — sweep for landed-but-unregistered files

`git log --since='2 hours ago' --name-only -- test/internal/` vs the census
registered list + disk diff found 3 more drifts, all registered:

| file | tier | exemptions | note |
|---|---|---|---|
| expl10r2_court_test.exs | :internal | [:client_token, :status_literal] | EXPL-10 follow-up court (conn-dispatch over PushRouter/LawCompiler); runs 11/11 green |
| expl11r1_ledger_range_court_test.exs | :wire | [:client_token] | real curl-over-loopback court; registered, 4/5 (failure owned by EXPL11-R1) |
| expl11r2_wps_service_events_court_test.exs | :internal | none | IN-FLIGHT name registered to stop fence re-drift; content scans still apply — any forbidden token the owning lane adds fails the census loudly. Allowlist: `Smalt.Internal.Expl11R2WpsServiceCourtTest`, `Smalt.WebPubSub` prefix, `Smalt.ConfidentialLedger` prefix, `Smalt.EventGrid.PushRouterPlug`, `Smalt.Test.Internal.Expl10r2CourtTest` |

Also disclosed: two pre-existing BK-CENS comment lines inside the census
file itself tripped the honest self-scan (comment text naming "Plug.Test" /
"Jason decode" literals and an "assert + status number" co-occurrence);
reworded in place — comment text in the census must not contain the literal
tokens the scans match.

## Verdict

Population fence sealed at the current tree snapshot: every file in
`test/internal/` is registered with tier + typed exemptions; census 6/6.
Residual test failures in expl11r1/expl11r2 are owned by the EXPL-11 lanes'
in-flight repairs (witnessed above with verbatim output) — they are test
failures, not census classes, and do not re-drift the fence.

## Replay

```bash
export PATH="$HOME/.asdf/shims:$PATH"
cd /Users/sac/smalt
MIX_BUILD_ROOT=_build-bkcens2 mix test test/internal/internal_tier_census_test.exs   # 6 passed
for f in expl9r1_egress_guard_court_test.exs expl9r2_arm_guard_court_test.exs \
         mcpt1_dispatch_court_test.exs kd169r_cred_gate_test.exs \
         expl10r2_court_test.exs expl11r1_ledger_range_court_test.exs \
         expl11r2_wps_service_events_court_test.exs; do
  MIX_BUILD_ROOT=_build-bkcens2 mix test test/internal/$f
done
```
