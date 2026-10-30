# POSH-009: SDK-parity register for posh faces

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
