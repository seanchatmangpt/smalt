# r217 — fin-sweep generated-artifact regen + idempotence (lane X6)

Date: 2026-10-16
Lane: X6 (fin sweep)
Subject: /Users/sac/smalt @ main, HEAD fd9cfea (pre-commit working tree)

## Command exits (pass 1, real regen)

| # | Generator | Exit | Output |
|---|---|---|---|
| 1 | `python3 scripts/receipt_index.py` | 0 | `receipts=311 sdk=49 total=360 suspects=17`; wrote RECEIPTS.md + receipts/INDEX.md for v26.10.14 and v26.10.16 |
| 2 | `python3 scripts/bench/report.py` | 0 | v26.10.14: 44 files, 103 rows; v26.10.16: 8 files, 252 rows |
| 3 | `python3 scripts/sdk_coverage.py` | 0 | v26.10.16 window: cells PASS=12, MISSING=0, UNREGISTERED-GAP=0, REGISTERED-DIVERGENCE=5, CLOSED-RECEIPT=5; `GATE: OK` |
| 4 | `python3 scripts/gen_error_codes.py --check` | 0 | `docs/ERROR_CODES.md up to date` |

Suspect count 17 is the standard output-less-receipt flag (receipt_index.py), not a gate failure.

## Idempotence evidence (rerun byte-identical)

Second full pass: all four generators exit 0 again. Third pass md5 diff against second pass
over all 8 written artifacts:

```
diff /tmp/x6/h2.txt /tmp/x6/h3.txt && echo BYTE-IDENTICAL-PASS2-VS-PASS3
BYTE-IDENTICAL-PASS2-VS-PASS3

2ca5dbe519e0214effff93e99b36e842  docs/jira/v26.10.14/RECEIPTS.md
ff1ea61a9bb7e27a0ab248cd864d1d98  docs/jira/v26.10.14/receipts/INDEX.md
1ced9702a1cc9da02755ee0afd86d238  docs/jira/v26.10.16/RECEIPTS.md
41190f3a4c071df523fdb8bf7de62503  docs/jira/v26.10.16/receipts/INDEX.md
cec215ff4ed72d690ca3653a1568e872  docs/jira/v26.10.14/BENCH_RESULTS.md
cb48f37efa56a905d0eab5f349a9589e  docs/jira/v26.10.16/BENCH_RESULTS.md
8b22b5b069dd19283b9e1235c0c93213  docs/jira/v26.10.16/SDK_MATRIX.md
aa074614ee21ac4bf1e931282dbf2220  docs/jira/v26.10.14/SDK_MATRIX.md
```

`gen_error_codes.py --check` is itself a byte-identity check — passed on both passes
(`docs/ERROR_CODES.md up to date`, exit 0 twice; md5 765d18300f52c922379855e1da3f9917 stable).

Note: two artifacts (v26.10.16 SDK_MATRIX.md, v26.10.16 receipts/INDEX.md) changed on pass 1
relative to the pre-sweep tree — that is the regen correcting drift, not non-idempotence;
from pass 1 onward every artifact is byte-stable (pass2 == pass3, exit 0 on every rerun).

## Verdict

Standing: **PASS** — all 4 generators exit 0, all reruns byte-identical.

Falsifier: any regenerated artifact differing between consecutive runs, or any generator
exit != 0.
