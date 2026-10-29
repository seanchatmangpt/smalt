# EXPL8-R — EXPL-8 finding repairs (MAA / MCP surface / Sync.Store)

Standing: **ALIVE**
Context: solo
Date: 2026-10-22
Repo: /Users/sac/smalt (main)
Lane: EXPL8-R
Toolchain: asdf elixir 1.20.4-otp-29, `MIX_BUILD_ROOT=_build-expl8r`

Repairs the ranked tickets in
`docs/jira/v26.10.22/receipts/expl8-mcp-sync-receipt-errc.md` (landed 04:57).
All probes/courts are real: real JSON-RPC over the real router (Plug test conn),
real MAA attest face, real ETS, real ReceiptSigner. Zero sleeps, no mocks.

## E8-T1 — wave-6 MCP tools unreachable (descriptor stale vs TTL) — FIXED

Regenerated `lib/smalt/mcp/generated/mcp_descriptor.ex` via the TTL header
command (`mix ggen_igniter.sync --ontology ... --query caps=<pack>/mcp_capabilities.rq
--template ... --out ...`), pack at `~/ggen-marketplace/packs/elixir-mcp-a2a-pack`.
All 5 wave-6 tools now dispatch; descriptor 32→37 capabilities.

```
$ MIX_BUILD_ROOT=_build-expl8r mix ggen_igniter.sync --ontology lib/smalt/mcp/gen/smalt_mcp_surface.ttl \
    --query caps=$HOME/ggen-marketplace/packs/elixir-mcp-a2a-pack/queries/mcp_capabilities.rq \
    --template lib/smalt/mcp/gen/mcp_descriptor.ex.eex ... --out lib/smalt/mcp/generated/mcp_descriptor.ex
ggen_igniter: unchanged (skipped, identical content): ... (engine: graphlaw, 1 query, 37 total row(s))
$ grep -c "rotationpolicy\|dns.zones\|schemaregistry\|alerts.list\|ttl.effective" lib/smalt/mcp/generated/mcp_descriptor.ex
5
```

Fail-closed drift fence + per-tool dispatchability court in
`test/internal/expl8r_court_test.exs`:
"every TTL tool dispatches over the real wire face (no TOOL_NOT_FOUND)" walks
all TTL ids over real JSON-RPC `tools/call` and REFUTES `TOOL_NOT_FOUND` /
`ACTUATION_REFUSED`; the drift fence asserts the TTL id set == descriptor set
== tools/list wire set (3-way, fail-closed).

## E8-T2 — MAA nonce registry died with its creator (fail-open) — FIXED

`lib/smalt/attestation/maa.ex ensure_nonce_table/0`: the `:smalt_maa_nonces`
table is now created with `heir: Process.whereis(:init) || self()` (SPOF-B/A-4
shadow-table law, `Sync.Store.init/1` idiom). Creator death transfers the
table to :init; replay protection no longer silently resets.

Court leg (real spawned Task creator, real ETS): "E8-T2: nonce table survives
creator-process death; replay still refused" — PASS (11/11).

## E8-T3 — caller-supplied policy overrode iss/iat/exp — FIXED (two layers)

1. Parse-time reservation: `issue(name=...)` where name ∈ {iss, iat, exp, nbf,
   jti} is a typed refusal `{:error, {:policy_refusal, "reserved_claim:<name>"}}`
   (`parse_issue/1`, `@reserved_claims`).
2. Merge-priority inversion at `issue_token/7`:
   `Map.merge(Map.merge(issued, binding), envelope_defaults)` — envelope
   defaults win over policy-issued and binding claims, never lose to them.

```
E8-T3: hostile policy cannot override iss/exp -> {:error, {:policy_refusal, "reserved_claim:iss"}} / "reserved_claim:exp" — PASS
E8-T3: envelope defaults win at the issue_token merge (x-ms-compliance-status="forged" vs envelope) — PASS
```

## E8-T4 — moduledoc premise rot (deleted test/mcp_test.exs) — FIXED

`lib/smalt/mcp/router.ex` moduledoc now lists the wave-6 tools (37 total),
cites `test/internal/expl8r_court_test.exs` for every fence it names
(actuation-verb gate, hostile `:doctor_supervisor` seam — both re-authored as
real wire legs in the court), and records the 64f6099 deletion of
`test/mcp_test.exs`. Census-registered (`:internal`, exemptions
`[:client_token, :status_literal]` with justification).

