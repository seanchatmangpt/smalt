# run-a-single-rule

How to render exactly one rule when `ggen sync run` has no `--rule` flag.

## Problem

You have a manifest with several `[[generation.rules]]` and want to render
one of them. The CLI has no per-rule selection: every rule in the resolved
`ggen.toml` renders on every `ggen sync run`.

Source of truth (this session):

- `ggen sync run --help` (ggen 26.10.11) lists exactly: `--dry-run`,
  `--format`, `--select`, `--watch`, `--consumer-mode`, `--introspect`,
  `--structured-errors`, `--autonomic`. No rule flag.
- The flag surface and its consequence were re-verified this session; the
  same absence is documented in `~/.claude/skills/run-ggen/SKILL.md`
  ("No `--rule` flag exists, and there is no per-rule selection at all").

## Fix: the single-rule-manifest pattern

Put the one rule in its own manifest directory and run there.

```bash
mkdir -p one-rule/{ontology,queries,templates,out}
cd one-rule
# ontology/, queries/, templates/ — copy or author the pieces rule X needs
# write a ggen.toml containing ONLY rule X's [[generation.rules]] stanza
ggen sync run
```

The manifest still needs the full `[project]`/`[ontology]`/`[generation]`
header (see the minimal shape in
[the tutorial](../tutorials/ggen-first-sync.md#step-2--the-manifest)).

## When you need one rule's query in a bigger manifest

Keep the rule in the big manifest for the normal full render, and keep a
scratch single-rule manifest for the debug loop. The /tmp/ggen-split
project is the real example: one rule, one template, one output
(`out/all-modules.txt`) — authored as a standalone directory precisely so
each `ggen sync run` does exactly one thing (see
[bulk-generate-scaffolds](../how-to/bulk-generate-scaffolds.md)).

## Do not

- Do not try `--select` — it projects the JSON summary output, not rule
  selection (verified against `ggen sync run --help` this session:
  "Select/project nested JSON output using JSONPath, key selection, or
  JMESPath query projections").
- Do not glue a second rule into a manifest and expect selection later;
  there is no later. Author the debug manifest from the start.

## Related

- [point-ggen-at-a-manifest](../how-to/point-ggen-at-a-manifest.md) —
  where a manifest may live
- [the sync-run contract](../reference/ggen-sync-run-contract.md)
