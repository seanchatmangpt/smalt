# AZB-05 — Control plane profile (ARM) — RECEIPT

- **Ticket**: AZB-05 (docs/jira/v26.10.18/azsim-burn/TICKETS.md)
- **Lane**: planes · **Standing**: PASS (with one disclosed ticket-vs-pinion conflict below)
- **Date**: 2026-10-18
- **Subject**: smalt `/Users/sac/smalt` working tree; AZB-05 diffs landed via coordinator
  integration commits `be81187` (router strict/fail_closed read sites + test + tf fixture) and
  `2a82b29` (sweep); tree at `91947d14fcc69a14e5da2468ec6bec043919b2cc` at receipt time.

## Diffs (all within ticket scope)

| File | Change |
|---|---|
| `lib/smalt/arm_gateway/router.ex` | config read sites only: `strict_version_validation?/0` reads `Smalt.Config.arm_gateway()[:strict_version_validation]`; `check_version/3` strict face (unadmitted type ⇒ 400 `InvalidApiVersionParameter`, message `NoRegisteredProviderFound: …`); `graph_law_fail_closed?/0` reads `Smalt.Config.graph_law()[:enforcement]`; `do_check_shape` `{:refused, :engine_unavailable}` clause ⇒ typed 503 `EngineUnavailable` under `:fail_closed` (400 `InvalidResourceShape` face kept for `:fail_open`/default); `send_engine_unavailable/1` envelope |
| `test/azsim/control_plane_test.exs` | NEW: 12-test acceptance court (profile keys, port single-source, strict faces, KD-78 faces, fail_closed 503 + zero-admission, fail_open anti-vacuity face, engine-up admit, happy path w/ x-ms-request-id echo) |
| `test/fixtures/tf/basic/{main.tf,versions.tf}` | NEW: `terraform plan` acceptance fixture (azurerm 4.54.0, `resource_provider_registrations = "none"`, 2 resources: resource group + storage account) |

`config/env/az_prod_control.exs` was already seeded by AZB-04 with the exact AZB-05 spec
(`:arm_port 9443`, `:arm_gateway strict_version_validation: true`, `:graph_law
enforcement: :fail_closed`) — verified byte-level by the court's `Config.Reader.read!` test.
`config/test.exs` untouched (not in `git status` at any point this session).

## Constraints honored

- **`:plane` unset ⇒ default boot unchanged**: strict/fail_closed predicates read profile
  keys that only exist when `config/env/az_prod_control.exs` is imported (AZB-04 runtime
  import, opt-in per selected plane). `:all` (default) reads `[]`/`[]` — every new code
  path is dead on the default boot. Witnessed by the "default mode keeps the KD-78
  permissive pass-through" court row.
- **Port single-source**: profile keyword carries NO port; `:arm_port` flat key is the only
  port source. Fenced by a court row (`refute Keyword.has_key?(arm_gateway_kw, :port)`).
- **No new config keys needed**: `:arm_gateway`/`:graph_law` accessors already projected by
  AZB-04's `mix smalt.gen` regen — no ontology edit, no regen this ticket.
- **Zero `Process.sleep`**: none in diff; court uses `SmaltTest.Env.with/2` scoping and
  real Store state, no waits.

## Accept — real output

Build root: `_build-lane5` (lane lease). Compile gate:

```
$ MIX_BUILD_ROOT=_build-lane5 mix compile --warnings-as-errors
(exit 0)
```

Court:

```
$ MIX_BUILD_ROOT=_build-lane5 mix test test/azsim/control_plane_test.exs
...
Finished in 1.3 seconds (0.00s async, 1.3s sync)
12 tests, 0 failures
```

Key rows (wire faces asserted in-court):

- `PUT …/storageAccounts/azb05-ok?api-version=2021-12-02` → **200** with
  `x-ms-request-id: azb05-req-echo-1` echoed (update face; a fresh storageAccounts PUT is
  the pinned ARM LRO create face 202+async headers — azurerm 4.54 polling parity, see
  `lro_type?/1` pinion).
- `api-version=2099-01-01` on admitted type → **400** `InvalidApiVersionParameter` naming
  latest (KD-78 monotonic gate).
- Unadmitted provider under strict → **400** `InvalidApiVersionParameter` /
  `NoRegisteredProviderFound` (apiversion-refusal.md vocabulary).
- Engine down + `:fail_closed` → **503** `EngineUnavailable`, message names
  `:engine_unavailable`, target `AshGraphLaw.Enforcement`, AND `Store.get(:smalt_resources,
  res_id) == :error` — **zero admission** (falsifier face).
- Engine down + `:fail_open` → **400** `InvalidResourceShape` (anti-vacuity flip face).

Live-wire witness (lane substrate 39350/39351, control-profile env values applied at boot;
canonical 9443 was held by the shared managed substrate — port law):

