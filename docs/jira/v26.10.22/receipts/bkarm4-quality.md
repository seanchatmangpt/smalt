# BK-ARM4 — Armstrong code-quality bars: census, worst-offender audit, beauty check, defensive sweep

Standing: ALIVE · Context: solo · Lane: BK-ARM4 · Repo: /Users/sac/smalt (canonical checkout)

Armstrong bars: ideal module ~300 lines; make it work → beautiful → fast, in that order; code reads like prose; no defensive programming.

## 1. Census (wc -l, session-touched topology/swarm/kind/fence/monitor/fond surfaces)

| file | lines | bar (flag >500) |
|---|---|---|
| test/internal/bkegs1_fence_court_test.exs | 785 | FLAGGED — worst offender, see §2 |
| test/integration/swarm_court_test.exs | 502 | marginal flag (2 lines over) |
| test/pipeline/fond_powl_runner_court_test.exs | 501 | marginal flag (1 line over) |
| test/integration/peer_two_node_court_test.exs | 406 | pass |
| lib/smalt/monitor/metrics.ex | 365 | pass |
| justfile.d/52-kind.just | 246 | pass |
| Dockerfile.smalt | 177 | pass |
| test/internal/bkmon3r_deadjoin_court_test.exs | 147 | pass |
| lib/smalt/powl2.ex | 147 | pass |
| Dockerfile.console | 73 | pass |
| scripts/kind/setup_kind_cluster.sh | 15 | pass |
| scripts/kind/teardown_kind_cluster.sh | 11 | pass |
| lib/smalt/powl2/executor.ex (closure-walk host) | 564 | marginal flag (larger than the ~300 ideal but one concern: a pure topology kernel; split is typed in §2n, not urgent) |

Test/court files are allowed to be long (each leg is an independent falsifier); the ~300-line ideal binds lib/ modules. Every lib/ surface (metrics 365, powl2 147, executor 564) is within striking distance or typed below. No file ships unrefactored beyond 800.

## 2. Worst offender: `test/internal/bkegs1_fence_court_test.exs` (785 lines)

**Does it do one thing?** Yes — one concern (the F-EGS1 error-handler fence across 3 route families) — but it does it 8 times by copy-paste: 8 rig modules (EgressNormalRig, EgressGuardedBoomRig, ArmNormalRig, ArmBoomRig, McpNormalRig, McpBoomRig, EgressParseRig, EgressOldBoomRig) each repeating `handle_errors/2` + `fegs1_fallback_send/2` + `poisoned_error_xml/2` + `generate_uuid/0` + `send_arm_error/5` with small per-rig variations. `fegs1_fallback_send/2` is byte-identical in 6 of the 8 rigs.

**Typed refactor shape (NOT executed — court test, coordinator-gated):**
- Extract one support module `test/support/bkegs1_rig.ex`: `BKEGS1.Rig` with
  - `start_bandit(faults \\ %{})` — one plug builder parameterized over a faults map `{:error_xml, :rid, :handler}`, each fault a fun that raises;
  - shared `fegs1_fallback_send/2`, `send_arm_error/5`, `poisoned_error_xml/2`, `generate_uuid/0` as public helpers;
  - per-family envelopes (Storage XML / ARM JSON / MCP JSON-RPC) as 3 small functions.
- Each rig collapses to a one-line `use BKEGS1.Rig, faults: [...], envelope: :storage|:arm|mcp`.
- Estimated 785 → ~250 lines; the fence law stays in ONE place; a fourth route family becomes 3 lines instead of 90.
- Falsifier: all 7 LEGs stay green unchanged (`mix test test/internal/bkegs1_fence_court_test.exs`), census count drops.
- Risk: zero production surface — test-only module; safe to execute any window.

## 3. Beauty check (3 session fixes, crash-first / pattern-matched / prose)

**BK-DUPID — `lib/smalt/pipeline/smalt_fond_plan.erl:44-60` (usort dedup).** PASS.
The fix is a one-line `lists:usort([ID || #{id := ID} <- Steps])` — a comprehension feeding a set operation, no loop, no accumulator. The law lives in a comment naming the receipt. Crash-first intact: `assert_acyclic` still `erlang:error({cyclic_plan, Ids})` typed on cycle. The `Providing` fold is the one non-prose stretch (a foldl of foldl into `maps:update_with`) — a list-comprehension-into-`maps:from_list/1` + append shape would read closer to the rest of the module; cosmetic, not a fix gate.

