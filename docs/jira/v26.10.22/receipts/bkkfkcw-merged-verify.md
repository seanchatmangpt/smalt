# BK-KFKCW — merged kafka_exp4 census + merged-file verification

**Standing:** ALIVE
Context: solo
Date: 20261022
Owner: BK-KFKCW
Repo: /Users/sac/smalt (canonical checkout)
Subject: `test/internal/kafka_exp4_court_test.exs` as committed at f0a52ef9 (clean vs HEAD at census time)

## 1. Census: which lanes' edits are present

The file was reported dirty with stacked lane edits; at census time it is
**clean vs HEAD** — the stacked edits were absorbed by the coordinator's tick
checkpoint f0a52ef9. All three lanes' edits are present and coherent in the
committed file:

| lane | edit | where |
|---|---|---|
| BK-KFKC (F3/F4 court) | F3 count-mismatch falsifier + non-vacuity + builder legs; F4 partition-bounds + wire legs | :26-140 |
| BK-KFKC / KFKC2 legacy face | `@kfkc_part` (top partition, kept off shared partition 0), 3 legacy magic-0/1 legs | :19-22, :142-186 |
| BK-B7CR consume-scope fix | per-run unique prefix (`Base.encode16(strong_rand_bytes(6))`), `--filter-prefix` threading, 240s test timeout above the 4×20s retry budget | :188-242 |

Supporting substrate: `tmp/bkkfkc_probe.py` supports `--filter-prefix`
(:39/:55/:70/:74). No `bkb7cr-consume-scope.md` receipt exists — **BK-B7CR is
in-flight** (edits landed via tick checkpoint, receipt not yet filed).

## 2. Merged-file verification — 3 fresh runs, varied seeds

```
$ export PATH="$HOME/.asdf/shims:$PATH"
$ for seed in 100 200 300; do MIX_BUILD_ROOT=_build-bkkfkcw \
    mix test test/internal/kafka_exp4_court_test.exs --seed $seed; done

== seed 100 ==  Result: 10 passed  (21.3s)  EXIT=0
== seed 200 ==  Result: 10 passed  (21.1s)  EXIT=0
== seed 300 ==  Result: 10 passed  (21.3s)  EXIT=0
```

Substrate UP (pid 81426, lock FREE). Build root `_build-bkkfkcw` (lane lease,
mine to reclaim).

This directly re-fences the BK-WIT3R item 5 defect face: the failure
reproduced across seeds 100/200/300 at 9/10 before the B7CR fix; the merged
file is 10/10 on the same seed set. The BK-KFKC2 corruption class and the
KIP-183 error-44 face stay green (consistent with BK-WIT3R items 1-2).

## 3. BK-B7CR receipt check

`docs/jira/v26.10.22/receipts/bkb7cr-consume-scope.md` does not exist —
in-flight. Its 5/5 falsifier claim therefore cannot be receipt-verified;
instead this lane verified the same surface independently: **3/3 fresh green
runs on the merged file with the B7CR fix present** (above). When B7CR files
its receipt it can cite this as independent corroboration.

## 4. Typing

Merged-file verification: **ALIVE** — the merged file is coherent (no
conflicting edits, probe/harness parity holds) and green 3/3 across seeds.

Lane lease cleanup: `_build-bkkfkcw` deleted at integration.

## Falsifier

Re-run `MIX_BUILD_ROOT=<fresh> mix test test/internal/kafka_exp4_court_test.exs
--seed {100,200,300}` — any non-10/10 result re-opens this verdict.
