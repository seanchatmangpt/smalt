# smalt-01 gcp wire parity first green receipt

Standing: UNVERIFIED

## Problem

Every GCP parity cell is UNVERIFIED: KD-GCP-05 (OPEN) in
`/Users/sac/smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` and
`/Users/sac/smalt/docs/gcp-parity/GCP_WIRE_PARITY.md`
say no cell is PASS. Observed this session: the smalt gcp+aws test dirs gave 76 passed,
but no receipt records it, so the register still reads OPEN.

## Acceptance

- Run the `/Users/sac/smalt/test/gcp` suite via mix and save the output to
  `/Users/sac/smalt/docs/gcp-parity/GREEN-RUN.md` with the SHA.
- Flip each GCP_WIRE_PARITY.md cell to PASS or a KD-GCP-nn row (none silent).
- Expected: 0 failures; KD-GCP-05 status moves to CLOSED-WITH-RECEIPT citing the file.

## Falsifier

Break one assertion in `/Users/sac/smalt/test/gcp/storage_test.exs`; the run must fail and the
matching cell must not stay PASS.

## Owned files

/Users/sac/smalt/docs/gcp-parity/GCP_WIRE_PARITY.md, /Users/sac/smalt/docs/gcp-parity/GREEN-RUN.md,
/Users/sac/smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md (KD-GCP-05 row only)

## Depends-on

none

## Size

S

## References (path : LOC)

- /Users/sac/smalt/docs/gcp-parity/GCP_WIRE_PARITY.md : 30 lines
- /Users/sac/smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md : 386 lines
- /Users/sac/smalt/test/gcp/storage_test.exs : 113 lines
- /Users/sac/smalt/test/gcp/ : 9 files, 860 lines total
- /Users/sac/smalt/docs/gcp-parity/GREEN-RUN.md : NEW (0 lines, to be created; est. LOC: 40; SHA
  header + command + tail of mix output + 30-row cell table)

## Result

Standing: UNVERIFIED

No run observed (build/test blocked for subagents). Created
/Users/sac/smalt/docs/gcp-parity/GREEN-RUN.md (~45 LOC: header, placeholder output, cell-to-test
map). GCP_WIRE_PARITY.md and KD-GCP-05 unchanged; flipping them needs real output.

## Repair

W9-01: GREEN-RUN.md placeholders replaced with explicit UNRECORDED / NOT A RECEIPT text and the
"Expected: 0 failures" prediction removed. The 76-passed figure is uncited (no record). Cell map
lists 8 cells, not a 30-row table; coverage against GCP_WIRE_PARITY.md is unproven until the
coordinator diffs cell IDs (silent-skip risk, open).

Coordinator acceptance: `cd /Users/sac/smalt && mix test test/gcp 2>&1 | tee /tmp/gcp.out`; paste
SHA + tail into GREEN-RUN.md, flip cells to PASS, set KD-GCP-05 to CLOSED-WITH-RECEIPT.
