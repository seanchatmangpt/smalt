# README

Diátaxis guide to ggen-driven code generation, authored from the v26.10.29
wave's real runs and receipts (DOCS-DIATAXIS lane, r19). Quadrant map:

- **Tutorials** — learning-oriented; type one end to end.
- **How-to** — task-oriented; one problem each.
- **Reference** — information-oriented; contract and pipeline facts.
- **Explanation** — understanding-oriented; why the laws are laws.

Every claim cites a receipt, a command output, or an on-disk file from the
authoring session (2026-10-29; ggen 26.10.11 unless a page says
otherwise). Start with the tutorial if ggen is new; the contract page and
the pipeline reference are the load-bearing citations for everything else.

## Tutorials

- [tutorials/ggen-first-sync.md](tutorials/ggen-first-sync.md) — zero to
  green: scratch dir, minimal manifest, two-row ontology, ORDER BY and
  body-binding laws, Tera loop, run + verify, then the real 25-module
  /tmp/ggen-split render and excerpt.

## How-to

- [how-to/run-a-single-rule.md](how-to/run-a-single-rule.md) — no --rule
  flag; the single-rule-manifest pattern.
- [how-to/point-ggen-at-a-manifest.md](how-to/point-ggen-at-a-manifest.md)
  — no --manifest flag; cwd-only resolution; stage-temp-copy-then-rm and
  when not to.
- [how-to/bulk-generate-scaffolds.md](how-to/bulk-generate-scaffolds.md) —
  the split-scaffold pattern; the unbound-variable and heredoc-tail
  defects with live-reproduced errors and fixes.
- [how-to/adopt-generated-code-safely.md](how-to/adopt-generated-code-safely.md)
  — lease-render, compile-validate, atomic mv, ownership disclosure,
  compile-freeze coordination, the NEVER-hand-expand header law.
- [how-to/regenerate-without-losing-handwork.md](how-to/regenerate-without-losing-handwork.md)
  — the config.ex incident; union-merge into the source; the lawful
  regen end-state.
- [how-to/extend-the-capability-graph.md](how-to/extend-the-capability-graph.md)
  — ConfigKey and IdentityFace rows through to capabilities.json;
  live-vs-queued standing vocabulary.

## Reference

- [reference/ggen-sync-run-contract.md](reference/ggen-sync-run-contract.md)
  — verified flag surface, E0013 / FM-GEN-008 / FM-WRITE-002, path
  resolution, JSON summary fields, tracing vs stdout.
- [reference/tera-gotchas.md](reference/tera-gotchas.md) — {% set %} filter
  pipelines, `is defined` guards, COALESCE in GROUP_CONCAT, loop-tag tail
  hygiene.
- [reference/smalt-generation-pipeline.md](reference/smalt-generation-pipeline.md)
  — all three chains: root ggen.toml (red herring), the six-stanza
  smalt.gen substrate pipeline (file:line), the MCP descriptor chain,
  Canonical.write.
- [reference/version-drift.md](reference/version-drift.md) — installed
  26.10.11 vs skill pin 26.8.18 vs source checkout; re-verify discipline.

## Explanation

- [explanation/generated-files-are-projections.md](explanation/generated-files-are-projections.md)
  — GGM-SRC-002, why hand-editing generated output is always wrong, the
  config.ex incident from both sides.
- [explanation/ontology-first-decomposition.md](explanation/ontology-first-decomposition.md)
  — scaffolds from a plan graph; compile-validated boundaries and
  lineage; the boundary/behavior limit.
- [explanation/vacuous-courts-and-real-clients.md](explanation/vacuous-courts-and-real-clients.md)
  — T02's same-calculus court vs T03's real consumers; replay fences;
  the real-consumer law.
- [multi-agent-compile-freeze-economics](explanation/multi-agent-compile-freeze-economics.md)
  — freeze costs from r11/r12/r10d, per-lane build roots, the SLA
  escalation protocol.

## Session sources

- /tmp/ggen-split — the real working pipeline (manifest, ontology,
  query, template, run.json, out/all-modules.txt, tree/ 25 files, ebin/
  25 beams).
- docs/jira/v26.10.29/receipts/r11-ggen-cache-port.md,
  r12-ggen-idp-port.md, r2-t02-saml-idp.md, r3-t03-consumer-court.md,
  r10d-tail-b.md.
- ~/.claude/skills/run-ggen/SKILL.md — treated as a source; where this
  session's live evidence differs (flag surface, versions), this guide
  cites the live run.