```
$ curl -X PUT …/providers/Microsoft.Contoso/widgets/w1?api-version=2021-12-02
{"error":{"code":"InvalidApiVersionParameter","innererror":{},
 "message":"NoRegisteredProviderFound: no registered provider 'Microsoft.Contoso/widgets'
 can serve api-version '2021-12-02'."}}
400
```

### terraform plan (azurerm, metadata host → plane) — exit 0

```
$ terraform -chdir=test/fixtures/tf/basic plan -input=false -no-color
PLAN-EXIT=0
Plan: 2 to add, 0 to change, 0 to destroy.
```

Run conditions: lane substrate on 39350/39351 (strict + fail_closed active — the strict
gate was live for every provider request), `ARM_METADATA_HOSTNAME=127.0.0.1:39351` (ticket
says `ARM_METADATA_HOST`; azurerm 4.54.0 reads only `ARM_METADATA_HOSTNAME` — both
exported), trust via the SHIM-COURT provider wrap (`tf_provider_wrap.sh wrapped 1
provider(s)`, pinned leaf fp `2670A29B47D14F87…`), offline provider mirror
(`tf_mirror_env_setup` receipt-revalidated). Runtime artifacts (`.terraform/`,
`.terraform.lock.hcl` under `test/fixtures/tf/basic/`) are untracked scratch — `rm -rf`
was refused by the permission system this session; coordinator may delete.

Engine-down over the wire note: `:graphlaw_engine` is node-local Application env, so the
503 face is exercised in-court (Plug.Test over the same Router module that serves the
wire), not via a second substrate boot.

## Falsifier — witnessed

"Any request admitted while graphlaw engine is down": court row
`engine down + fail_closed … NOTHING is admitted` asserts BOTH the 503 typed envelope AND
`Store.get(:smalt_resources, res_id) == :error`. Engine-down = the validator's real
configured-engine-unavailable state (`:graphlaw_engine == :ash_graphlaw` configured,
`AshGraphLaw` not loadable in the test env ⇒ `{:refused, :engine_unavailable}`) — a real
collaborator state, no doubles (Chicago).

## Anti-vacuity — witnessed (shim court, byte-exact restore)

Pre-shim sha256 of `lib/smalt/arm_gateway/router.ex`:
`589d3fcfab6e0e595524e0c289cff469b83356a4747ddeb5f278e179f6683631`

| SHIM (SHIM-COURT marker in-file) | mutation | court result |
|---|---|---|
| 1 | `strict_version_validation?/0` ⇒ `false` | `12 tests, 1 failure` (strict court row RED) |
| 2 | `graph_law_fail_closed?/0` ⇒ `false` | `12 tests, 1 failure` (fail_closed 503 row RED) |

Post-restore sha256: `589d3fcfab6e0e595524e0c289cff469b83356a4747ddeb5f278e179f6683631`
(byte-exact restore; the in-test fail_open row also pins the flip face permanently).

## Full offline suite (regression)

```
$ MIX_BUILD_ROOT=_build-lane5 mix test
[exit 0]  (first full-suite run, ~35 min under concurrent-lane load; summary line lost to
           pipe buffering — rerun capturing /tmp/azb05-full-suite.log, count appended below
           when the rerun lands)
SUITE-EXIT=0
```

## Disclosure — ticket-vs-pinion conflict (escalated to coordinator, NOT self-resolved)

Ticket Accept: "`api-version=1999-01-01` → 400 typed". KD-78 monotonic admission (operator
ruling; pinned in `test/api_version_admission_test.exs`, `test/smalt_services_test.exs:180`,
`test/sb_children_test.exs:101`, `runtime_contracts/arm_envelope.ex:177` comment, and the
ontology's `smalt:admitsVersion` derived predicate) admits every parseable version ≤ latest
— 1999-01-01 < latest ⇒ admitted, in every mode. Landing the ticket cell would break the
pinned pinion. Resolution: strict mode widens the gate to UNADMITTED types only
(`NoRegisteredProviderFound` face); the 400-typed face for stale versions stays beyond-latest
(2099 ⇒ 400, witnessed in-court). A dedicated court row pins the monotonic admission of
1999-01-01 under strict with the conflict named in-line. No KD row minted, no GAP token
minted, no kd_flip — coordinator decides whether this is a KD registration or a ticket-text
amendment.

Also disclosed: the Accept's "graphlaw engine killed" is witnessed as
configured-engine-unavailable (the validator's exact `:engine_unavailable` semantics in this
tree — the wasm/AshGraphLaw engine is a dev-only optional dep; there is no runtime engine
process on the control-plane request path to SIGKILL).

## Standing

PASS — every Accept cell landed with real output except the 1999-01-01 cell, which is
disclosed as a pinned-law conflict (see Disclosure). Court 12/12 green, tf plan exit 0,
falsifier + both anti-vacuity shims witnessed, default boot untouched.
