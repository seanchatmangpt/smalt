# ARMFIX — ARMSTRONG census top-3 typed violations closed (v26.10.21)

Context: solo

**Standing:** **ALIVE** (all three fixes landed at HEAD 4326bd6, courts 8/8 + owning tiers 28/28 on rerun)

Lane: armfix (writer), repo /Users/sac/smalt, toolchain Elixir 1.20.4-otp-29 / Erlang 29.1.2,
`MIX_BUILD_ROOT=_build-armfix` (lane build root left in place for coordinator cleanup at integration).

## Diffs (landed in coordinator checkpoint commit 4326bd6)

- `lib/smalt/runtime_contracts.ex` (+28/-…): `name_of/1` and both `contract_name_guess/2`
  arms return typed `{:error, :bad_name}` on rescue instead of re-guessing;
  `String.to_atom(inspect(entry))` replaced by `String.to_existing_atom(inspect(bad_name))`
  with `rescue ArgumentError -> {:error, :bad_name}`; `typed_name/2` rescue now returns
  `{:error, :bad_name}` (was silent `{:ok, name}`) and its `Enum.find` dropped the
  `is_atom/1` guard so tuple-keyed bad entries resolve to the malformed_name marker;
  `plane_of/2` rescue returns `{:error, :bad_name}` (was silent `{:ok, :unknown}`).
- `lib/smalt/data_plane/appconfig_features.ex`: `eval_filter` rescue narrowed to
  `[ArgumentError, ErlangError]` with `[:smalt, :appconfig, :filter_error]` telemetry emit
  (flag, filter, formatted error); unknown raises (e.g. Protocol.UndefinedError) now
  propagate — let-it-crash. Moduledoc updated.
- `lib/smalt/arm/deployments.ex`: `correlation_id: inspect(make_ref())` minted once per
  deployment record (referentially stable across GET/PUT); op id minted once per admission
  so `id` and `operationId` agree (was two divergent `System.unique_integer` counters);
  `deployment_map` renders `rec.correlation_id` (was fresh `smalt-#{unique_integer}` per render).
- `lib/smalt/egress_router.ex` (Peers): fallback `"correlationId" => "azb10-" <> inspect(make_ref())`
  minted PER EVENT (was deterministic `resource_uri_digest` — every event on a resource
  shared one id, destroying correlation). `build_event/2` made `@doc false` public for
  court observability (real caller, no mocks).

## Chicago courts — test/internal/armstrong_idiom_court_test.exs (8 tests, all pass)

1. Wired `verify/0` regression fence: no `contract_malformed_*` registry marker on the
   healthy set. NOTE: the cosmos_header etag contract fails solo in the test env —
   witnessed identical at HEAD with the fix reverted (pre-existing, environment-dependent,
   not session-introduced); fence targets the registry's own markers, not that contract.
2. Non-atom `name/0` → `contract_malformed_name` (pre-existing marker preserved).
3. Crashing `name/0` → typed `contract_malformed_name`, no rescue-away.
4. Non-module entry → result keyed `{:error, :bad_name}` with BOTH malformed_name and
   malformed_plane markers.
5. **Atom-count fence**: `:erlang.system_info(:atom_count)` before/after `verify/1` over
   hostile entries (`{:bad,:entry}`, `42`, `"oops"`, 3-tuple) — equal; zero atoms minted.
6. Appconfig known-class error (badmap Audience) → conservative `false` WITH
   `filter_error` telemetry received; unknown raise (`to_string/1` on map group name →
   Protocol.UndefinedError) propagates via real `evaluate/3` (was silently `false`).
7. Deployments: correlationId stable across GET, unique across deployments, `#Reference<`
   (make_ref) — not an incremental integer.
8. Router: two `build_event/2` for the same resource yield DISTINCT correlationIds;
   meta-provided `:correlation_id` still honored.

## Tier output

```
MIX_BUILD_ROOT=_build-armfix mix test test/internal/armstrong_idiom_court_test.exs
  → Result: 8 passed        (8/8)
MIX_BUILD_ROOT=_build-armfix mix test test/integration/appconfig_events_test.exs \
  test/integration/namespace_put_test.exs test/internal/armstrong_idiom_court_test.exs \
  test/integration/arm_workspace_tables_test.exs \
  test/integration/cross_surface_determinism_test.exs \
  test/internal/eh_throttle_wiring_test.exs
  → Result: 28 passed       (28/28; first batch run had one flaky failure that did
    not reproduce on rerun — see note)
```

Flake note (honest report): the first combined batch (17/18) failed one test that passed
on both the solo rerun and the full 28-test rerun; failure did not reproduce twice. No
assertions in the failing region were changed between runs — classified flake, unowned.

Runtime caveat observed: `Loading of Elixir.Smalt.EgressRouter.Peers.beam failed: :not_purged`
log line during integration runs — pre-existing code-reload artifact, tests unaffected.

Machine context: `just bench-machine` not run — this lane changed no bench surfaces.

## Replay

```
export PATH="$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$HOME/.asdf/installs/erlang/29.1.2/bin:$PATH"
cd /Users/sac/smalt
MIX_BUILD_ROOT=_build-armfix mix test test/internal/armstrong_idiom_court_test.exs
```
