# G13 — Two-provider limbo: archived Elixir spike vs canonical Go provider

Status: ALIVE (2026-10-30, read-mostly sweep + live recipe execution).
Scope: references to `provider_court.sh`, `terraform-provider-smalt` (the deleted root
spike), `mix escript`, `57-tf-provider` across docs/jira/posh/**, justfile.d/57+58,
receipts/, READMEs, dfcharter/*.
Canonical: Go provider at `adapters/terraform-provider-smalt/`
(terraform-plugin-framework v1.19.0); `just posh-court` (58-posh.just) is the GA
admission path.

## New finding (this sweep): the spike dir is not fully gone

`/Users/sac/smalt/terraform-provider-smalt/` exists again — an untracked tombstone
stub holding only `README.md` (mtime Oct 30 12:07) that correctly says
"ARCHIVED/SUPERSEDED → adapters/terraform-provider-smalt + just posh-court".
Consequences:

- The POSH-007 receipt's falsifier check (`test ! -d .../terraform-provider-smalt`)
  is now STALE — re-run fails; the archive tarball itself is verified present.
- `justfile.d/57-tf-provider.just` recipes still default `SMALT_TF_DIR` to this dir
  and are tombstone-blind (§ below).

## Reference classification

- R1 `justfile.d/57-tf-provider.just` — headers self-declare spike, "NOT the GA
  admission path"; `provider-court` is a loud DEPRECATED alias →
  `provider-court-elixir`. ARCHIVE-OK (text) / CONFUSED (behavior, § below).
- R2 `justfile.d/58-posh.just:40` — "57 (Elixir spike — do not modify; this module
  builds the Go successor)". ARCHIVE-OK.
- R3 `README.md:433-434` — "terraform-provider-smalt, archived per POSH-007" with a
  Go provider under `adapters/terraform-provider-smalt`. CANONICAL-OK.
- R4 `adapters/terraform-provider-smalt/README.md` — quickstart cd's into the
  adapters tree, `dev.tfrc` dev_overrides. CANONICAL-OK.
- R5 POSH-007 ticket, `migration-ledger.md`, `receipts/migration/*` — spike
  archived to `tmp/posh/archive/terraform-provider-smalt-elixir-spike-20261030.tar.gz`
  (verified present), per-file dispositions, spike `scripts/provider_court.sh`
  discarded. ARCHIVE-OK; the receipt falsifier check is now stale (tombstone).
- R6 `gaps/09-courts-matrix.md:30-34` — 57 is "self-declared NOT the GA admission
  path"; GA court is `posh-court`. ARCHIVE-OK.
- R6a `gaps/09-courts-matrix.md:63-65` — Elixir courts "re-runnable via `just
  provider-court-elixir`". CONFUSED — false post-tombstone; a run now dies at
  provider-build.
- R7 `dfcharter/design.md:273` — tree diagram lists root `terraform-provider-smalt/`
  as "provider (POSH-004, dev_overrides)". CONFUSED — presents the archived spike
  as the live provider; canonical is `adapters/`.
- R8 `dfcharter/design.md:356` — "Existing capital:
  `.../terraform-provider-smalt/scripts/schema_inventory_gate.py`". CONFUSED —
  path deleted 2026-10-30; file survives only in the archive tarball.
- R9 `dfcharter/verify.md:92-96` — §3 SUPERSEDED banner: stage table "spec'd
  against `.../provider_court.sh`, the archived Elixir spike". ARCHIVE-OK.
- R10 `receipts/schema_parity_live.md` — reference run rebuilt the escript FROM
  the archive tarball (`tar -xf` → `mix escript.build`, exit 0). ARCHIVE-OK.
- R11 `receipts/final-wave-receipt.md:48-53` — notes `adapters/.../scripts/` holds
  only `build_install.sh`, ... PARTIAL-STALE (as-of-date, no rewrite owed) —
  adapters/scripts now also holds `court/`, `provider_court.sh`,
  `dev_overrides.sh`, `tfrc.sh`, `receipts/`.
- R12 `gaps/05-ci-cd.md` dependabot row — `terraform-provider-smalt` named as a
  gomod entry, i.e. the adapters/ Go module. CANONICAL-OK.
- R13 `gaps/02-smalt-arm-vs-azure.md`, `gaps/12-runbook.md` — cite archive tarball
  paths / adapters example roots. ARCHIVE-OK / CANONICAL-OK.

## Does 57-tf-provider.just still parse/run? (witnessed 2026-10-30)

Parse: yes — the module imports clean; all recipes register.

`just provider-build` actual output:
```
[TF-PREREQ] just/kubectl/terraform/mix present (go not required)
** (Mix) Could not find a Mix.Project, please ensure you are running Mix in a directory with a mix.exs file
[TF-BUILD-FAIL] mix escript.build exited nonzero in terraform-provider-smalt
error: recipe `provider-build` failed with exit code 1
```
Semi-typed: exit 1 with a `[TF-BUILD-FAIL]` line, but the message is mix.exs-shaped
("land it first" implication) when the truth is the tree is ARCHIVED. The recipes
have no archive-awareness and the tombstone README is never read.

- `provider-install`: dies earlier at provider-build; its own typed
  `[TF-INSTALL-FAIL] $s missing` guard is unreachable.
- `provider-court-elixir` / deprecated `provider-court`: run the full kind ladder
  (kind-up/images/deploy + 60x1s healthz poll) and only then die at provider-build —
  loud but late: a doomed court burns the whole ladder before failing.

## Verdict table

| Surface | Verdict |
|---|---|
| justfile.d/57-tf-provider.just | CONFUSED (behavior) — tombstone-blind, misleading failure mode |
| justfile.d/58-posh.just | CANONICAL-OK |
| README.md (root) | CANONICAL-OK |
| adapters/terraform-provider-smalt/README.md | CANONICAL-OK |
| posh docs POSH-007 + ledgers + receipts | ARCHIVE-OK (falsifier check stale) |
| gaps/09-courts-matrix.md | CONFUSED only at line ~63 ("re-runnable") |
| dfcharter/design.md :273, :356 | CONFUSED |
| dfcharter/verify.md §3 | ARCHIVE-OK |
| receipts/final-wave-receipt.md | PARTIAL-STALE (as-of-date) |
| tombstone terraform-provider-smalt/README.md | ARCHIVE-OK |

## Close conditions

1. **Collapse 57 into loud archive-stub recipes** (primary, ERRC: delete/tighten).
   First line of `provider-build`, `provider-install`, and — critically, BEFORE the
   kind ladder — `provider-court-elixir`:
   `[ -f {{SMALT_TF_DIR}}/mix.exs ] || echo "[TF-ARCHIVED] use just posh-court" >&2`
   Exit 4 = typed ARCHIVED refusal, distinct from exit 3 (prereq) and 1 (build).
   `provider-status` stays report-only; keep the deprecated `provider-court` alias
   delegating to the stub (banner already names `just posh-court`).
   Falsifier: `just provider-build` exits 4 with `[TF-ARCHIVED]`, not exit 1 with a
   mix.exs-shaped message.
2. **Fix dfcharter/design.md** :273 → `adapters/terraform-provider-smalt/` and :356
   → rehome the schema_inventory_gate.py reference to the archive tarball or its
   adapters/scripts/court equivalent.
3. **Fix gaps/09-courts-matrix.md:63-65**: replace "re-runnable via `just
   provider-court-elixir`" with "archived — see 57's [TF-ARCHIVED] stub; GA court is
   `just posh-court`".
4. **Resolve the tombstone ambiguity, pick one**: (a) hard-delete the root dir —
   the posh007 falsifier check `test ! -d terraform-provider-smalt` passes again;
   or (b) keep the tombstone and amend the receipt falsifier to
   `test -f terraform-provider-smalt/README.md`-style tombstone-awareness. Per ERRC
   asymmetry (delete outranks keep), (a) is preferred — the archive tarball already
   preserves everything. Today neither holds.
5. **Receipt hygiene**: final-wave-receipt's adapters/scripts enumeration is
   as-of-date — no rewrite owed; R6a is a live-doc claim and must change (CC-3).

## Status

ALIVE — sweep executed 2026-10-30: greps over docs/jira/posh/**, justfile.d/,
receipts/, READMEs, dfcharter/*; live `just provider-build` and `just
provider-install` runs witnessed (exit 1, [TF-BUILD-FAIL]); tombstone README read;
archive tarball presence verified; posh007 receipt falsifier check re-derived stale.