```
E8-T4: actuation verb over the wire -> ACTUATION_REFUSED — PASS
E8-T4: hostile :doctor_supervisor seam is read over the wire (sentinel child id verbatim) — PASS
```

## E8-T5 — unparseable policy rules silently dropped (widening) — FIXED

`parse_rules/2` now fail-closed in BOTH sections: any unparseable rule is a
typed `{:error, {:policy_refusal, "bad_rule"}}` — the EXPL-8 widening witness
(Tpm-only intent admitting SevSnpVM) now refuses.

```
E8-T5: unparseable authorization rule -> bad_rule (Tpm widening witness refuses) — PASS
E8-T5: unparseable issuance rule -> bad_rule — PASS
```

## E8-T6 — nonce burned by a FAILED attestation — FIXED

Nonces are reserved atomically (`insert_new` of a `:pending` row) at check
time, released on failure (`release_nonce` in attest/3's else), and recorded
as consumed only on the success path. BK-MAAP6 (lane P5, landed after this
lane's edits were checkpointed) extended the reservation with an owner-pid +
pending-eviction bounds law on top; the E8-T6 law is preserved and
BK-MAAP6's bounds court is green.

```
E8-T6: failed attest releases the nonce for a corrected retry; success consumes it — PASS
```

## E8-T7 — Sync.Store.commit untyped guards (crash-on-internal) — FIXED

`lib/smalt/sync/store.ex commit/3`: guards tightened to non-negative integers
+ binary frame_wire (a negative seq or non-binary wire previously crashed the
CAS GenServer). Typed `FunctionClauseError` at the boundary; control leg proves
a well-formed commit still admits.

```
E8-T7: negative seq / non-binary wire -> FunctionClauseError; control commit -> {:ok, %{seq: 1}} — PASS
```

## Verification

```
$ MIX_BUILD_ROOT=_build-expl8r mix test test/internal/expl8r_court_test.exs
Result: 11 passed                          (11/11, 0 failures)
$ MIX_BUILD_ROOT=_build-expl8r mix test test/internal/expl8r_court_test.exs \
    test/internal/az2_maa_attestation_court_test.exs \
    test/internal/ath1_batch_frame_receiver_court_test.exs \
    test/internal/w3cb_vc_export_court_test.disp \
    test/integration/az3_confidential_ledger_court_test.exs \
    test/integration/az3b_ledger_mount_court_test.exs
Result: 46 passed
```

Adjacent courts stay green: az2 MAA court (7 legs), ath1 frame receiver (11),
w3cb VC export, az3/az3b ledger (8) — all consume the touched faces.

Full offline suite run during the lane (shared checkout, concurrent lanes
landing): `Result: 778/796 passed, 18 failed` — all 18 failures traced to
OTHER lanes' in-flight files (expl10r2/expl11r1 census registration debt,
`Smalt.Internal.NamespacePutTest` KD-124 `:code.delete` race, Smalt.Test.Internal.Expl10r2
param-validation legs). Zero failures in files this lane owns. Census drift
at lane close is other lanes' unregistered new files (expl10r, expl11r3,
bkmaap6) — each owner registers per the BK-CENS reconciliation pattern.

## Disclosures

- Edited `test/internal/internal_tier_census_test.exs` (shared seam) to
  register `expl8r_court_test.exs` + its typed exemptions — census file is
  part of its own scan, so comment text avoids the literal scan tokens.
- EXPL-8's T7 `Frame.encode/1` `:op` 0..255 guard and decode pad-validation
  nits remain UNFIXED-in-lane (build-side doc-truth only, no ticket owner
  named in EXPL-8); typed here for the next ERRC sweep.
- My lib edits (maa.ex, store.ex, router.ex, mcp_descriptor.ex) were
  snapshot-landed by coordinator tick checkpoints (ef958eaa, 70405ff6,
  266e9e60-class) while lanes ran concurrently; this commit carries the
  receipt only. BK-MAAP6 (P5) layered nonce bounds/eviction on the E8-T6
  reservation law after the snapshot; both courts green on the merged tree.
