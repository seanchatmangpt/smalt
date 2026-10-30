# 39 Turnstile Fence Landing (G26 option (a))

Status: **PARTIAL_ALIVE** — the fence is enforced and the executable court is
green with witnessed non-vacuity; the LIVE kind/TF apply path court did not
run this session (substrate not booted; `just posh-smalt-wire` was never
invoked — the stage-5 recipe edit is compile-checked only).
`mix compile` exit 0; `mix test test/smalt/posh` 41 passed;
`mix test test/integration/{rbac_role_definitions,tags_locks}_test.exs`
16 passed; combined court 8 passed; shim court FAIL→PASS witnessed.

Subject: `/Users/sac/smalt` (working tree, uncommitted — wave v26.10.30
residue was already in flight when this lane started; coordinator owns the
commit). Consumer repo `/Users/sac/cai/courtroom-platform-az` untouched
except this report file.

## Landed (file:line, working tree)

1. **Template fix** — `ggen-marketplace/packs/posh/templates/beam_pipeline.ex.tmpl`
   - BIND is now the literal `Smalt.Posh.Turnstile` (:29-32); the
     `Smalt.Posh.Turnstile.Turnstile<Resource>` ghost namespace is gone.
   - Generated `admit/2` calls the real fence with the real signature:
     `turnstile().admit(policy, route, frame, state_root, opts)` (template
     :87), matches `{:ok, %{receipt: _} = settlement}` (template :88-91),
     returns `{:ok, settlement} | {:refused, reason}` — never raises.
     Requires `state[:policy]` (compiled `Smalt.Posh.Ingress.Admission`);
     optional `:route/:state_root/:log_name`. Arity/return verified against
     `lib/smalt/posh/turnstile.ex:33-35`.
   - `turnstile_module()` now projects the literal module (:106).
2. **Regeneration** — `just posh-generate` ran clean (invariant gate clean,
   render rows>0, copy-out + compile gate passed). All 13
   `lib/smalt/posh/pipeline/*.ex` no longer reference ghosts; byte-contract
   law holds (fix the template, never the output).
3. **Fence wiring** — `lib/smalt/arm_gateway/plug/receipt_turnstile.ex`
   - dual mount: `call(conn, :stamp)` unchanged byte contract; NEW
     `call(conn, :fence)` (:50) — mutating verbs on `/subscriptions/*`
     consult `Smalt.Posh.Pipeline.Arm_request.admit/2` (the generated
     layer, option (a)); refusal → `halt` 400 typed
     `AdmissionRefused` ARM envelope (:139-160), still stamped (the stamp
     mount's before_send still runs).
   - Plug.Parsers `_json` unwrap (:136-137): a non-object JSON body
     (array/string) is the delta; Parsers wraps it as `%{"_json" => v}` —
     without the unwrap the fence never fires (witnessed: RouteNotFound
     passthrough before the fix).
   - refusal settlement: the stamp before_send (:106-124) appends a
     `kind: "refusal"` entry whose receipt == header digest
     (`Settlement.digest("arm.request", ts, raw_body)`), so the event log
     carries the refusal, not just the wire. Admitted deltas settle through
     `Turnstile.admit → Settlement.settle` normally.
   - `ensure_log!/1` (:63-73): unlinked, idempotent start of the fence's
     EventLog so default boots (no `config :smalt, :posh`) get a real
     persisted log at `tmp/posh/events.ndjson` — no crash, no silent
     no-log fake pass.
   - config gate `config :smalt, :turnstile_fence` (keys `enabled` default
     TRUE, `log_name`, `dir`, `policy`) — charter posture ON for arm.request;
     disclosed choice. Disabled → conn passes untouched (flip test in suite).
4. **Router mount** — `lib/smalt/arm_gateway/router.ex:79`
   `plug(Smalt.ArmGateway.Plug.ReceiptTurnstile, :fence)` immediately after
   `Plug.Parsers` (the fence admits the parsed body; Bearer still guards
   ahead of it — unauthenticated deltas get 401 as before).
5. **Court** — `test/smalt/posh/turnstile_fence_court_test.exs` (4 tests):
   unreceipted mutating delta (JSON array) → 400 AdmissionRefused + header +
   event-log entry matching `Settlement.digest` ; object-body delta passes;
   fence-disabled flip; GET stamp-only. Real router, real Parsers, real
   Admission, real BLAKE3, real EventLog file — Chicago-clean, no mocks.
6. **Stage-5 message fix** — `justfile.d/58-posh.just` (single disclosed
   edit): the assert now proves the FENCE (POST `[]` with bearer → 400 +
   `AdmissionRefused` body) and the stamp, and the PASS line says
   "turnstile stamp + fence refusal" — no more "ingress enforced" overclaim
   from a header-presence check.

## Shared-seam edits (disclosed per same-checkout law)

- `ggen-marketplace/packs/posh/templates/posh_yaml.tmpl` — lane 42's
  in-flight file broke ggen sync (`{{ range . }}` is not Tera); I applied a
  one-line unblock; lane 42 then landed their own `{% for %}` fix over it.
  Net: theirs stands.
- `ggen-marketplace/packs/posh/shapes/ingress.ttl` — added
  `posh:ArmRequestShape` (open delta-payload shape). Without it the ghost
  shape IRI fell back to the closed IngressRouteShape and the SHACL lane's
  `validate/2` wiring refused EVERY legitimate ARM write (witnessed:
  pre-existing `arm_receipt_turnstile_test` "receipt binds the raw body on a
  POST" 400'd). Lane 44's ShapeValidator is untouched; the route's
  `posh:shape` now resolves to a real shape.
- `lib/smalt/posh/ingress/admission.ex` (:106-131) — `run_admission/4`
  inline-fallback: when `Smalt.Posh.Ingress.TaskSupervisor` is not running
  (default boots without `config :smalt, :posh`), validate INLINE with the
  same real validator (`{:noproc, _}` / ArgumentError) instead of
  crash-looping into a bogus `{:admission_crash, :restart_budget_exhausted}`
  refusal for every request. Real exits still retry within budget.

## Verification ladder (real output)

- `mix compile` (asdf elixir 1.20.4-otp-29, MIX_BUILD_ROOT=_build-lane39):
  exit 0.
- `mix test test/smalt/posh` → 41 passed, 0 failures.
- `mix test test/integration/rbac_role_definitions_test.exs
  test/integration/tags_locks_test.exs` → 16 passed.
- court + `test/integration/arm_receipt_turnstile_test.exs` → 8 passed
  (pre-existing stamp contract intact).
- **Shim non-vacuity**: `plug(..., :fence)` mount commented out → court
  `Failed: 1 test`; restore byte-identical (sha256 5f6657b12a799f94 both
  sides) → `4 passed`. The court cannot pass without the fence.
- Stage-5 recipe: `just --justfile justfile.d/58-posh.just --evaluate`
  parses.

## Standing / open residue

- Fence on the arm.request gateway face: **ALIVE** (in-process court green +
  flip witnessed).
- Live kind/TF apply path: **UNVERIFIED** this session — `just posh-smalt-wire`
  (now with the fence assert) must run against the booted substrate to close
  G26 on the live path.
- Go provider + posh/ UDS membrane untouched (no adapters/ or posh/ edits).
- Lane build root `_build-lane39` left for the coordinator (lease, deleted at
  integration).
- Concurrent-wave notes: the justfile, template, and pipeline modules were
  hot-edited by lanes 41/42/44 mid-flight; all my gates were run against the
  final on-disk state as of this report. `posh-generate`'s own compile gate
  and `mix compile` agree.
