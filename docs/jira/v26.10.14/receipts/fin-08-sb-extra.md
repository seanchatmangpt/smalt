# fin-08 — sb-extra.probe.cjs CRC coverage

- Lane: fin-08 (DoD-only finish), 2026-10-15, repo `/Users/sac/smalt`
  (v26.10.14, branch `main`), no commits
- Task: TS-4 added `test/sdk-smoke/sb-extra.probe.cjs` (3 supplementary
  probes), coordinator-sanctioned but outside census registration, so DoD-14's
  census CRC (registered=11) did not cover it. Extend the CRC to count the
  file's probes into `registered_total` so an unregistered supplementary file
  cannot silently escape.

## Change

`scripts/sdk_coverage.py`, `census_crc()`:

- New `EXTRA_PROBES` constant: `("test/sdk-smoke/sb-extra.probe.cjs",
  r'record\("([\w-]+)"')`. The file registers via `record(name, err)` — the
  `record(` pattern with order-preserving dedupe (each probe has one record
  call in its success arm and one in its failure arm; only one executes, so
  distinct names = registration count = 3).
- `registered` stays the census-only count checked against the receipt claim
  (`registers N probes` = 11) and the file header claim (`— 11 probes`).
  New fields: `registered_total` = 11 + 3 = 14, `extra` =
  [(file, [scheduleMessage, receiveAndDelete-delivery,
  acceptNextSession-no-session])].
- CRC `ok` additionally requires every registered supplementary file to exist
  and register >=1 probe (missing/empty file now fails the CRC).
- `registered_total` + named extra file surfaced in the machine-summary CRC
  line, the SDK_MATRIX.md CRC section, and the CRC FAIL finding message.

## Witnessed run

```
servicebus       census CRC: registered=11 registered_total=14 +3 (test/sdk-smoke/sb-extra.probe.cjs) receipt_claim=11 header=11 -> OK
```

`python3 scripts/sdk_coverage.py` exit=1 — pre-existing findings unchanged
(cosmos/ts UNREGISTERED-GAP, 7 MISSING cells); census CRC itself OK before and
after; `docs/jira/v26.10.14/SDK_MATRIX.md` regenerated with the new line:

```
registered=11 registered_total=14(+3 from test/sdk-smoke/sb-extra.probe.cjs) receipt_claim=11 header=11 -> OK
```

Negative control (registration guard is not vacuous): the CRC now fails if the
supplementary file is missing or registers 0 probes (`any(not en ...)`).

## Also

- `docs/jira/v26.10.14/sdk-results/ts-servicebus-census.md`: appended one line
  noting the supplementary file is now CRC-covered (registered_total
  11 + 3 = 14).

## Final CRC line

`servicebus census CRC: registered=11 registered_total=14 +3
(test/sdk-smoke/sb-extra.probe.cjs) receipt_claim=11 header=11 -> OK`
