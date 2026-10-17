# ERROR_CODES generator — lease contract

The admitted policy lives at `tmp/errc/coordinator-unblocks.md` (2026-10-15 09:40
admission). This file is its mechanical home: what the seam is, who regens when,
and the fence. If this file and the policy receipt drift, the receipt wins until
the coordinator re-admits.

## The seam

One generator, `scripts/gen_error_codes.py`, projects `docs/ERROR_CODES.md` from
three source families:

1. `lib/smalt/arm_gateway/router.ex` (`send_arm_error` sites + pinned
   InvalidResourceShape + inline 412 envelope)
2. `lib/smalt/egress_router.ex` (send sites + helper envelopes + fixed rows)
   — the file's egress extraction keeps a
   pending-status pairing heuristic with a ~400-char window; hardening (lens 4)
   makes any unpaired egress "code" literal exit 1 with a typed
   `UNRESOLVED_STATUS` message instead of emitting a silent `| egress | ? |`
   row.
3. `test/compliance/*.exs` (`["code"] == "..."` assertions; "?" status by
   design — the corpus pins the code, not the status)

The doc is a projection; edit the sources (or the ANNOTATIONS table), never the
generated file.

Escape scheme (lens 5): the generator's `esc/1` escapes a literal backslash
FIRST (`\\`), then pipes (`\|`), then flattens newlines. Both consumers —
`Smalt.DSPy.Remediation.split_row/1` and the fence's `parse_row_lines/1` —
scan for unescaped separators in a single pass (`\x` consumes both chars),
so `esc` and the parsers are exact inverses: any annotation content,
including backslashes, pipes, and a trailing escaped pipe, round-trips.
Any change to `esc` or the scanners must keep the round-trip property and
carry a mutation proof (see Mutation standard).

## Lease: who regens when

- Any lane whose landing touches a wire-visible error path (`router.ex`,
  `egress_router.ex`, engine error tuples, sentinel/KV/blob error shapes,
  `test/compliance/*.exs` rows) runs `python3 scripts/gen_error_codes.py` as
  the FINAL step of its receipt — same as ARM's regen-last precedent.
- Lanes not touching wire error paths are exempt.
- A fence failure (`test/error_codes_doc_test.exs` → `--check` exit 1) observed
  from ANOTHER lane's landing is ROUTED to that lane as a typed
  `POLICY_MISS[wire-error-path-without-regen]`; the observer does not regen
  unilaterally (regen-race avoidance). The runtime-contracts lane regens only
  when (a) the landing lane's session has closed (receipt final, no follow-up
  cycle) or (b) the coordinator directs it — then it regens, discloses in its
  own receipt, and routes the miss.
- This lane (runtime-contracts) owns `scripts/gen_error_codes.py` and
  `docs/ERROR_CODES_GENERATOR.md` by lease; other lanes regenerate the doc via
  the command, they do not edit the generator.

## The fence

`test/error_codes_doc_test.exs` runs `--check` and fails on any drift —
including line-cite drift, which is expected under fan-out churn. Expected
firings: any egress/arm/compliance landing without regen. A firing with NO
recent source landing is a defect signal, not churn.

## Mutation standard

Any change to the generator's extraction patterns must be mutation-proven:
delete or perturb a pattern and show the fence (or the new UNRESOLVED_STATUS
fail-closed) fires; restore byte-identical. See
`tmp/errc/runtime-contracts-lens4/cycle-N.md` receipts for examples.

## See Also

- `docs/ERROR_CODES.md` (the generated projection this contract covers)
- `docs/jira/v26.10.16/receipts/r11-error-codes-regen.md` (regen + drift-fence receipt)
