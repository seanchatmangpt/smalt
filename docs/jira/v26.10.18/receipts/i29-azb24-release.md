# I29 — AZB-24 release mint (publish-dry green; court-x2 typed-RED carried)

- **Window**: v26.10.18 / i29
- **Subject**: AZB-24 release mechanics at the v26.10.18 wrap tree,
  HEAD `67856850c7645599acb7e2ac852c8d7f76115ee3`
- **Standing**: PARTIAL_ALIVE — publish-dry 4/4 gates PASS (exit 0); the
  release receipt mint is PENDING (exact command below; not run by this lane)
- **Context**: solo(/Users/sac/smalt)
- **Date**: 2026-10-19

## Wrap-tree verification (verbatim output)

```
$ git status --porcelain
 M docs/jira/v26.10.16/sdk-results/spc-bands.md
 M docs/jira/v26.10.18/FINAL.md
 M docs/jira/v26.10.18/receipts/i29-court-x2-final.md
?? docs/jira/v26.10.18/receipts/azb-23-court-x2.md
?? docs/jira/v26.10.18/receipts/i29-courtface-verify.md
```

The 3 modified typed-RED/final docs for the coordinator:
`docs/jira/v26.10.16/sdk-results/spc-bands.md`,
`docs/jira/v26.10.18/FINAL.md`,
`docs/jira/v26.10.18/receipts/i29-court-x2-final.md`; plus 2 untracked new
receipts (`azb-23-court-x2.md`, `i29-courtface-verify.md`).

```
$ python3 scripts/gen_error_codes.py --check
docs/ERROR_CODES.md up to date
exit=0
```

## publish-dry — PASS, exit 0 (verbatim output)

```
$ just publish-dry
== publish dry-run gate: /Users/sac/smalt ==

-- gate 1: mix hex.build -o /tmp/hex-publish-dry/smalt.tar
   PASS (tarball: 804352 bytes; log: /tmp/hex-publish-dry/smalt.tar.build.log)

-- gate 2: inner-tar key grep (pattern: signing.key|verifying.key|\.ggen|keys/)
   PASS (0 matches in contents.tar.gz listing)

-- gate 3: packaged-set leak grep (pattern: legacy-client|/Users/sac)
   PASS (0 hits in packaged set at /tmp/hex-publish-dry/smalt.tar.unpacked)

-- gate 4: python3 scripts/gen_error_codes.py --check
   PASS (docs/ERROR_CODES.md up to date)

== summary ==
PASS [gate1 hex.build]  PASS [gate2 inner-tar keys]  PASS [gate3 leak grep]  PASS [gate4 error-codes]
publish released pending final court-x2 (rotation EXECUTED 2026-10-15)
exit=0
```

## Mint — PENDING (skipped on an arg conflict, per task step 4's skip clause)

The task-specified mint used `--exit-code 0`, but the required
`--court-log tmp/court-x2-1792402305.log` ends
`[COURT-X2] RECEIPT: gate FAILED (see above).` /
`recipe 'court-x2' failed on line 8 with exit code 1`. BUMP-PLAN §3 requires
the real court-x2 exit; a release receipt recording `exit_code: 0` bound to
the sha256 of a FAILED gate log would be a false receipt. Skipped rather
than guessed. Exact command for the coordinator:

```bash
python3 scripts/mint_release_receipt.py \
  --sha 67856850c7645599acb7e2ac852c8d7f76115ee3 \
  --refusals tmp/azb24-typed-refusals.json \
  --court-log tmp/court-x2-1792402305.log \
  --release v26.10.18 \
  --ref main \
  --command "just court-x2" \
  --exit-code 1 \
  --standing "TYPED-RED CARRIED: 8 gate attempts 1792397604..1792402305, no two consecutive greens; gate carried to v26.10.19 (azb-23-court-x2.md)" \
  --court-standing RED_COURT_X2 \
  --type RELEASE_ADMISSION_COURT \
  -o docs/jira/v26.10.18/receipts/azb24-release-receipt.json
```

`tmp/azb24-typed-refusals.json` is written and matches the shape
`load_refusals/1` accepts (`scripts/mint_release_receipt.py` lines 49-57:
object with a `refusals` list). The only deltas from the task command are
`--exit-code 1` and the TYPED-RED standing/court-standing, matching the
court log's actual exit — exit 0 in the receipt would require a real
two-green court-x2 first.

## FINAL.md §3

Already filled by the typed-RED lane: verdict TYPED-RED CARRIED, attempt
ledger, per-run verdict table, green witnesses, residual race family, close
condition. No edit made. Note: the task brief said 6 attempts; disk shows
8 gate entries (1792397604 → 1792402305) in
`docs/jira/v26.10.18/receipts/i29-court-x2-final.md` and FINAL.md §3 — the
receipts and logs are the ground truth.
