# POSH-009: SDK-parity register for posh faces

**DIALECT-SCOPED: dialect #1 (Azure ARM/azurerm)** — the parity target "the
real Azure surface smalt emulates" reads as the **dialect-#1 surface**; gate
semantics unchanged. Stamp added by GAP-15 wave-2 doc migration (lane 15);
decision record: `../v26.10.31/00-unification-dialect-decision.md`.

## Task
Per the smalt SDK-parity discipline (KNOWN_DIVERGENCES.md + coverage compiler):
derive the posh surface inventory mechanically (from posh's exposed RPC/CLI
surface), assert every cell is pass / registered-divergence / loudly-MISSING vs
the real Azure surface smalt emulates. Register file posh/KNOWN_DIVERGENCES.md;
compiler scripts/posh_coverage.py; gate exits 1 on silent gaps.

## Acceptance
Coverage gate green on scaffold with the v1 face set; a deliberately removed face
flips its cell to MISSING and the gate exits 1.

## Falsifier
A gate that accepts an empty inventory is vacuous — mutation court required.
