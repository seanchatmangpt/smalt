# 26 Turnstile Live Path: Receipt Stamp vs Receipt Fence

Status: PARTIAL — the receipt **stamp** is ALIVE on the live TF apply path
(witnessed: `just posh-smalt-wire` assert, `justfile.d/58-posh.just:257-264`);
the receipt **fence** (refuse an unreceipted delta + settle a receipt into the
event log) is not enforced on any live path. Dead-code census re-read from
disk 2026-10-30.

Subjects:

- consumer: `/Users/sac/cai/courtroom-platform-az` (HEAD 31c58e9)
- substrate: `/Users/sac/smalt` (working tree, unpinned — see gap 24)

## What each face actually enforces today

- **BEAM ARM gateway (9443)** — `ReceiptTurnstile` plug
  (`receipt_turnstile.ex`, mounted `router.ex:46`, ABOVE Bearer). Emits: yes,
  every response incl. 401s and crash 500s. Verifies: no. Refuses:
  **no — stamps, never halts**. Event log: no.
- **posh UDS membrane (Go)** — `armclient/client.go:232` ->
  `receipt.VerifyTurnstile`. Emits: no. Verifies: yes, fail-closed on
  mismatch. Refuses: partial — **verification is skipped entirely when both
  headers are absent** (`client.go:200-204`). Event log: no.
- **terraform-provider-smalt (live TF apply)** —
  `adapters/terraform-provider-smalt/internal/**`. Verifies: **no — zero
  `turnstile`/`x-smalt` refs in the adapter tree** (grep 2026-10-30).
  Emits/refuses/logs: no.
- **BEAM admission fence** — `Smalt.Posh.Turnstile.admit/5`
  (`posh/turnstile.ex`). Refuses: yes (typed `{:refused, _}`). Event log:
  yes (`Settlement.settle` -> `EventLog.append`). Callers: **none live**.

Conclusion: on the live TF apply path the only turnstile artifact is a
response header emitted by the BEAM face. Nobody on that path reads it. The
module that actually refuses and settles (`Smalt.Posh.Turnstile`) is
test-only, and the generated pipeline layer that is supposed to route
admission through it is dead.

## Dead code (GAP04/GAP08 confirmed)

- `Smalt.Posh.Turnstile.admit/5` has **zero live callers**. Only test usage:
  `smalt/test/smalt/posh/posh_engine_test.exs:37,44,56`.
- All 13 generated pipeline modules
  (`smalt/lib/smalt/posh/pipeline/*.ex`: arm.request, arm-get, echo,
  arm.resource_group, arm.container_app, arm.container_app_environment,
  arm.container_registry, arm.key_vault, arm.key_vault_secret,
  arm.log_analytics_workspace, arm.role_assignment, arm.role_definition,
  arm.storage_account, arm.user_assigned_identity,
  arm.federated_identity_credential) reference **nonexistent modules**
  `Smalt.Posh.Turnstile.Turnstile<Resource>` (e.g.
  `arm.container_app.ex:31` -> `Smalt.Posh.Turnstile.TurnstileContainerApp`;
  only `Smalt.Posh.Turnstile` exists). Even if the modules existed, the call
  is wrong: `turnstile().admit(frame, receipt_iri())` is arity 2, the real
  fence is `admit/5`.
- Nothing calls any `Pipeline.admit/2` either — grep over `smalt/lib` and
  `smalt/test` shows no `Posh.Pipeline.` reference outside the generated
  directory. Double-dead: the dispatch target does not exist and the dispatch
  entry point itself is never invoked.
- Template root cause: `ggen-marketplace/packs/posh/templates/
  beam_pipeline.ex.tmpl:26` BINDs
  `Smalt.Posh.Turnstile.<Pascal(turnstileLocalName)>`, and the template body
  (line 53) calls `turnstile().admit(frame, receipt_iri())`. The ontology
  names turnstile individuals (`turnstileContainerApp`, ...), so the render
  manufactures a per-route module namespace that the runtime never defined.

## Is the fence real on the live TF apply path?

No. Chain of custody on a TF apply:

1. provider PUT -> smalt 9443 -> `ReceiptTurnstile` stamps
   `X-Smalt-Receipt-Turnstile` onto the response (real, every delta).
2. provider discards the header (no reference in the adapter).
3. `Smalt.Posh.Turnstile` is never consulted; no admission runs; no entry
   lands in the event log (`Smalt.Posh.Egress.EventLog`, `events.ndjson`).

On the posh UDS path the Go membrane verifies the header when present, but
absent headers bypass silently, and this path is not the TF apply path.

So the charter fence "no unreceipted delta passes" holds today only in
`posh_engine_test.exs`. What holds on every path is weaker: "every delta gets
a stamped response header".

## Minimal wiring to make the fence real on every admitted delta

Ranked. (a) and (b) are composable; (c) is the fallback if neither is
admitted this wave.

### (a) Fix the templates to emit valid module refs + wire dispatch

Two one-line-class edits in `ggen-marketplace/packs/posh/templates/
beam_pipeline.ex.tmpl`:

