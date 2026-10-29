# EXPL-8 — MCP surface + sync/receipt/attestation ERRC sweep (read-only)

**Standing:** **PARTIAL_ALIVE (explore lane)** — read-only sweep; findings are observations
against the working tree, no code edits. All probe commands embedded with real output.
Context: solo
Date: 2026-10-22
Repo: /Users/sac/smalt (main)
Lane: EXPL-8
Toolchain: asdf elixir 1.20.4-otp-29, `MIX_BUILD_ROOT=_build-expl8` (left for coordinator
`just lane-clean` — rm denied in this read-only lane).

Excluded per dispatch (covered elsewhere): `lib/smalt/sync/receipt.ex` core algebra
(bk92, KD-165) — audited only the uncourted edges (odd inputs, concurrent mint
interleaving). Prior EXPL-1..7 + KD register (v26.10.22 `KNOWN_DIVERGENCES.md`
KD-167..173) read first; none of the findings below are registered.

## Scope actually covered

- `lib/smalt/mcp/router.ex` (1609 L, 37 input_schema clauses), `lib/smalt/mcp/gen/smalt_mcp_surface.ttl`
  (37 capabilityIds), `lib/smalt/mcp/generated/mcp_descriptor.ex` (32 capabilities), `application.ex:142` mount.
- `lib/smalt/sync/{frame,batch,guard,store,receipt}.ex`, `lib/smalt/receipt/vc_export.ex`,
  `lib/smalt/attestation/maa.ex` (601 L).
- Probes: real compiled modules, `mix run --no-start`, wire tier via `Plug.Test` (no mocks;
  real JSON-RPC over the router). No tree writes; scratch in /tmp.

## T1 — Five wave-6 MCP tools implemented but UNREACHABLE (descriptor stale vs TTL) — HIGH

Silent-drop class, generated-artifact drift. The TTL names 37 capabilityIds; the generated
descriptor ships 32. `dispatch_tool/2` requires `Descriptor.describe/1` success, so five
tools with full invoke + input_schema clauses (`kv.rotationpolicy.get`, `css.zones`-class:
`dns.zones.list`, `eg.schemaregistry.groups`, `monitor.alerts.list`,
`cosmos.ttl.effective`) never dispatch: `tools/list` shows 32 tools; wire calls get
TOOL_NOT_FOUND.

Probe (real wire face, Plug.Test → Mcp.Router.call):

```
$ MIX_BUILD_ROOT=_build-expl8 mix run --no-start /tmp/expl8_probe.exs   (abridged)
== P1: wave-6 MCP tools unreachable ==
kv.rotationpolicy.get: :error
dns.zones.list: :error
eg.schemaregistry.groups: :error
monitor.alerts.list: :error
cosmos.ttl.effective: :error
== P1b: wire face ==
cosmos.ttl.effective -> TOOL_NOT_FOUND: refused: unknown tool "cosmos.ttl.effective" (not in the generated read-only descriptor)
kv.rotationpolicy.get -> TOOL_NOT_FOUND: (same shape)
substrate.status -> dispatched ok (control leg)
```

Also witnessed at the generation layer:

```
$ grep -c "capabilityId" lib/smalt/mcp/gen/smalt_mcp_surface.ttl  -> 37
$ grep -c "rotationpolicy\|dns.zones\|schemaregistry\|alerts\|ttl.effective" lib/smalt/mcp/generated/mcp_descriptor.ex  -> 0
Smalt.Mcp.Descriptor.capabilities() |> length  -> 32
```

Repair ticket E8-T1: re-run `ggen_igniter.sync` (TTL → `generated/mcp_descriptor.ex`),
add a drift fence asserting `length(Descriptor.capabilities()) == count(TTL capabilityIds)`
(fail-closed, shim-courtable), and a dispatchability court asserting every TTL tool id
dispatches over the real wire face. If the 5 tools are intended-unregistered, the TTL rows
are the premise rot to delete instead. Either way the two sides must agree mechanically.
Doc-truth rider: `router.ex` moduledoc names tools only through wave-5 and cites
`test/mcp_test.exs` — see T4.

