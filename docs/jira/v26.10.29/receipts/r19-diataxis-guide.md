# r19-diataxis-guide

- window: v26.10.29 · lane: DOCS-DIATAXIS (r19) · date: 2026-10-29
- standing: **ALIVE** — all four Diátaxis quadrants + index authored;
  guide gates green (H1 match 16/16, 100-char law, zero dead links,
  balanced fences, corruption sweep clean); every claim grounded in this
  session's receipts, live command output, or on-disk files re-read this
  session.

## Scope honored

Owned tree only: `docs/jira/v26.10.29/diataxis/**` + this receipt. No git
state commands; no writes outside ownership; no compile/test runs (docs
lane); no Process.sleep anywhere in the lane.

## What was authored (16 files, 1,408 lines)

- tutorials/ggen-first-sync.md (215) — zero-to-green, typeable verbatim;
  both query laws shown as live-reproduced errors; real /tmp/ggen-split
  excerpt embedded; how-tos cross-linked.
- how-to/run-a-single-rule.md (58) — no --rule flag;
  single-rule-manifest pattern.
- how-to/point-ggen-at-a-manifest.md (60) — no --manifest flag; cwd-only
  resolution; stage-temp-copy-then-rm; when NOT to.
- how-to/bulk-generate-scaffolds.md (131) — split-scaffold pattern; both
  real defects with live-reproduced errors and proven fixes.
- how-to/adopt-generated-code-safely.md (72) — lease-render, atomic mv,
  ownership disclosure, header law.
- how-to/regenerate-without-losing-handwork.md (75) — config.ex
  incident, union-merge recovery, lawful end-state.
- how-to/extend-the-capability-graph.md (94) — ConfigKey/IdentityFace
  rows through capabilities.json; standing vocabulary; refusals.
- reference/ggen-sync-run-contract.md (125) — verified flag surface,
  error taxonomy, path law, JSON summary fields.
- reference/tera-gotchas.md (80) — four gotcha classes, live vs cited.
- reference/smalt-generation-pipeline.md (94) — three chains,
  smalt.gen.ex stanza cites.
- reference/version-drift.md (48) — three identities, discipline.
- explanation/generated-files-are-projections.md (65) — GGM-SRC-002,
  config.ex incident from both sides.
- explanation/ontology-first-decomposition.md (58) — plan-as-graph,
  boundary-not-behavior limit.
- explanation/vacuous-courts-and-real-clients.md (70) — same-calculus
  courts, real-consumer law.
- explanation/multi-agent-compile-freeze-economics.md (80) — freeze
  costs, SLA protocol, polling discipline.
- README.md (83) — quadrant map, one line per file, session sources.

## Grounding sources (read this session)

- /tmp/ggen-split: ggen.toml, ontology/split.ttl, queries/extract.rq,
  templates/module.ex.tera, run.json, out/all-modules.txt (425 lines),
  tree/ (25 files), ebin/ (25 beams — `ls /tmp/ggen-split/ebin/*.beam |
  wc -l` → 25)
- receipts: r11, r12, r2, r3, r10d
- ~/.claude/skills/run-ggen/SKILL.md + smoke.sh
- smalt files: lib/mix/tasks/smalt.gen.ex, lib/smalt/projection/
  canonical.ex, lib/smalt/config.ex, lib/smalt/mcp/gen/
  smalt_mcp_surface.ttl, lib/smalt/mcp/generated/mcp_descriptor.ex,
  docs/capabilities.json, docs/THIRD_PARTY.md
- ~/ggen/Cargo.toml (line 2: version 26.10.12)

## Live-reproduced evidence (scratch /tmp/r19-repro.5GY9Zd)

| Defect | Evidence |
|---|---|
| Unbound projected var | exit 1; `[FM-GEN-008]`; "Variable not found in context" |
| Heredoc glue | junk line `SHEOFcat >> out/...`; fix `grep -c "SHEOFcat"` → 0 |
| Missing ORDER BY | exit 1, `error[E0013]: ... SELECT query lacks ORDER BY` |
| `..` traversal | exit 1, `[FM-WRITE-002]` "contains a traversal component" |
| Green control | exit 0; JSON summary with closure/decisions/graph_hash_hex fields |

