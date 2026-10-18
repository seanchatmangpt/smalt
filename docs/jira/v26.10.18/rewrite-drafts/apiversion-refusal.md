# Rewrite draft: apiversion / refusal-tier test family

Window: v26.10.18. Frozen tree — no edits, drafts only. Scope: the five ARM
gateway fence files. Invariants preserved verbatim, never touched by the
rewrite: KD-78 monotonic-admission pins (latest-1y admits, beyond-latest is
the 400 face) and the refusal-tier law (matched route: api-version 400 before
any 404; unmatched route: 404 RouteNotFound before the api-version gate;
shape-before-parent on parented children).

---

## 1. `test/apiversion_matrix_test.exs` — the cite-drift fence

### Problem

Every route row carries a hand-maintained string cite
(`"lib/smalt/arm_gateway/router.ex:1496"` etc.) and the `@cite_drift` fence
(lines 401-435) greps `router.ex` line content to detect stale citations.
That fence re-anchors itself every time the router gains lines (2026-10-17
re-anchor is the second such event). The line numbers are a projection of the
router's shape that we re-derive by hand — the fence tests the projection, not
the router.

### Rewrite: cite by symbol, not by line

Replace every `file:line` string with an MFA citation into the Router module.
The fence becomes structural: a citation is valid iff the symbol exists in the
loaded (or compile-verified) module. Line insertions can no longer break it,
because nothing references a line.

**Compile-time atom registry** (module attribute, no runtime file read):

```elixir
# Cite = {route_key :: atom, handler :: {atom, atom, arity}}
@route_cites %{
  generic_provider_put:
    {Smalt.ArmGateway.Router, :handle_resource_put, 5},
  subnet_put: {Smalt.ArmGateway.Router, :handle_child_put, 5},
  vault_keys_put: {Smalt.ArmGateway.Router, :handle_child_put, 5},
  blob_services_put: {Smalt.ArmGateway.Router, :handle_child_put, 5},
  containers_put: {Smalt.ArmGateway.Router, :handle_child_put, 5},
  immutability_policies_put: {Smalt.ArmGateway.Router, :handle_child_put, 5},
  sb_queues_put: {Smalt.ArmGateway.Router, :handle_parented_child, 7},
  sb_topics_put: {Smalt.ArmGateway.Router, :handle_parented_child, 7},
  sb_subscriptions_put: {Smalt.ArmGateway.Router, :handle_parented_child, 7},
  eh_eventhubs_put: {Smalt.ArmGateway.Router, :handle_parented_child, 7},
  eh_consumergroups_put: {Smalt.ArmGateway.Router, :handle_parented_child, 7},
  vnet_links_put: {Smalt.ArmGateway.Router, :handle_parented_child, 7},
  rg_put: {Smalt.ArmGateway.Router, :handle_rg_put, 4}
}
```

(Note: drop the placeholder — the SB subscriptions row cites the same
`handle_parented_child` MFA; every parented row cites the same shared handler
symbols, which is exactly the point: the cite names the code path exercised,
not a text position.)

**Introspection fence** (replaces `@cite_drift` + the grep test):

```elixir
test "cite fence: every route cite resolves to a live Router symbol" do
  {:ok, router} = Code.ensure_loaded(Router)

  for {route_key, {mod, fun, arity}} <- @route_cites do
    assert mod == router
    assert function_exported?(mod, fun, arity),
           "stale citation #{route_key}: #{inspect({mod, fun, arity})} " <>
             "no longer exists in Router — the handler was renamed/removed; " <>
             "re-derive the cite, never re-anchor a line"
  end
  # n.b. Router handlers are defp — see "private functions" below.
end
```

**Private functions (`defp`)**: `function_exported?/3` is false for private
functions on the loaded module. Two options, prefer (a):

(a) **abstract_code chunk** — one pass, no router changes, real introspection:

```elixir
defp handler_defs(mod) do
  {:ok, {_, [abstract: {:raw_abstract_v1, code}]}} =
    :beam_lib.chunks(:code.which(mod), [:abstract_code])

  for {fun, arity, _anno, _body} <- code, into: MapSet.new(), do: {fun, arity}
end
```

