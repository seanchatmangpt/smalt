# BK-JAR lane receipt — JA court repairs + UNWITNESSED receipt standing-line repair

- **Standing:** ALIVE (ja15 court 10/10 PASS exit 0; both target receipts resolve ALIVE via `extract_standing`; no compile-abort in test/internal/)
- **Context:** solo
- **Date:** 2026-10-22
- **Lane:** BK-JAR, repo /Users/sac/smalt, MIX_BUILD_ROOT=_build-bkjar

## 1. JA court repair (test/internal/ja15_error_logger_court_test.exs)

The syntax error witnessed at line 235 in the bk85 receipt is NOT present at HEAD:
the file compiles and the court passes on the current tree.

```
$ MIX_BUILD_ROOT=_build-bkjar mix test test/internal/ja15_error_logger_court_test.exs
Running ExUnit with seed: 523680, max_cases: 32
Finished in 0.3 seconds (0.00s async, 0.3s sync)
Result: 10 passed
[exited with code 0]
```

No premise or assertion was touched — no edit to the file was needed. One
advisory compile warning remains (pre-existing): line 133 references
`SmaltTest.Internal.Poll.eventually/1`, resolved at runtime (test passes);
module absent at compile time.

## 2. Compile-abort census sweep

Per the census law (compile-abort exit 1 / 0 tests executed ≠ real failures):

```
$ MIX_BUILD_ROOT=_build-bkjar mix test test/internal/
Result: 287/356 passed, Failed: 69 tests
exit 2; zero "** (CompileError)" / "** (" compile-abort markers in output
```

- test/internal/: 69 real test failures, 0 compile-aborts. Failures are
  pre-existing / other lanes' territory (not triaged here — lane scope is
  compile-aborts + the ja15 court, which is green).
- test/integration/: COMPILE-ABORT in `lib/smalt/messaging/kafka/conn.ex:460`
  (`Smalt.Messaging.Kafka.Conn.route_fetch/5`) — an in-flight edit owned by the
  KAFKA-EXP4 lane (per the 2255586a checkpoint). Not my file; not fixed here.
  Compile-freeze SLA applies to its owner.

## 3. UNWITNESSED receipt standing-line repair

`receipt_index.py` `EXPLICIT_STANDING` requires `standing:` with the colon
adjacent (`\**\s*standing\s*:\**`). Both target receipts carried evidence and
ALIVE prose but in formats the regex rejects:

- `bk126-spof4-reconcile.md`: had `## Standing` header + bold ALIVE prose, no
  explicit line → added `**Standing:** ALIVE (spof4-court 19/19 PASS, exit 0)`
  (restates the receipt's own embedded court transcript; nothing fabricated).
- `erl4r-vc-twins-lakehouse.md`: had `**Standing**:` (asterisks between word
  and colon, regex-invisible) → normalized to `**Standing:**` (same evidence).

Verified via the tool itself:

```
$ python3 -c "from receipt_index import extract_standing; ..."
bk126-spof4-reconcile.md ('ALIVE', '**Standing:** ALIVE (spof4-court 19/19 PASS, exit 0) — ...')
erl4r-vc-twins-lakehouse.md ('ALIVE', '- **Standing:** ALIVE (court 8/8 PASS, exit 0)')
```

Both receipts also satisfy `has_evidence` (`exit 0` transcript) → non-SUSPECT.

## Dispatch notes

- `_LANES.md` rows BK-126 / ERL-4r still read "UNWITNESSED (no standing line)";
  _LANES.md is not in this lane's commit scope — coordinator should flip both
  rows to ALIVE on integration (receipts now carry explicit standing lines).
- test/integration/ compile-abort (kafka/conn.ex) dispatched to KAFKA-EXP4 owner.
- ja15 "syntax error at :235" premise was stale: the defect is absent at HEAD.

## Replay

```
MIX_BUILD_ROOT=_build-bkjar mix test test/internal/ja15_error_logger_court_test.exs   # 10 passed
python3 scripts/receipt_index.py | grep -iE "spof4-reconcile|vc-twins"                # no SUSPECT rows
```