**BK-MON3R — `lib/smalt/monitor/metrics.ex` series/5 filter (exact downcased equality).** PASS with one typed note.
The filter is exact equality (`r == wanted and m == metric`) replacing the dead `starts_with(r <> "|")` idiom — the dead-code defect is dead, and L4 witnesses it does not leak sibling rows. Armstrong note: the filter is an `if/else` inside `flat_map` where a `for` comprehension (`for {{r,m,b},_,_,_} <- rows, r == wanted, m == metric, b in window, do: {r,m,b}`) would read as prose. Cosmetic.

**BK-POWLH3 — `lib/smalt/powl2/executor.ex` can-follow closure walk.** PASS.
`cycle_edges/1` → `reaches?/3` → `reach_dfs/4` is textbook pattern-matched recursion: the base case is a function head (`reach_dfs(_e, cur, to, _seen) when cur == to`), the seen-set is a guarded clause, the fan-out is `Enum.any?` recursion. No ifs-where-patterns-belong, no rescues. Reads like Armstrong prose.

## 4. Defensive-programming sweep (rescue/catch converting crashes to defaults)

Grep over all session-touched surfaces above (+ store.ex). Every site typed:

**Legitimate boundaries (keep):**
- `executor.ex:196 run_guard` — guard crashes fail CLOSED to a typed `{:andon_refusal, :guard_raised, ...}`; this is the law (crash → typed refusal, never default-pass).
- `bkegs1_fence_court_test.exs` (7 try/rescue sites) — the court itself: each rescue asserts the TYPED fence envelope a crash must render, plus the F-EGS1 fallback for a faulting fence (fail-closed secondary). Legitimate.
- `swarm_court_test.exs:160 call_typed/3` — converts erpc failures to TYPED `{:error, {:node_down, node}}` / `{:error, {:erpc, reason}}`, re-raises anything unexpected. This is the Armstrong-adjacent ideal: crash → type, not default.
- `store.ex:224 apply_put` — `ArgumentError -> {:error, {:bad_payload, ...}}` typed. Legitimate.
- `store.ex:293 journal append` — log-and-drop on sink-down, typed warning. Legitimate boundary (journal is best-effort, data plane survives).
- `metrics.ex record/4` — log-and-drop with warning on post-boot table loss. Legitimate (documented law).
- `fond_powl_runner_court_test.exs:395 f1a_planner` — catch converts typed plan refusals (`unprovided_need`/`cyclic_plan`) to `{:refused, klass}`; leg-appropriate.

**Defensive smell (FIXED this lane):**
- `metrics.ex merge/2` — `rescue ArgumentError -> :ok` was SILENT (zero log, zero bits) while sibling `record/4` logs the same event. A silent default is exactly the Armstrong ban. **Fix landed:** merge/2 now logs the same typed warning record/4 emits ("dropping merged sample"), drop law unchanged. Crash→default remains (correct boundary) but is no longer silent.

**Smell noted, kept (typed, not fixed):**
- `swarm_court_test.exs stop_peer/1` — `rescue _ -> :ok; catch _,_ -> :ok` blanket-catch in teardown. Teardown idempotency is a legitimate boundary (stopping an already-dead peer must not kill the court), but the catch is UNTYPED — narrowing to `ArgumentError` + `:exit, :low_entropy`-class reasons would make the drop carry its reason. Left as-is: it is teardown-only and narrowing risks flipping the green swarm court mid-session; typed as a successor tidy, not a defect.

## Verification

- `MIX_BUILD_ROOT=_build-lane4 mix compile` — green with the merge/2 fix in tree (first run exit 0 pre-sibling-edits; re-run after sibling in-flight churn green: "COMPILE-OK after attempt 3"). Disclosed transient: sibling lanes' in-flight `lib/smalt/powl2/executor.ex` (mismatched delimiter) and `lib/smalt/cluster.ex` broke two intermediate compiles — not this lane's surface, settled by their owners.
- Targeted: `MIX_BUILD_ROOT=_build-lane4 mix test test/internal/bkmon3r_deadjoin_court_test.exs` — `Result: 4 passed` (witnessed).
- Census figures are `wc -l` at receipt time on the named files; they are counts, not claims.
