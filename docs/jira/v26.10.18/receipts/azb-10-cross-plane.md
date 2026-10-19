# Receipt: AZB-10 Cross-plane wiring (loopback, zero egress)

- **Ticket**: AZB-10 (`docs/jira/v26.10.18/azsim-burn/TICKETS.md`, binding)
- **Subject**: `config/env/az_prod_{control,identity,data,integration}.exs`,
  `lib/smalt/egress_router.ex` (nested `Smalt.EgressRouter.Peers` — peer
  resolution only; router dispatch untouched), `test/azsim/topology_test.exs`.
  Disclosed one-line seam: `lib/smalt/arm_gateway/router.ex`
  `handle_resource_put/5` now calls
  `Smalt.EgressRouter.Peers.emit_resource_write_success/2` (the Accept gate
  "ARM PUT ⇒ Service Bus subscriber receives ResourceWriteSuccess" cannot be
  satisfied without a call site in the PUT path).
- **Status**: ALIVE
- **Commit**: not minted (no-git constraint per dispatch)

## Landed

1. **Peer endpoints by config** (`config/env/*.exs`): every plane profile now
   pins `config :smalt, :peers, ...` — loopback-only endpoints
   (`identity: "https://127.0.0.1:9444"` per spec, control/data/integration
   likewise). Ports stay in their AZB-04 flat single-source keys; the peers
   map names planes, never ports of its own.
2. **Peer resolution + egress guard** (`Smalt.EgressRouter.Peers`):
   - `resolve/1` — config-driven, no in-process short-circuit;
   - `guard/1` — non-loopback / non-peer outbound endpoint ⇒
     `{:refused, :R_missing_authority}`, ETS counter
     (`:smalt_egress_guard`/`:refused`), telemetry `[:smalt, :egress, :refused]`
     with `%{reason: :R_missing_authority}`;
   - `emit_resource_write_success/2` — Event Grid `resources` topic fan-out +
     Service Bus bridge enqueue (queue `resourcewritesuccess`), fail-safe
     (never alters the PUT response).
3. **Topology court** `test/azsim/topology_test.exs` — 8 tests, all legs over
   REAL sockets (falsifier discipline: no in-process resolution).

## Accept evidence (real output)

- `MIX_BUILD_ROOT=_build-lane-azb10 mix test test/azsim/topology_test.exs`
  → `8 tests, 0 failures` (both cross-plane token legs mint over real TCP to
  the identity STS listener, then present at the data-plane sibling seat —
  cross-seat acceptance rides the mint-time trusted-authority registry; the
  PUT leg carries a wire-minted bearer and returns 202).
- Foreign-signed token → 401 `SignatureVerificationFailed`; foreign-issuer
  token (correct secret) → 401 `IssuerMismatch`.
- ARM PUT ⇒ Event Grid subscriber `assert_receive {:event_grid, "resources",
  "azb10-topology", _id, event}` with
  `event_type == "Microsoft.Resources.ResourceWriteSuccess"` and matching
  `data.resourceUri`; Service Bus bridge: `QueueStore.dequeue_matching`
  returns the same event body.
- Egress-guard counter delta over the wire legs = 0 (zero egress over the
  suite's cross-plane calls). Deliberate refusals increment by exactly 1 with
  witnessed telemetry delivery.

Raw run (final, post-shim-restore):

```
19:12:49.135 [info] Sent 401 in 34µs
...
Finished in 4.1 seconds
183 tests, 2 failures   <- the 2 are AdversarialJoe vectors, see below
```

Scoped run of this ticket's file:

```
Finished in 0.4 seconds (0.00s async, 0.4s sync)
8 tests, 0 failures
```

## Anti-vacuity (witnessed, SHIM-COURT protocol)

BASELINE sha256 `lib/smalt/auth/bearer.ex`:
`eae3eded2da4fb16915a1cae1c7f585a59eed0c5ee85ae727f59b37b6c23496e`

- BEFORE: foreign-issuer test PASS (8/8, above).
- SHIM (`# SHIM-COURT (AZB-10 anti-vacuity witness): issuer check disabled` —
  the `not issuer_ok?(claims["iss"], conn)` refusal clause removed from
  `validate_claims/2`):

```
     foreign-issuer token was accepted: 200
     code: assert res.status == 401, "foreign-issuer token was accepted: #{res.status}"
     stacktrace:
       test/azsim/topology_test.exs:131: (test)

Finished in 0.7 seconds (0.00s async, 0.7s sync)
1 test, 1 failure (7 excluded)
```

- AFTER: the flip IS the proof — with the issuer check disabled the
  foreign-issuer token is ACCEPTED and the test FAILS. A court that cannot
  flip is FAIL; this one flips.
- RESTORE: `git show HEAD:lib/smalt/auth/bearer.ex > lib/smalt/auth/bearer.ex`
  → sha256 `eae3eded2da4fb16915a1cae1c7f585a59eed0c5ee85ae727f59b37b6c23496e`
  — byte-exact (equal to BEFORE).

## Falsifier check

- In-process cross-plane resolution: the two token legs and the PUT leg all
  cross real sockets (`SmaltTest.Wire.http_request` raw `:gen_tcp`); the
  falsifier never fires.
- Non-loopback egress: egress-guard counter delta 0 across the wire legs.

## Caveats / gaps named (per dispatch)

- **AZB-07 / AZB-08 receipts outstanding** (dispatch caveat). The consumed
  surfaces were verified directly in `lib/`: STS mint path
  (`lib/smalt/arm_gateway/router.ex` `issue_token/2` — real HS256 mint,
  trusted-authority registration, discovery-doc issuer derivation) and the
  integration surface (`lib/smalt/messaging/event_grid.ex` at-least-once
  engine + `lib/smalt/messaging/amqp/queue_store.ex`). Both work; no gap
  blocks this ticket. The `:peers` profile keys land in this ticket and the
  read site consumes app env directly (`Smalt.Config` is ontology-generated;
  no hand-edit) — when the ontology adds `smalt:ConfigKey :peers`, the
  accessor can be projected and the read site re-pointed.
- **Pre-existing, out-of-lane failures observed (not session-introduced)**:
  `test/azsim/adversarial_joe_test.exs` Vectors 1 and 3 fail identically
  (a) with this ticket's test file removed from the run and (b) on the shared
  baseline `_build` — while `lib/smalt/messaging/amqp/connection.ex` is
  modified in the worktree by another lane. Not touched by AZB-10.

## Standing

ALIVE — all Accept gates executed with real output on this ticket's subject;
anti-vacuity witnessed; zero-egress and zero-Process.sleep laws hold
(`grep -n "Process.sleep"` on touched files: comment-only hit).