## T2 — MAA nonce replay registry dies with its creator process (fail-open) — HIGH

`maa.ex:341-349 ensure_nonce_table/0` creates `:smalt_maa_nonces` (`:public`, no heir,
no owner process) inside whatever process runs the first `attest/3` — in production, a
short-lived Bandit request process. Table death silently resets replay protection.

Probe (attest in a spawned request-process stand-in, let it exit, replay same nonce):

```
== P2: MAA nonce registry lifetime ==
first attest (spawned proc): ok len=944
nonce table alive after owner death: false
REPLAY ACCEPTED after owner death — nonce registry lost
```

Repair ticket E8-T2: own the table in a real process (GenServer owner or `heir` to `:init`,
the `Sync.Store.init/1` SPOF-B idiom cited in `lib/smalt/shim_court` docs — precedent
`lib/smalt/sync/store.ex:107`), or fold the registry into an owned table next to
`Smalt.Store` tables. Court: attest in a spawned-then-dead process, replay the nonce,
assert typed `nonceReplay` STILL fires. Shim `ensure_nonce_table` to a no-op for the
anti-vacuity leg. `# KD-COVERS` row registration is the registrar's call (KD-174 next free).

## T3 — Caller-supplied MAA policy overrides iss/iat/exp in the signed token — MEDIUM-HIGH

`issue_token/7` merges `issued` claims LAST over the envelope defaults (`maa.ex:434-454`):
`Map.merge(defaults, Map.merge(issued, binding))`. `params["policy"]` is caller-supplied,
and issuance rules copy arbitrary name=value into the token. A hostile policy can override
the envelope security claims:

```
== P3: hostile policy overrides envelope claims ==
issued: %{"exp" => "never", "iss" => "https://evil.example/"}
attest with hostile policy: iss="https://evil.example/" exp="never"
```

Real MAA's issuancerules cannot override the token envelope (iss/iat/exp are
provider-controlled). Repair ticket E8-T3: reserve the envelope claim namespace — refuse
`issue(name=...)` where name ∈ {iss, iat, exp, nbf, jti} (or all `x-ms-*` +
envelope names), typed `invalidparameter` refusal at `parse_issue/1` or issue_token merge
priorities: defaults win, issued claims merge UNDER, not over. Court: hostile policy leg
asserting `iss`/`exp` unchanged.
Witnessed end-to-end: hostile policy → signed token with `iss="https://evil.example/"`,
`exp="never"`. A `verify_attestation/1` consumer trusts iss/exp from the token, so the
override survives verification (ReceiptSigner signs whatever is merged).

## T4 — MCP router moduledoc premise rot: cites deleted test/mcp_test.exs — MEDIUM (doc-truth)

`test/mcp_test.exs` was deleted in the 64f6099 clean-room reset
(V261019-11) and never re-authored. The moduledoc (router.ex:42-61) still claims:
"Tests exercise this module over `Plug.Test` ... see test/mcp_test.exs", cites the
hostile-supervisor `:doctor_supervisor` seam fence, the actuation-verb fence, and a
"TTL-vs-Descriptor cross-check" test — none exist anywhere in test/ or scripts/
(grep `Smalt.Mcp` over test/ → only application/egress_router refs; `git log -- test/mcp_test.exs`
→ last touch is the 64f6099 deletion). The entire 37-tool JSON-RPC surface on :9545 has
ZERO court coverage; the read-only gate (`ACTUATION_REFUSED` fence) is uncourted since the
reset. Repair ticket E8-T4: re-author a wire-tier court (the T1 dispatchability court can
carry the actuation-fence legs) and fix the moduledoc; every fence the moduledoc claims
gets a real test id named in the doc.

