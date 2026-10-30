# 64 — Help / Completions (annotated help + `--list` truncation fix)

**Wave**: v26.10.30, lane 11/16. **Standing**: ALIVE (all verify commands ran this session, exits below).

## Witnessed defect

`just --list` (just 1.56.0) renders only the **LAST** line of a recipe's doc
comment — witnessed with a temp justfile (`# alpha first` / `# beta second`
→ list shows `beta second`). Every multi-line posh/provider doc comment
therefore displayed a continuation line instead of its summary:

- `posh-up` / `posh-down` — showed the `# ---` banner line (59-posh-ops.just)
- `posh-court`, `posh-vet`, `posh-smalt-wire`, `posh-invariant-court`,
  `posh-court-sla-test`, `compat-court`, `posh-regen-check`, `posh-status`,
  `posh-bootstrap` — showed a mid-sentence continuation line (58-posh.just)
- `provider-court`, `provider-court-elixir`, `provider-install`,
  `provider-status`, `tf-plan-smoke` — same class (57-tf-provider.just,
  root justfile)

## Fix (doc-comment rewrite, house style per 52-kind)

Every affected recipe now carries a single-line doc comment (the `--list`
surface): `# recipe — one-line summary.` Detailed notes move ABOVE a blank
line as detached `# Usage: ...` comment blocks — a blank line terminates a
doc comment, so detail lines never render in `--list`. Recipe bodies are
byte-unchanged; comment-only diff.

Files: `justfile.d/58-posh.just` (10 recipes), `justfile.d/59-posh-ops.just`
(2), `justfile.d/57-tf-provider.just` (4), `justfile` (1: `tf-plan-smoke`).

## Landed

1. **Annotated help** — `scripts/posh_help.sh` (+x), wired as `just posh-help`
   (single disclosed block appended to `justfile.d/58-posh.just`). Surface:
   recipe → summary → usage example → typical duration for the 31-recipe
   posh/provider family. Modes: full (default), `list`, per-recipe
   (`bash scripts/posh_help.sh posh-court` — via the script because just
   consumes extra args as recipes). Built-in drift guard: every help row is
   checked against `just --list`; a row with no recipe exits 2
   (`[POSH-HELP-DRIFT]`).
2. **Bash completion (optional, default-off)** — `posh/completions/posh.bash`:
   compgen over `just --list` filtered to `^(posh|provider|compat|tf-)`
   prefixes; `just posh-<TAB>` completes recipe names. Install documented in
   the file header; `complete -o default` falls through to just's default for
   non-posh prefixes. Exercised non-interactively: `_posh_just` returned all
   23 `posh-*` names.

## Verification receipts

```
just --list | grep -E 'posh|provider|compat|tf-'  → 31 rows, every row a
  single-line "recipe — summary" (before: 12 rows showed continuation lines)
bash scripts/posh_help.sh            → full annotated help, rc=0
bash scripts/posh_help.sh list       → 31 rows, rc=0
bash scripts/posh_help.sh posh-court → summary/usage/duration, rc=0
bash scripts/posh_help.sh bogus      → [POSH-HELP-FAIL] unknown recipe, rc=1
bash scripts/posh_help.sh list (drift guard pre-fix witness: rc=2 with
  [POSH-HELP-DRIFT] x31 when the name column was untrimmed — the guard is
  not vacuous; after trim, rc=0)
just posh-help                       → full help, rc=0
bash -n posh/completions/posh.bash   → clean
COMPREPLY exercise (source + _posh_just with cur=posh-) → 23 posh-* names
```

## Residual / non-goals

- Durations in the help table are engineering estimates, not measured SLAs
  (SLA clocks live in scripts/posh_sla.sh); the table cites them as "typical".
- `posh-help` accepts no recipe arg over the just wire (just treats extra
  args as recipes); per-recipe detail goes through the script.
- Completion is bash-only; zsh users get just's native completion.
- Other justfile.d modules (non-posh family) may carry the same multi-line
  doc-comment class; out of lane scope.
