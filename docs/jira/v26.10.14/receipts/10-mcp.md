# Receipt — V261014-10 (MCP Plane) — lane 10

- **Date:** 2026-10-15 · **Repo:** /Users/sac/smalt @ main 3fc2543 (dirty, shared checkout)
- **Work order:** docs/jira/v26.10.14/10-mcp.md

## Scope landed (in working tree, uncommitted)

Per coordinator dispatch: **no commits made from this lane** ("no git state changes/commits" —
coordinator owns integration commits). Work order §3.1 said "commit the pending lane work";
the dispatch's no-commit rule was followed as controlling. All five pending lane files remain
modified in the tree:

- `lib/smalt/mcp/gen/mcp_descriptor.ex.eex` — lens-7 canonical order (pending, untouched)
- `lib/smalt/mcp/generated/mcp_descriptor.ex` — regenerated, sha256 `900c396b…` (pending, untouched)
- `lib/smalt/mcp/router.ex` — pending lane state + **§3.3 fix**
- `test/mcp_test.exs` — pending lane state + **§3.3 fences + §3.2 heal**
- `test/mcp_wire_test.exs` — pending lane state + **§3.2 heal**

## §3.3 — cosmos.query non-binary partition_key

`lib/smalt/mcp/router.ex`: `_other -> %{}` (silent full-table scan) replaced by a typed refusal
via new `partition_key_headers/1` helper placed AFTER the `invoke/2` clause group. First attempt
interleaved the helper inside the clause group → `defp invoke/2` non-contiguity warning failed the
ggen `--warnings-as-errors` verify gate; helper relocated (same pattern as `message_count_arg/1`).

`test/mcp_test.exs` lens3 refusal-envelope matrix: three new rows (partition_key = integer `5`,
list `["a","b"]`, map `%{"k"=>"v"}`) → all assert exact `INVALID_PARAMS` structured code. Green.

## §3.2 — setup heal

Both `setup do` blocks now call `assert :ok = SmaltTest.Lifecycle.ensure_store_up()` before the
Store.put seeds (lane 01's landed helper, `test/test_helper.exs:123`).

## Gates (actual output)

| Gate | Result |
|---|---|
| `mix test test/mcp_test.exs test/mcp_wire_test.exs` | 80 tests, 0 failures |
| Same, run ×2 consecutively | both `80 tests, 0 failures` |
| Seed sweep `--seed 1 7 42 99 123` (mcp_test.exs) | 5× `51 tests, 0 failures` |
| `mix smalt.gen` | **EXIT=0**, "unchanged (skipped, identical content)" rows; 0 warnings |
| Manifest hash fence | on-disk descriptor sha256 `900c396b7537…fac47` == manifest pin (manifest.json:51) |

### Intermediate failure (repaired)

First `mix smalt.gen` runs exited 1 (build_broken): all warnings sourced from
`lib/smalt/egress_router.ex` (another lane's in-flight edits — Application.get_env, never-match
clause, plug typing violation). Not this lane's file; per the compile-freeze SLA the owning lane
landed clean and the gate re-ran green (EXIT=0). One genuine lane defect (invoke/2 clause
contiguity from my first helper placement) was caught by the same gate and repaired in-cycle.

## §3.4 Out of scope (recorded, per work order)

- Batch-array bodies → generic INVALID_REQUEST (`router.ex:595`): **WONTFIX** — no batch support
  contracted for v26.10.14; generic refusal spec-tolerable.
- Notifications get `id: nil` envelope (`router.ex:133-134`): **UNSUPPORTED** — no
  notification-plane capability advertised.

Both rows belong in the release known-gaps table (ERROR_SWEEP convention); not fixed here.

## Falsifiers

- Manifest hash drift after any template touch — checked, equal.
- Seed-dependent setup race — 5-seed sweep green.
- Non-binary partition_key silent scan — new fence rows green.
