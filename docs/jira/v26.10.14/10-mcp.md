# V261014-10 — MCP Plane: land lens-7 canonical order, protocol pinning, test-isolation heal

- **Release:** v26.10.14 · **Status:** ready for implementation · **Mode:** commit pending lane work + two bounded fixes
- **Depends on:** lane 01's `ensure_store_up/0` (§3.2 lifts its seam; if not landed, copy the helper per lane 01's landed form — do not invent a divergent variant)

## 1. Summary

The MCP plane has converged, uncommitted lane work that must land in v26.10.14: lens-7 canonical-order template change, regenerated descriptor (hash-converged), router re-sort defense-in-depth, and +104 lines of adversarial test fences. Protocol pinning is complete (8-offer matrix; server answers literal `2024-11-05`, `router.ex:91`). Two defects to fix; one cluster recorded out of scope.

## 2. Scope — commit as-is

| File | Content |
|---|---|
| `lib/smalt/mcp/gen/mcp_descriptor.ex.eex` | sorts capabilities by `capability_id` (:17), `List.last(canonical)` for the trailing-comma join (:27) — canonical order at the source tier |
| `lib/smalt/mcp/generated/mcp_descriptor.ex` | regenerated; sha256 `900c396b…` matches `.ggen_igniter/manifest.json:51` — generation converged |
| `lib/smalt/mcp/router.ex` | defense-in-depth re-sort in `tools/` (:188-189) and registry-introspection `mcp_tools` (:490-493), tied to the lens-7 ORDER-BY root cause |
| `test/mcp_test.exs` | +104 lines of fences: protocol-pin loop (:468-491), 100-deep-arg fuzz, duplicate-key determinism, hostile child-id (:872-936), TTL↔wire drift (:1250-1272) |
| `test/mcp_wire_test.exs` | wire-tier companion changes |

No further edits to lane content — commit as the converged state. **The template is hash-load-bearing:** any cosmetic edit changes the descriptor hash and breaks the manifest fence; edit template and manifest together via the generator only.

## 3. Work items

### 3.1 Commit the pending lane work (files above)

### 3.2 V261014-10-A: setup `Store.put` race — adopt `ensure_store_up/0`

**Evidence:** `test/mcp_test.exs:36-50` and `test/mcp_wire_test.exs:14-39` call `Smalt.Store.put(:smalt_resources, ...)` directly in `setup`. Cross-module Store teardown can drop the table mid-setup (the same family as the witnessed full-suite "unknown table" crash). Lane 01's `ensure_store_up/0` is the fix seam.

**Change:** convert both setups to call `ensure_store_up/0` (lifted from lane 01's landed form).

**Acceptance:** `mix test test/mcp_test.exs test/mcp_wire_test.exs` green under `--seed 0` and ≥10 random seeds (the race is timing-dependent; seed sweep is the fence).

### 3.3 V261014-10-B: `cosmos.query` swallows non-binary `partition_key`

**Evidence:** `router.ex:336-340` — `_other -> %{}` treats a non-binary `partition_key` (integer/list/map) as absent, yielding a full-table scan instead of typed `INVALID_PARAMS` — the same silent-coercion class the fuzz fence exists to prevent.

**Change:** replace `_other -> %{}` with typed `INVALID_PARAMS` ("partition_key must be a string"). Add fence cases (integer, list, map) to the existing fuzz describe block.

### 3.4 Explicitly out of scope (record, do not fix)

- **Batch-array bodies → generic INVALID_REQUEST** (`router.ex:595`): **WONTFIX** — no batch support contracted for the v26.10.14 surface; generic refusal is spec-tolerable.
- **Notifications get an `id: nil` envelope** (`router.ex:133-134`): **UNSUPPORTED** — no notification-plane capability advertised; revisit only if one ships.

Both rows go into the release known-gaps table (ERROR_SWEEP convention), not into this cycle's code.

### 3.5 Known constraint (do not fix this cycle)

`mix smalt.gen` under `--warnings-as-errors` is blocked by *unrelated* module warnings (whole-tree compile coupling). Run as unchanged-proposal exit 0, not a clean-tree full regeneration; do not chase unrelated warnings here.

## 4. Acceptance criteria

1. `mix smalt.gen` unchanged-proposal exit 0.
2. `mix test test/mcp_test.exs test/mcp_wire_test.exs` green ×2 consecutively.
3. Manifest hash equality fence green (`900c396b…` per `.ggen_igniter/manifest.json:51`).
4. Non-binary `partition_key` → typed `INVALID_PARAMS` (new fence green).
5. Seed-sweep green (≥10 seeds) for both MCP modules.
6. WONTFIX/UNSUPPORTED rows recorded.
7. All five pending files committed; `git status` clean for the MCP lane.

## 5. Sequencing / dependencies

1. Lane 01 first (`ensure_store_up/0`).
2. Commit lane work → 3.3 fix + fence → 3.2 setup heal → acceptance gates.

## 6. Risks

- Template hash-load-bearing (§2).
- Single-run green is not evidence; the ×2 + seed-sweep requirement is not optional.
