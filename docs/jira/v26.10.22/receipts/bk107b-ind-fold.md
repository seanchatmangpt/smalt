# BK-107b — IND records fold: 6 industry packs + consumers into v26.10.22 milestone

**Standing:** **ALIVE** (doc fold; external landing receipts are the pack-lane
receipts in ggen-marketplace/ggen commits below). Context: solo.

## Subject

smalt's milestone record
(`docs/jira/v26.10.22/azure-industry-matrix.md`) did not reference the 6 IND
packs + consumers that landed in `/Users/sac/ggen-marketplace` and
`/Users/sac/ggen` (commits `a60c0b864`, `2a75d85bd`, `2e955c7b3`, `1ecaa7301`,
`0b4e701e8`, `edab453a0`, `e87d029fd`, `2e29ad2f4`, `258f1bdb0`, `14cada6c6`,
ggen side incl. `cc0602c6a`). This receipt + the appended "Examples landed"
section close that gap. No code changed; docs only.

## Fold table

| Industry | Pack (ggen-marketplace) | Consumer (ggen) | Qualification consequence | Mutation-court non-vacuity |
|---|---|---|---|---|
| Legal / e-discovery | `packs/industry-legal-ediscovery` | `examples/industry/legal-ediscovery` | 5 files rendered (`2026-Q-0001` evidence shapes, 20 triples) via `ggen sync run` | witness courts ALIVE (010 bates / 020 custodian / 030 wall-breach) |
| Financial | `packs/industry-financial-ledger` | `examples/industry/financial-ledger` | 5 files, consequence sha256 `a795fc8d` → `8bde79c4` (real-ggen qualified ALIVE) | exactly-once gate-fire courts green |
| Pharma 21 CFR | `packs/industry-pharma-21cfr` | `examples/industry/pharma-21cfr` | 91-triple rendered SHACL, `batch-201` chain, byte-identical double sync, BLAKE3 receipt | non-vacuity witness flips (4 gates: signature / audit-trail / CAPA / non-WORM) |
| Aero / defense | `packs/industry-aero-defense` | `examples/industry/aero-defense` | 24 files, consequence sha256 `7320fcb6` (real-ggen qualified ALIVE) | gate non-vacuity witnessed with fresh mutations (3 ASK gates: classification-complete, cross-level flow, non-loopback air-gap) |
| Manufacturing DfLSS | `packs/industry-manufacturing-dflss` | `examples/industry/manufacturing-dflss` | 5 files, consequence sha256 `a795fc8d` (real-ggen qualified ALIVE; graph_hash `d2497d51…`, replay-stable) | exactly-once gate-fire courts green |
| Semantic CAD/BIM | `packs/industry-semantic-cad-bim` | `examples/industry/semantic-cad-bim` | 25-triple rendered SHACL, hospital-tower graph (3 storeys / 5 elements / rev0→rev2) | mutation court REFUSEs injected defects |

External commits: marketplace `a60c0b864`, `2a75d85bd`, `2e955c7b3`,
`1ecaa7301`, `0b4e701e8` (+ `edab453a0`, `e87d029fd`, `2e29ad2f4`,
`258f1bdb0`, `14cada6c6` in the operator brief; consumer-side `cc0602c6a`
in ggen). Qualification/mutation-court status lines are quoted from each
lane's landing-commit message (verified `git log` in both repos
2026-10-21).

## Verification (real output)

1. All 12 external paths exist on disk (6 packs in
   `/Users/sac/ggen-marketplace/packs/industry-*`, 6 consumers in
   `/Users/sac/ggen/examples/industry/*`): loop checked each, 12/12 OK.
2. `just docs-dod-check` → **exit 0**, all `OK` lines, zero MISS. The gate
   is a pinned in-repo path list and does not include the external
   ggen/ggen-marketplace paths; those were verified directly (1) instead —
   gate scope unchanged, no gate edit.

## DoD

- [x] Matrix section appended, names pack/consumer path per industry with
      consequence sha256 + mutation-court status.
- [x] External paths verified on disk (12/12).
- [x] `just docs-dod-check` exit 0.
- [ ] Commit — intentionally NOT done (lane hands off; coordinator owns git).
