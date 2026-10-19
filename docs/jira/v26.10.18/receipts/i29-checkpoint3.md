# i29 Checkpoint 3 — in-flight lane census at HEAD b9b9199

- Subject: /Users/sac/smalt @ `b9b9199882ab1c8018ee82f24673421ac625bbc1`
Context: solo
- Command: `git status --porcelain && git rev-parse HEAD`

```
 M .ggen_igniter/manifest.json
 M .ggen_igniter/receipts/2026-10-19.jsonl
 M docker/burn/compose.burn.yml
 M docker/burn/parallel-matrix.sh
 M docs/jira/v26.10.16/sdk-results/spc-bands.md
 M lib/smalt/messaging/amqp/atom_bridge.ex
 M test/amqp/atom_bridge_test.exs
 M test/amqp/broker_facade_test.exs
 M test/amqp/flow_credit_test.exs
 M test/amqp/frame_codec_test.exs
 M test/amqp/sas_verifier_test.exs
 M test/arm_cors_test.exs
 M test/azsim/sovereign_midnight/sovereign_midnight_test.exs
 M test/lro_test.exs
 M test/mcp_test.exs
 M test/mcp_wire_test.exs
 M test/smalt_arm_gateway_test.exs
 M test/smalt_ets_baseline_identity_test.exs
 M test/wire/arm_wire_test.exs
 M test/wire_tier_refusal_sweep_test.exs
b9b9199882ab1c8018ee82f24673421ac625bbc1
```

`git diff --stat` (HEAD vs worktree): 20 files, +808/-183.

## Per-file ownership

### Lane A — i29 atom_bridge s4 (azb-17 capacity face) — IN-FLIGHT

Evidence: diff comments literally tagged `i29 (azb-17 s4-amqp-capacity face)`;
burn witness cited in-diff (`flood_conns=2073 atom_log_lines=2073`).

| File | State | Role |
|---|---|---|
| `lib/smalt/messaging/amqp/atom_bridge.ex` | in-flight (+39/-) | restores silent `{:error, :closed}` clause; rate-limited non-terminal debug path via `:persistent_term` (no per-conn log lines, no atom minting) |
| `test/amqp/atom_bridge_test.exs` | in-flight (+69) | flood-of-closed-connections silence test, real sockets, Chicago (no mocks) |

### Lane B — burn matrix (docker/burn, AZB-17/azb-18 surface) — IN-FLIGHT

Evidence: `parallel-matrix.sh` diff comment `# AZB-17: regenerate compose.burn.yml
at the requested N before every run ... generated-artifact law`; `compose.burn.yml`
is the regenerated generated artifact (+579).

| File | State | Role |
|---|---|---|
| `docker/burn/parallel-matrix.sh` | in-flight (+6) | emits compose at N before each run; never trusts disk state |
| `docker/burn/compose.burn.yml` | in-flight (generated) | regenerated output of `emit_compose` — generated artifact, not hand-edited |
| `docs/jira/v26.10.16/sdk-results/spc-bands.md` | in-flight | n bump 297→298 / 296→297 from a fresh burn/SDK leg sample — measurement update, not hand-edit of a band |
| `.ggen_igniter/manifest.json` | in-flight | sha + timestamp for `store_tables.ex` updated by a `mix smalt.gen`-class regen (2026-10-19T05:16:49Z) — generator manifest, side effect of a lane run |
| `.ggen_igniter/receipts/2026-10-19.jsonl` | in-flight (+18) | generator receipt lines from same run |

### Lane C — test-env hygiene sweep (SmaltTest.Env canonicalization) — IN-FLIGHT

Evidence: uniform mechanical refactor across 13 test files — hand-rolled
`prev = Application.get_env` + `on_exit` restore blocks replaced with
`SmaltTest.Env.put_restored(...)` (presence-preserving, absent prev is
delete_env'd, nil-no-op leak class killed; comments cite AZB-11b,
test-isolation-leak gate, v26.10.17 interference sweep).

| File | State |
|---|---|
| `test/amqp/broker_facade_test.exs` (+11/-) | in-flight |
| `test/amqp/flow_credit_test.exs` | in-flight |
| `test/amqp/frame_codec_test.exs` | in-flight |
| `test/amqp/sas_verifier_test.exs` | in-flight |
| `test/arm_cors_test.exs` | in-flight |
| `test/azsim/sovereign_midnight/sovereign_midnight_test.exs` | in-flight |
| `test/lro_test.exs` (+32/-) | in-flight (removes local `restore_env/2`, uses `put_restored`) |
| `test/mcp_test.exs` | in-flight |
| `test/mcp_wire_test.exs` (+55/-) | in-flight |
| `test/smalt_arm_gateway_test.exs` | in-flight |
| `test/smalt_ets_baseline_identity_test.exs` | in-flight |
| `test/wire/arm_wire_test.exs` (+39/-) | in-flight |
| `test/wire_tier_refusal_sweep_test.exs` (+39/-) | in-flight |

## Named-surface checks from dispatch

- **budget reseed** (`docs/jira/v26.10.18/test_budgets.json`): NOT dirty — file
  exists on disk, no working-tree change at b9b9199. Budget lane either already
  landed or has not started; no in-flight residue.
- **A22-F1**: fully committed at HEAD (`b9b9199 feat(kd): KD-98 registered —
  A22-F1 multi-data-section split heuristic witnessed`). No leftover files.
- **event_hubs_test.exs**: NOT dirty — Lane A did not touch it; ownership
  stays atom_bridge_test.exs only.

## Commit boundary (once lanes land)

Three atomic commits, dependency-safe (no shared files across lanes):

1. `feat(amqp)` — i29 s4: Lane A files (`atom_bridge.ex`, `atom_bridge_test.exs`).
2. `feat(burn)` — Lane B: `docker/burn/*`, `spc-bands.md`, `.ggen_igniter/*`.
   `compose.burn.yml` lands as regenerated output of the parallel-matrix change.
3. `test(env)` — Lane C: the 13-file SmaltTest.Env sweep.

Then gate order: `mix test` → `just test-budget` (reseed if Lane C timings
shifted; note `test_budgets.json` currently clean — a reseed here would become
a 4th dirty file, own it in the Lane C commit or a follow-up) → `just sleep-gate`
(Lane C touches env-restore paths) → commit → `just docs-dod-check`.

Standing: CENSUS (read-only observation receipt; no gates run in this checkpoint).