## Gate results (re-run after final edits)

- H1 matches filename: 16/16 OK.
- 100-char law: PASS — zero lines over 100 in all 16 files.
- Dead relative links: PASS — per-file-relative resolution, all resolve.
- Balanced code fences: PASS — even fence count in every file.
- Corruption sweep: PASS — remaining hits are legitimate content (the
  scaffolds' "Boundary placeholder only" moduledoc, the mktemp template,
  one prose use of "placeholder files" as a foil).

## Per-file grounding table (real command output, this session)

`wc -l` + `grep -c` pair (receipt-cites pattern: receipt ids
r11/r12/r10d/r2/r3 + receipts/r*; source-cites pattern: /tmp/ggen-split,
SKILL.md, smalt.gen.ex, canonical.ex, run.json, config.ex, ggen.toml,
split.ttl, module.ex.tera, extract.rq, Cargo.toml, emit.sh,
capabilities.json, mcp_descriptor, smalt_mcp_surface, all-modules):

```text
FILE | LINES | RECEIPT-CITES | SOURCE-CITES
./explanation/generated-files-are-projections.md |       65 | 4 | 11
./explanation/multi-agent-compile-freeze-economics.md |       80 | 15 | 0
./explanation/ontology-first-decomposition.md |       58 | 0 | 4
./explanation/vacuous-courts-and-real-clients.md |       70 | 9 | 0
./how-to/adopt-generated-code-safely.md |       72 | 10 | 3
./how-to/bulk-generate-scaffolds.md |      131 | 0 | 16
./how-to/extend-the-capability-graph.md |       94 | 10 | 5
./how-to/point-ggen-at-a-manifest.md |       60 | 1 | 10
./how-to/regenerate-without-losing-handwork.md |       75 | 7 | 8
./how-to/run-a-single-rule.md |       58 | 0 | 5
./README.md |       83 | 4 | 8
./reference/ggen-sync-run-contract.md |      125 | 0 | 13
./reference/smalt-generation-pipeline.md |       94 | 4 | 17
./reference/tera-gotchas.md |       80 | 0 | 4
./reference/version-drift.md |       48 | 0 | 6
./tutorials/ggen-first-sync.md |      215 | 1 | 19
16 files, 1408 lines total
```

## Honesty notes

- The dispatch figure "~70 min aggregate polling in GGEN-IDP alone" is
  NOT in the guide: no receipt carries it. The economics page uses r11's
  "45+ attempts across ~30 min" and r12's 22:00-23:01 ledger instead.
- "17 concurrent lanes" appears once (adopt-generated-code-safely),
  attributed to wave dispatch with the 21-receipt directory as the
  on-disk witness.
- The r12 rdflib witness row is reflowed to fit the 100-char law
  (noted in place); verbatim source in r12 §2.
- Files showing zero receipt-cites ground in session command output
  instead (e.g. contract page: `--help`, E0013/FM-GEN-008/FM-WRITE-002
  runs; bulk-generate-scaffolds: 16 /tmp/ggen-split + live-repro cites).
- guide gates re-run after every edit wave; final state green.

## Files touched by this lane

- docs/jira/v26.10.29/diataxis/README.md
- docs/jira/v26.10.29/diataxis/tutorials/ggen-first-sync.md
- docs/jira/v26.10.29/diataxis/how-to/{run-a-single-rule,
  point-ggen-at-a-manifest,bulk-generate-scaffolds,
  adopt-generated-code-safely,regenerate-without-losing-handwork,
  extend-the-capability-graph}.md
- docs/jira/v26.10.29/diataxis/reference/{ggen-sync-run-contract,
  tera-gotchas,smalt-generation-pipeline,version-drift}.md
- docs/jira/v26.10.29/diataxis/explanation/{generated-files-are-projections,
  ontology-first-decomposition,vacuous-courts-and-real-clients,
  multi-agent-compile-freeze-economics}.md
- docs/jira/v26.10.29/receipts/r19-diataxis-guide.md (this receipt)

Scratch dirs created this session: /tmp/r19-repro.5GY9Zd (live-repro
lease). No git state transitions performed.