## T5 — MAA policy grammar: unparseable rules silently dropped (widening) — MEDIUM

`parse_rules/2` → `parse_rule/2` returns nil for unparseable rules and
`Enum.reject(&is_nil/1)` silently drops them. Rules are AND-ed, so a dropped rule widens
the policy. Witnessed:

```
$ mix run -e '... c:[type=="Tpm"] => permit; c:[type=="SevSnpVM"] => permit(); ...'
widening: Tpm-only policy (rule1 unparseable, dropped) admits SevSnpVM: {:ok, %{}}
```

(Tpm-only intent admits SevSnpVM because the Tpm rule failed to parse.) Counter-leg
witnessed fail-closed: a `typ==` condition (well-formed but unknown claim) is NOT dropped —
`{:error, {:policy_refusal, "authorization_denied:typ"}}` — so the gap is exactly the
nil-drop path. Repair ticket E8-T5: unparseable rule in `authorizationrules` → typed
`{:error, {:policy_refusal, "bad_rule"}}` (fail-closed); issuance-section drops can stay
lenient or be typed, owner's call.

## T6 — MAA nonce burned by a FAILED attestation — MEDIUM

`attest/3` inserts the nonce (`nonce_fresh?/1`) BEFORE `same_measurement?`/
`evaluate_policy`/binding checks (maa.ex:176-183). A request that fails any later step
consumes the nonce; a legitimate retry with corrected runtime data and the same nonce gets
typed `nonceReplay`. Witnessed end-to-end:

```
attempt1 (measurement mismatch, carries nonce) -> measurement_mismatch refusal
attempt2 (corrected data, SAME nonce) -> refused: nonceReplay — nonce burned by FAILED attempt1
```

Real MAA nonces bind to successful issue, not attempt. Repair ticket E8-T6: record the
nonce only on the success path (issue_token), or delete on failure (delete-on-failure
reopens a narrow replay race — record-on-issue is cleaner). Court: fail-then-retry-same-nonce
leg asserting success. Note interaction with T2: with the current ephemeral table BOTH
issues compound — the registry both forgets on owner death and remembers on failure.

## T7 — Low / notes (code-read, no probe)

- `Frame.encode/1` doc says `:op` optional "0..255" but no guard — `op: 256` builds
  `<<op::8>>` → ArgumentError (build side only, not remote input). frame.ex:63-65.
- `Frame.decode/1` never validates the reserved pad is zero (doc says "zero pad");
  nonzero pad silently accepted. frame.ex:83. Doc-truth nit.
- `Sync.Store.commit/3` guards only `is_integer` on client_id/seq (negative →
  `<<-1::64>>` ArgumentError) and doesn't type `frame_wire` (non-binary →
  `Receipt.absorb` → :crypto.hash raise) — crashes the CAS GenServer (heir preserves the
  table; data survives, in-flight calls die). Callers are internal (SyncRoutes feeds
  Frame-decoded binaries), so untyped-crash-on-internal-only; tighten the guard while
  touching the file.
- **Non-finding (proved, not probed)**: `Sync.Receipt` concurrent mint interleaving —
  `absorb/2`/`mint/1` are pure (no shared mutable state); the only serialized mutation
  point is `Sync.Store.handle_call` (one GenServer, CAS law intact). Structurally
  impossible to interleave; no ticket.
- `VcExport.to_vc/2` raises ArgumentError on bad terms — documented ("Raises on..."),
  caller-side typed; no ticket.
- `vc_binding` reads `vc["proof"]["proofPayloadSha256"]` from the map even though
  verify_vc already re-derived it — cosmetic.

## Verification ladder

Narrow probes over real compiled modules + one real wire-tier leg (Plug.Test through
`Mcp.Router.call/2`); MAA legs through the public `attest/3`/`evaluate_policy/2` (real
ReceiptSigner signing, real ETS). No substrate boot needed; no mocks; no sleeps.