```diff
-      BIND(CONCAT("Smalt.Posh.Turnstile.",
-            UCASE(SUBSTR(REPLACE(STR(?turnstile), "^.*[#/]", ""), 1, 1)),
-            SUBSTR(REPLACE(STR(?turnstile), "^.*[#/]", ""), 2))
-        AS ?turnstileMod)
+      BIND("Smalt.Posh.Turnstile" AS ?turnstileMod)
```

and in the body:

```diff
-         {:ok, receipt} <- turnstile().admit(frame, receipt_iri()) do
+         {:ok, %{receipt: receipt}} <-
+           turnstile().admit(admission_policy(), route_iri(), frame, state_root(),
+                             payload_body: frame_body(frame)) do
```

with the module gaining the graph-projected accessors it already has data
for:

```elixir
  def route_iri, do: "{{ route }}"
  defp admission_policy, do: Smalt.Posh.Ingress.Admission.policy_for(route_iri())
  defp state_root, do: Smalt.Posh.Egress.Settlement.current_root()
  defp frame_body(frame) when is_binary(frame), do: frame
  defp frame_body(frame), do: Jason.encode!(frame)
```

Then regenerate (byte-identical render law) so the 13 modules in
`lib/smalt/posh/pipeline/` stop referencing ghosts. Note `admit/5` returns
`{:ok, %{receipt: ...}}` (settlement map), not `{:ok, receipt}` — the `with`
clause must match the settlement map.

Wiring the entry point is the second half: something must call
`Pipeline.admit/2`. Cheapest honest seam: the `ReceiptTurnstile` plug already
sees every mutating request; instead of only stamping, it can consult
`Smalt.Posh.Pipeline.ArmRequest.admit/2` (validate + turnstile) for
non-GET verbs and `halt` with a typed ARM 400 envelope on
`{:refused, reason}` (Andon RED via the router's `send_arm_error`), keeping
the stamp on the refusal response. That makes the fence real on the same
face the TF provider already drives, with no provider-side change.

### (b) Route BEAM-side admission through turnstile.ex directly

Skip the generated layer for enforcement (keep it as topology metadata):
inside `Smalt.ArmGateway.Plug.ReceiptTurnstile.call/2`, for mutating verbs,
call `Smalt.Posh.Turnstile.admit/5` with a policy resolved from the registry
(`Smalt.Registry` top/api-version data already keys per resource type) and
`halt` + `send_arm_error(conn, 400, "AdmissionRefused", ...)` on refusal.
Smaller diff than (a), but it orphans the generated pipelines permanently —
register that as a divergence if chosen (`KD-nn`: "posh pipeline layer is
topology metadata, not the enforcement path; enforcement is the gateway
plug").

### (c) Register as divergence

If neither lands: add a `KD-nn` row to
`smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` — surface "POSH-002
turnstile fence", divergence "enforced only in tests; ARM face emits receipts
but refuses nothing; provider discards them", close condition "a mutating
unreceipted delta on 9443 is refused with a typed envelope AND an event-log
entry exists for the refusal". Until then `just posh-smalt-wire` only proves
the stamp, not the fence — its assert should be renamed in prose
(header-presence, not "turnstile ingress enforced"; the fail-closed message
at `58-posh.just:263` overclaims).

## Falsifier proposal (executable court)

`smalt/test/integration/turnstile_fence_court_test.exs` — imports
`Smalt.Posh.Pipeline.ArmRequest` (option (a) wired) or drives the router
(option (b) wired), and asserts BOTH:

1. refusal: `POST /subscriptions/sub/resourcegroups/rg-x` with a body that
   violates the route shape returns a typed ARM 400 (not 2xx), and the
   refusal response still carries `X-Smalt-Receipt-Turnstile`;
2. settlement: after the refused attempt,
   `Smalt.Posh.Egress.EventLog` (or the `events.ndjson` file for the test
   dir) contains an entry whose digest matches
   `Settlement.digest("arm.request", ts, raw_body)` for the refusal — i.e. a
   receipt for the unreceipted delta's refusal is in the log, not just on
   the wire.

Court is non-vacuous today: run it against the current tree and it fails at
step 1 (the delta is admitted, not refused) — the flip from FAIL to PASS is
the evidence the fence landed. Post-landing non-vacuity: remove the plug's
admission branch and the court must fail again (shim-court pattern,
`scripts/shim_court/lib.sh`).

## Receipt

- Commands: grep/find censuses over `smalt/lib`, `smalt/test`,
  `smalt/adapters/terraform-provider-smalt`, `smalt/ggen-marketplace/packs/
  posh`, `smalt/justfile.d/58-posh.just`; reads of `router.ex`,
  `receipt_turnstile.ex`, `turnstile.ex`, `beam_pipeline.ex.tmpl`,
  `client.go`, `posh_engine_test.exs`, `arm_receipt_turnstile_test.exs`.
- No executable court ran this session (read-only lane); the proposed court
  above is the close condition.
- Standing: GAP26 OPEN. Fence UNVERIFIED on live paths; stamp ALIVE
  (witnessed by stage-5 wire assert + `arm_receipt_turnstile_test.exs`).
