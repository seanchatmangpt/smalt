# Docs From First Principles (the method behind this tree)

Understanding-oriented. This doc explains *why* the docs tree is
shaped the way it is, and why the shape was derived rather than
inherited. The derivation of record is
`docs/jira/v26.10.16/DOCS-INVENTORY.md` (the ideal docs DAG, derived
from landed reality: 137 defmodules, 46 app-env keys, the court chain,
the gates, the receipts). The disposition plan is
`docs/jira/v26.10.16/docs-restructure-plan.md` (Diátaxis mapping,
per-file disposition table, docs-dod impact).

## The method

Docs trees rot by accretion: each document is written for the decision
of its moment and then outlives the moment. The first-principles
method inverts the flow — derive the ideal tree from the *current*
subsystem inventory (audiences: hex consumer, clone dev, auditor), diff
it against what exists on disk, and grade every cell COVERS / STALE /
MISSING. The output is a work list, not a critique: each STALE/MISSING
row names its source-of-truth inputs (DAG edges), so the rewrite is a
projection of code, not of older docs.

## Why audience-first

The same fact serves three audiences in three registers. The golden
path is a tutorial claim ("run this, expect that"), a how-to
procedure, and a reference table — three files, three registers, one
fact, cross-linked rather than merged. Merging them is how a doc
becomes simultaneously too long to learn from and too vague to
execute. The Diátaxis quadrants (`docs/tutorials/`, `docs/how-to/`,
`docs/reference/`, `docs/explanation/`) are the mechanical form of that
split, with `docs/archive/` for dated receipts-in-prose (a receipt is
history; a living doc must not read like one).

## Why every why-doc is receipt-anchored

An explanation that cannot name the evidence for its claim is prose.
The explanation quadrant's convention (this rewrite): each why-doc
names the receipts that prove the decision it explains — the zero-touch
enclave ruling cites the T5/cleanroom receipts
(`docs/jira/v26.10.16/receipts/t5-cleanroom-validation.md`,
`docs/jira/v26.10.16/sdk-results/t5-cleanroom.md`,
`docs/jira/v26.10.16/sdk-results/native-lifecycle.md`); the two-green
court law cites the red post-mortems; the emulation stance cites the
census receipts. Receipt paths named in user-facing docs must exist on
disk — `just docs-dod-check` is the mechanical fence
(`justfile.d/12-docs-dod.just`), and a receipt path named here that
goes missing later fails the gate loudly.

## Why docs-dod is exit-gated

A link is a claim that a referent exists. The gate converts that claim
into a checked fact at every run, the same way the error-code drift
fence converts "docs match code" into a checked fact. The docs tree
ships the same discipline as the code tree: generated artifacts are
regenerated, references are gated, and a broken path is a MISS line
with exit 1 — loud, never a silent stale link.

## See Also

- `docs/jira/v26.10.16/DOCS-INVENTORY.md` — the derivation of record
  (COVERS/STALE/MISSING per audience)
- `docs/jira/v26.10.16/docs-restructure-plan.md` — the disposition
  plan (Diátaxis mapping, per-file table)
- `docs/archive/README.md` — archive scope
- `docs/explanation/architecture.md` — the tree's architecture home
