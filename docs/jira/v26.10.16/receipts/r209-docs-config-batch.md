# Receipt — R209 (docs/config accuracy batch)

- **Subject:** `/Users/sac/smalt` @ main, working tree (lane 294, W11 docs lane)
- **Standing:** PASS (all three claims verified against disk 2026-10-16)
- **Date:** 2026-10-16
- **Audit coverage:** closes unaccounted-diff items 9, 10, 12 of the
  2026-10-16 pre-commit audit.

## What landed

- **docs/JUST_REFERENCE.md justfile.d section** (lines 46–107): documents
  the module-import pattern (lanes add `justfile.d/NN-*.just` + one import
  line), per-module descriptions for all 18 modules, and the just-1.56
  shebang-recipe rule with the GAP_SYNC_ROOT canonical fix.
- **repo-root CLAUDE.md agent-config section**: pins dispatch to the five
  repo-defined agents in `.claude/agents/` (bench-runner, kd-registrar,
  milestone-doc, shim-court-author, substrate-op) plus read-only Explore,
  bans the built-in generics, and requires absolute repo paths in subagent
  prompts.
- **test/sdk-python/README.md venv mapping table**: pins each PY probe to
  its venv identity (7 named venvs, one per probe family).

## Verification (2026-10-16, lane 294, unedited output)

```
$ just --list | grep -cE '^\s{4}\S'          # doc claims 59 recipes
59
$ ls justfile.d/*.just | wc -l               # doc claims 18 modules
18
$ ls .claude/agents/
bench-runner.md
kd-registrar.md
milestone-doc.md
shim-court-author.md
substrate-op.md
$ for v in arm blob cosmos eh sb rg auth; do [ -d "test/sdk-python/.venv-$v" ] && echo ".venv-$v EXISTS" || echo ".venv-$v MISSING"; done
.venv-arm EXISTS
.venv-blob EXISTS
.venv-cosmos EXISTS
.venv-eh EXISTS
.venv-sb EXISTS
.venv-rg EXISTS
.venv-auth EXISTS
```

All three docs' concrete claims check out: 59 recipes / 18 modules match
JUST_REFERENCE.md:50-51; the five agents CLAUDE.md names all exist on disk;
all seven venv dirs named in the README table exist. Standing PASS.
