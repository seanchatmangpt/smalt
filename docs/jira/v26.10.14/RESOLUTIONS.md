# v26.10.14 — Shared Seams & Resolutions

Cross-lane agreements for the work orders in this directory. When two orders touch the
same surface, the seam is recorded here so neither duplicates or clobbers the other.

## S1 — `SmaltTest.Lifecycle.ensure_store_up/0` (lanes 01 → 02, 10)

- **Owner:** lane 01 (defined in `test/test_helper.exs`). Child-aware: `ensure_all_started`
  → restart Store child if `whereis == nil` (treating `{:error, {:already_started, _}}` /
  `:already_present` as success) → bounded wait for all Store ETS tables to exist.
  Non-raising, idempotent.
- **Consumers:** lane 02 (`lens7` `restore_store!/0` calls it instead of hand-rolling
  restart+wait; the on_exit safety net becomes the one-line call), lane 10 (MCP +
  MCP-wire test setups), lane 01's own ~20-site sweep.
- **Rule:** no lane invents a divergent variant. If lane 01 has not landed when a consumer
  starts, implement behind a single local seam and switch the call site in a follow-up
  commit in the same release.

## S2 — Receipt-file gate for GAP register flips (lanes 05/06/07/08 → 13)

- A GAP row flips to CLOSED only when
  `docs/jira/v26.10.14/receipts/<lane>-<gap-name>.md` exists, containing the landing
  diff, fence commands, and their real output.
- Lane 13 owns register grammar (token form, strikethrough-closed form, close-condition
  lines); lanes 05/06/07 own their rows' *content* at flip time via the receipts.
- **No receipt, no flip.** If receipts are absent at wrap, the rows stay OPEN and the
  release-notes honesty paragraph says so.

## S3 — `egress_router.ex` split (lanes 06 / 19)

- Lane 06: blob route arms (container list ~:741, blob list :931), `blob_error/3`
  header-only change, new `blob_error_xml/4`.
- Lane 19: SKR/KV arms (:456-462, :477), CORS plug (:37), Sentinel strict-mode is in
  `sentinel.ex` (19 owns), Resource Graph in `resource_graph.ex` (19 owns).
- **Merge order:** either; both run the shared regression set (`test/wire/egress_wire_test.exs`,
  `test/data_plane/{cosmos,key_vault_actions,audit_planes}_test.exs`) before landing.

## S4 — `justfile` split (lanes 12 / 14)

Lane 12 owns `court`, `census`, `invariant-gates`, `naming-sweep`. Lane 14 owns
`gen-error-codes`. Both must pass `just -l` + their acceptance recipes after the second
lane lands; neither rewrites the other's recipes.

## S5 — Kill-restart discipline (lanes 02 / 04 / 18 / 19)

Any test that takes a supervised child (or a compiled module) down restores it
synchronously in the test process (`try/after` + checked restart/reload + liveness +
state verification) before reporting. `on_exit` restore alone is a defect.
Canonical implementations: lens7 fix (02), engine-kill court (18). Lane 04's
`{:session_release, ...}` serialization and lane 19's strict-mode env flips follow the
same capture-and-restore discipline.

## S6 — Honesty register (lane 13 final-text authority)

`docs/RELEASE_NOTES_v26.10.14.md` carries exactly one gap block, adjacent to the
existing `GAP(lro-no-failed-path)` CLOSED note: "parity for the documented surface;
named gaps for the rest" + the register census. Lanes 05 (feature-or-disclosure line)
and 16 (RevOps bullet) propose edits; lane 13 reconciles the final text last so the
census sentence matches the register state at wrap.

## S7 — Probe vs court vocabulary (lane 18)

Only `scripts/mutation_court.py` is a "court." The six one-shot probes (cosmos
continuation, auth crit, blob If-Match, typ, tee-admit jti, LRO lens-9) are stamped
"one-shot — not full-court protocol" in `docs/BENCHMARKS.md`; no doc may call them
courts. The two new gate-visible tests (wire-tier sweep, engine-kill) are courts once
they have BEFORE/KILL/RESTORE phases with receipts.

## S8 — Seed-detection discipline for docs citing digests/counts (lanes 14, 15, 17)

Any doc restating a digest, count, or gate-witness number must recompute it at landing
time (the cited hex/number in the work orders is as-of-authoring). Do not copy values
out of the work orders into landing docs.

## S9 — Template/hash invariants (lane 10)

`lib/smalt/mcp/gen/mcp_descriptor.ex.eex` is hash-load-bearing (`.ggen_igniter/manifest.json:51`
pins the generated descriptor sha256). Any template edit regenerates via `mix smalt.gen`
and updates the manifest in the same commit — never by hand-editing the generated file.
