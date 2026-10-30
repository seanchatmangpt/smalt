# point-ggen-at-a-manifest

How to run ggen against a manifest that is not in your current directory.

## Problem

`ggen sync run` reads `ggen.toml` from its current working directory only.
There is no `--manifest` flag (verified this session against
`ggen sync run --help` on ggen 26.10.11, and documented in
`~/.claude/skills/run-ggen/SKILL.md`).

## The cwd-only resolution law

- `output_dir` and every rule's `output_file` resolve relative to wherever
  `ggen.toml` itself lives — which is always the cwd. They do NOT resolve
  relative to the ontology/query/template files.
- A `..` component in a resolved output path is rejected:
  `[FM-WRITE-002]` "`to:` path '../all-modules.txt' contains a traversal
  component; it must stay inside the project root" (reproduced this
  session, exit 1).

Consequence: keep `ggen.toml`, `ontology/`, `queries/`, `templates/`, and
the output tree under one directory you `cd` into. /tmp/ggen-split is the
real shape.

## Fix: stage-temp-copy-then-rm

If the manifest lives elsewhere, stage a temporary copy at the cwd you
want outputs to land in:

```bash
cp path/to/your-manifest.toml ggen.toml
ggen sync run
rm ggen.toml
```

The `rm` belongs in the same command chain, not "later". Two laws:

1. Never leave a temp `ggen.toml` at a project root. A stray root-level
   manifest changes what the next `ggen sync run` in that cwd renders —
   in a shared checkout, the next lane inherits your manifest.
2. Never stage a temp manifest that resolves `output_file`s into paths
   the real project owns; the render writes real files.

## When NOT to stage a temp copy

Do not stage a copy into a shared checkout you do not own (a lane or a
colleague's in-flight tree). /tmp/ggen-split is the working alternative:
a standalone scratch tree with its own manifest, outputs under its own
`out/` — landed into the real repo later by atomic `mv` (the pattern r11
used for registry.ex: rendered in /tmp/gc1-lease, formatted with smalt's
own .formatter.exs, atomic mv into the repo — see
[adopt-generated-code-safely](../how-to/adopt-generated-code-safely.md)).

## Related

- [run-a-single-rule](../how-to/run-a-single-rule.md) — one rule in one
  manifest
- [the sync-run contract](../reference/ggen-sync-run-contract.md) — flag
  surface and path resolution
