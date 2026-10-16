# Q-1 Shadow Verify Receipt (F-6 pre-flight)

- **Date**: 2026-10-15
- **Subject SHA**: `518b31a54ccc0829cafb9e04538714e58c287a30` (main HEAD)
- **Method**: sanctioned scratch checkout — `git archive HEAD | tar -x -C /tmp/smalt-shadow-80056` (no worktree). Sibling path deps (`ggen_igniter`, `ash_graphlaw`, `ash_r2rml`, `ash_ex4pm`) symlinked into `/tmp/` so `../` path deps resolved; transitive Hex deps fetched via `mix deps.get`.
- **Lane**: Q-1 finish-support, F-6 pre-flight.

## Static verdicts (all run in the scratch tree, independent of main-tree in-flight edits)

| Check | Verdict | Exit | Notes |
|---|---|---|---|
| `mix compile --warnings-as-errors` | PASS | 0 | Cold dep compile accepted; smalt compiled 93 files clean. Dep-stage warnings from `ash_ex4pm`/`ex4pm` (Ash domain-config inclusion, `GgenIgniter.Ontology` undefined in dep mix task) did not fail and belong to dep projects. |
| `mix format --check-formatted` | **FAIL** | 1 | `test/security/lens6_crash_class_test.exs` — missing trailing newline at EOF (line 88, `+|`). |
| `python3 -m py_compile smalt-cli/smalt_cli/*.py` | PASS | 0 | All files clean. |
| `node --check workspace/scripts/*.mjs` | PASS | 0 | 3 files: `azure-arm-probe.mjs`, `azure-dataplane-probe.mjs`, `e2e-court.mjs`. |
| `node --check test/sdk-smoke/*.cjs` | PASS | 0 | All clean. |

Skipped per lane order: dialyzer (not configured), Python SDK test suites (need substrates).

## Early warnings for F-6/F-7

1. **Format defect at HEAD**: `test/security/lens6_crash_class_test.exs` lacks a trailing newline. Verified present in BOTH the scratch HEAD tree and the main tree (`tail -c` byte check) — this is a live HEAD defect, not masked by in-flight edits. Any `mix format --check` gate in F-6/F-7 will trip on it. One-byte fix (append newline).

## Teardown

Scratch tree `/tmp/smalt-shadow-80056` and `/tmp/{ggen_igniter,ash_graphlaw,ash_r2rml,ash_ex4pm}` symlinks removed after receipt.