then assert `MapSet.member?(defs, {fun, arity})`. This is introspection of the
compiled module's own debug_info — it fails structurally when a handler is
renamed or deleted, and never when lines are inserted.

(b) If beam debug_info is stripped in the test env, fall back to promoting the
seven handler names to a tiny public `@doc false` facade on the Router
(`def route_handlers, do: [...]`) — one generated constant, not new surface.

**What the MFA cite does NOT replace**: the "registry completeness" row that
greps `Microsoft\.[A-Za-z]+...` literals from `router.ex` source. That row
checks a source-level property (every route's type literal is admitted) and
there is no symbol to introspect for it. It stays source-based, but its
documented exclusion list (Authorization/locks, DocumentDB/sql prefix guard,
policy surface, sb-rules, deletedVaults) moves from inline comments to a
`@excluded_literals` attribute so each exclusion is a named, individually
reviewable row with the same close-condition prose.

**Row tuples change shape**: `{type, path, "router.ex:1496"}` becomes
`{type, path, :subnet_put}`; the describe block renders
`"#{type} (#{route_key})"` and the registry maps route_key -> MFA once. The
`@generic_put_line` constant dies.

### Preserved verbatim

- The three-PUT fence per row: latest passes, `2099-12-31` ->
  InvalidApiVersionParameter, omitted -> MissingApiVersionParameter.
- **KD-78 row**: "PUT with old-but-valid api-version (latest minus 1y) admits
  monotonically (KD-78)" — body unchanged, including the `version_base/1`
  `-preview` suffix stripping.
- Matrix sweep precedence rows (matched GET-list/DELETE pass; unmatched POST
  404-before-gate) — untouched; they test behavior, not citations.

---

## 2. `test/wire_tier_refusal_sweep_test.exs`

### Assessment: minor rewrite only

This file is already citation-free and registry-driven. Three targeted
changes:

1. **Route resolution table doubles as the cite registry.** The big
   `resource_path/2` case block is a hand-written type->path mapping. Rewrite
   it to consume the same `@route_cites` registry from file 1 (extract to a
   shared `SmaltTest.RouteCites` helper module under
   `test/support/route_cites.ex`) so both files answer one question — "which
   handler does this type's PUT ride" — from one source. New admitted child
   types then need exactly one registry row, not one registry row + one path
   case + one cite string.
2. **Kill the `raise "no ARM path builder..."` fallthrough** (line 241) in
   favor of a typed compile-time assert: `@path_coverage` computes
   `Registry.admitted_resource_types()` minus the resolver's keys at compile
   time and `Enum.empty?/1` asserts it in a module attribute — the suite fails
   at load, naming the uncovered types, instead of raising per-type at runtime.
3. Preserve: the shapeless-set derivation (`shapeless_admitted_types/0`,
   response-derived, never hardcoded), the Defaults-hydration clause, defect
   clause V261014-18-D2 (404 RouteNotFound for admitted-but-unrouted types),
   and the law comment chain. The `>= 30` floor stays a floor.

No KD-78 rows here; the refusal-tier law is the file's whole subject and the
400/never-422/never-2xx assertions stand unchanged.

---

## 3. `test/arm_error_corpus_test.exs`

### Problem

Same disease as file 1, weaker strain: per-row comment cites
(`# lib/smalt/arm_gateway/router.ex:402`) plus the `send_arm_error` regex
census. Comment cites rot silently (no fence); the regex census is the only
real fence.

### Rewrite

1. **Delete the per-row line-comment cites** (`# router.ex:NNN`). Replace with
   the shared registry key in the `@tag corpus:` line:
   `@tag corpus: "MissingApiVersionParameter", cite: :check_api_version` —
   a symbol cite that the same abstract_code fence from file 1 verifies. The
   fence lives once in the shared `SmaltTest.RouteCites` helper and this file
   calls into it (a `cite-covers` test asserting every corpus row's `:cite`
   resolves to a live symbol via `handler_defs/1`).
2. **Cross-ref the LRO draft**: the LRO-async row
   (`202 + azure-asyncoperation + poll_until_succeeded`) and the
   `:lro_delay_ms` global pin in setup are the seams the LRO rewrite draft
   touches. If that draft landed, this file's LRO row should consume the
   shared `poll_until_succeeded` helper from it (`test/support/`), deleting
   the local copy at lines 493-518; if not landed, keep the local helper and
   mark the row with `# CROSS-REF: lro rewrite draft — dedupe on landing`.
   The `lro_delay_ms` save-prev/on_exit pin stays either way (it is the i22
   forensics fix, not a citation).
3. **Regex census stays** — it is the mechanical completeness fence and it is
   structural (regex over source, not over line numbers). Add the missing
   `{409, "SecretVersionNotFound"}`-style rows only via the census list, never
   by hand-editing per-row asserts. One tightening: the census asserts
   equality today, which means a NEW send_arm_error code fails the fence until
   a corpus row lands — keep that; the failure message should name the new
   `{status, code}` pair and the instruction "add a corpus row, never widen
   the census."

### Preserved verbatim

- Envelope shape-consistency court (three emit paths, one shape; target
  present iff GraphLaw; 429 carries no target; innererror present-but-empty).
- The `{400, ...}` refusal-tier ordering pins (details-present on SHACL issues
  vs details-absent on refused path).
- Monotonic-gate comment on the InvalidApiVersionParameter row (KD-78 400
  face).

---

## 4. `test/arm_cors_test.exs`

### Assessment: no rewrite

49 lines, zero citations, config save-prev/on_exit discipline already correct,
config flip tested per-request. The only note: it runs `async: false` though
it touches only `Application.env` + one route; if the window wants parallelism
wins, it could go async with an owned tag — but `Application` env is node-global
so `async: false` is correct as-is. Leave untouched; no draft body.

---

## 5. `test/smalt_arm_gateway_test.exs`

### Assessment: minimal rewrite

1292 lines of behavioral pins, citation-free. Only two changes:

1. **`api_v/1` placeholder hardening**: currently
   `nil -> "2024-01-01"` (line 55). That placeholder is fine for unadmitted
   parent types but silently fabricates a version for a type whose Registry
   row disappeared. Change to:
   ```elixir
   defp api_v(type) do
     case Smalt.Registry.latest_version(type) do
       nil -> flunk("type #{type} not admitted — Registry regen pending")
       v -> v
     end
   end
   ```
   …except `create` paths that legitimately target unadmitted parents (the
   SB/EH seeding pattern from the matrix test) already pass explicit versions,
   so audit each `api_v/1` call site: where the type must be admitted, flunk;
   where a placeholder is load-bearing, pass `"2021-04-01"` explicitly at the
   call site so the placeholder is visible, not implicit.
2. **Cross-ref LRO draft**: the storageAccounts LRO flow (lines 635-681) and
   the RG LRO delete (lines 192-199) pin 202 + header + terminal-poll. If the
   LRO draft's shared poll helper lands, consume it (delete the local
   `Enum.reduce_while` loop at 662-669); same mark-if-not-landed convention as
   file 3.
3. Preserve: KD-78 pins at lines 303-320 (monotonic gate comments), KD-T5-F2
   (no trailing slash), KD-T5-F3 (terminal body carries target resource id),
   R30 location immutability, the throttle window-lease test, KD-54/R119
   subscription LIST, refusal-tier comments (shape-before-parent) on the
   secrets and cosmos orphan probes.

---

## Shared artifact summary

New file `test/support/route_cites.ex` — `SmaltTest.RouteCites`:

- `@route_cites` map: route_key -> {module, fun, arity} (the compile-time atom
  registry).
- `handler_defs/1` via `:beam_lib.chunks(... [:abstract_code])`.
- `assert_cites_resolve!/0` — the single fence body, called by file 1 and
  file 3.

Test-file diff footprint: file 1 heavy (cite system swap), files 2/3 medium,
file 5 light, file 4 none. No `lib/` changes required (option (a) keeps the
router untouched). Generated artifacts unaffected. No GAP tokens minted; no
KD flips.
