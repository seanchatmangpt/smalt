# BK-BMIR3 — tmp/bench mirror wave 3: historical-citation residue closed

- **Standing**: ALIVE (all 25 historical-citation jsonls existed in tmp/bench, snapshotted byte-identical, paired sha256 verified; final census 0 untracked of 59)
- **Context**: solo
- **Date**: 2026-10-22 · **Repo**: /Users/sac/smalt · **Lane**: BK-BMIR3
- **Closes the pending-with-owner slice of**: BK-BMIR2 (docs/jira/v26.10.22/receipts/bkbmir2-mirror-wave2.md §4)

## 1. Existence check (all 25 EXIST)

```
$ for n in <25 names>; do [ -f tmp/bench/$n.jsonl ] && echo "EXISTS $n" || echo "GONE $n"; done
EXISTS cost5-sb-measured
EXISTS cost5-sb-price
EXISTS court_bench_20261021223808052
EXISTS court_bench_20261021T223254.701Z
EXISTS court_bench_20261021T225058.824Z
EXISTS ctq2-txn
EXISTS impl21-postupgrade-sdk
EXISTS ja9-scaling
EXISTS pb1-fond-sweep
EXISTS powl-native-face-fresh
EXISTS powl-native-face-mutant
EXISTS rg404-t21-verify
EXISTS scvd-arm
EXISTS scvd-floor
EXISTS scvd-soak
EXISTS spc-watch
EXISTS spc-watch2
EXISTS t36-boot
EXISTS t42-json
EXISTS t43-p99-hunt
EXISTS t45-boot-phases
EXISTS ttv6-cold-boot
EXISTS ttv7-warmed-p99
EXISTS ttv7-warmed-p99.load132
EXISTS wire-parity
```

Zero GONE → zero unrecoverable-historical types needed.

## 2. Snapshots (cp -p, paired sha256 verified equal to tmp/bench/ source)

12 into `docs/jira/v26.10.20/bench/`, 15 into `docs/jira/v26.10.21/bench/`
(primary citing milestone; secondary citations in v26.10.22 receipts point at
the same mirrors). Wave-3 blocks appended to both dirs' PROVENANCE.md.

```
$ shasum -a 256 docs/jira/v26.10.2{0,1}/bench/*.jsonl   # wave-3 rows below; full run: 45 MATCH, 1 NO-SRC (pre-existing b10-system-topics.jsonl, source already gone from tmp/bench, not this lane's)
c4a85b52ff1edebda5f173e7b7b18b21de846a9fb00a7fe36bff01c49f5acff1  docs/jira/v26.10.20/bench/cost5-sb-measured.jsonl
c6ce3a560ab5a0c1f736d6d6344506593ba4ee2f8e943448674aa327c2fb3d2e  docs/jira/v26.10.20/bench/cost5-sb-price.jsonl
acafa9af35b4ae6f4a1dd1aeb4dfec5a62c679a2732f342662f09441a7a6244b  docs/jira/v26.10.20/bench/ctq2-txn.jsonl
cdb9da3cf2ff808144bbc579735252335c2686279bca4cc06f5d55296b852979  docs/jira/v26.10.20/bench/rg404-t21-verify.jsonl
1fa7abd39144290b616886799a99bfb8453cfc9dbdf6795e465c4aac87b0162c  docs/jira/v26.10.20/bench/scvd-arm.jsonl
f314d1636bc498abfe0d0bb694cf872db8b7bca6e750fce95cea68065d5c7e40  docs/jira/v26.10.20/bench/scvd-floor.jsonl
18b119e8788b571ff4772d80fa5c0c62e1055856f2a96a5c36708003844c6d1a  docs/jira/v26.10.20/bench/scvd-soak.jsonl
f81defbb090c59af7741486ce029f241071e76013799a5088d8a93e49ea56bae  docs/jira/v26.10.20/bench/spc-watch.jsonl
a332a5c56dd1436fe427dd0c8abaf794e626859a4ba3a1f4a76609d2595c9b1e  docs/jira/v26.10.20/bench/spc-watch2.jsonl
5484df196528a42a350844207aa6f4d457779b345a2f7f930f9d1da0cc7f5d19  docs/jira/v26.10.20/bench/wire-parity.jsonl
4f25547a71283c6e07ff593ebce7735bb8aa80643cedab5770504c662650c521  docs/jira/v26.10.21/bench/court_bench_20261021223808052.jsonl
d850fd231116f334fa3b590bfef8755f1bb1c6d1b6922c2b23b18a268b1fcc18  docs/jira/v26.10.21/bench/court_bench_20261021T223254.701Z.jsonl
03340d394a75c8c196a671e70ed9a162407a6b19e6f4de6435e0409b53e424e4  docs/jira/v26.10.21/bench/court_bench_20261021T225058.824Z.jsonl
65fd2b053f54822a37a1306933ebcce97fd1f604d255d7f12a8dfd129380f477  docs/jira/v26.10.21/bench/impl21-postupgrade-sdk.jsonl
49ac9ab104dff45d8041e5000eb7fe2263ad50d48f607dc4d48956f3a34d633a  docs/jira/v26.10.21/bench/ja9-scaling.jsonl
5790994497c288a5194cc5fbf6e593130005dddd9b62fe12fe87a55d843f92fe  docs/jira/v26.10.21/bench/pb1-fond-sweep.jsonl
0942bf6d75ec7fb32aefb836c515a8055f1b02db8f3be2ccff11972fd3b8cf29  docs/jira/v26.10.21/bench/powl-native-face-fresh.jsonl
7c95608c53581f07c411934dbc20c2dc096d8fef1366ff998bf0d9c782b1f14a  docs/jira/v26.10.21/bench/powl-native-face-mutant.jsonl
805659988258662ca6139988ae3939aac286605611df32e9dbaafee6f3e02f59  docs/jira/v26.10.21/bench/t36-boot.jsonl
a67cd56dbd852f86c4112af0a6dd5094fca3fc90284ba1c2180305b45284d23f  docs/jira/v26.10.21/bench/t42-json.jsonl
235881130842ef92ff0d6e96076916e8d3af5c70776ca42f71157e1098af1b41  docs/jira/v26.10.21/bench/t43-p99-hunt.jsonl
49c412fb0ed158aac64d121bab5498f6c5b8266d8f57d08fe8d49819e7111099  docs/jira/v26.10.21/bench/t45-boot-phases.jsonl
53e42a26defd41cdfd8b0f0e49169098f70a0b432a5854b4de19bb36d72c83f0  docs/jira/v26.10.21/bench/ttv6-cold-boot.jsonl
3f03746cbc94cfcc754bf3d65fe52562ea06f7f3ad55136044a47e04261c6cfb  docs/jira/v26.10.21/bench/ttv7-warmed-p99.jsonl
2d025693a4ec71be85c5e466f731d8124f86129a436790592c2f8cc4e057ca95  docs/jira/v26.10.21/bench/ttv7-warmed-p99.load132.jsonl
```

## 3. Snapshot table (mirror → source → citing docs)

| mirror | source (gitignored) | citing docs |
|---|---|---|
| v26.10.20/bench/cost5-sb-measured.jsonl | tmp/bench/cost5-sb-measured.jsonl | v20 receipts/cost4-migration-displacement |
| v26.10.20/bench/cost5-sb-price.jsonl | tmp/bench/cost5-sb-price.jsonl | v20 receipts/cost4-migration-displacement |
| v26.10.20/bench/ctq2-txn.jsonl | tmp/bench/ctq2-txn.jsonl | v20 DFLSS-CHARTER (live-claim), v22 receipts/bksubtls-repair |
| v26.10.20/bench/rg404-t21-verify.jsonl | tmp/bench/rg404-t21-verify.jsonl | v20 receipts/rg404-t21-404-root-cause |
| v26.10.20/bench/scvd-arm.jsonl | tmp/bench/scvd-arm.jsonl | v20 receipts/scvd-t21-arm-ramp, v21 receipts (KD-157 witnesses) |
| v26.10.20/bench/scvd-floor.jsonl | tmp/bench/scvd-floor.jsonl | v20 receipts/scvd-t23-serial-floor-profile |
| v26.10.20/bench/scvd-soak.jsonl | tmp/bench/scvd-soak.jsonl | v20 DFLSS-CHARTER (live-claim, BK-BMIR2 "first in line") |
| v26.10.20/bench/spc-watch.jsonl | tmp/bench/spc-watch.jsonl | v20 receipts/spc-drift-watch |
| v26.10.20/bench/spc-watch2.jsonl | tmp/bench/spc-watch2.jsonl | v20 receipts/spc-drift-watch, v21 receipts/bk40-skip-audit, v22 receipts/bkskiptype-inventory |
| v26.10.20/bench/wire-parity.jsonl | tmp/bench/wire-parity.jsonl | v20 receipts/wire-parity-matrix, v21 receipts/val-prd |
| v26.10.21/bench/court_bench_20261021223808052.jsonl | tmp/bench/court_bench_20261021223808052.jsonl | v21 receipts/bench11-court-receipt-schema |
| v26.10.21/bench/court_bench_20261021T223254.701Z.jsonl | tmp/bench/court_bench_20261021T223254.701Z.jsonl | v21 BENCH-ERLANG |
| v26.10.21/bench/court_bench_20261021T225058.824Z.jsonl | tmp/bench/court_bench_20261021T225058.824Z.jsonl | v21 receipts/bench8-court-bench-escript |
| v26.10.21/bench/impl21-postupgrade-sdk.jsonl | tmp/bench/impl21-postupgrade-sdk.jsonl | v21 PRD, v21 receipts/impl21-postupgrade-sdk, v22 receipts/bkard21b-drift-fixes |
| v26.10.21/bench/ja9-scaling.jsonl | tmp/bench/ja9-scaling.jsonl | v21 receipts/ja9-scaling-envelope, receipts/bk60-receipt-index-gate |
| v26.10.21/bench/pb1-fond-sweep.jsonl | tmp/bench/pb1-fond-sweep.jsonl | v21 receipts/pb1-fond-loop-latency, v22 receipts (bk5-powlbench, kdim-ifmatch-row, pb1sdkfix-rerun) |
| v26.10.21/bench/powl-native-face-fresh.jsonl | tmp/bench/powl-native-face-fresh.jsonl | v21 receipts/powlbench-fresh-rerun |
| v26.10.21/bench/powl-native-face-mutant.jsonl | tmp/bench/powl-native-face-mutant.jsonl | v21 receipts/powlbench-fresh-rerun |
| v26.10.21/bench/t36-boot.jsonl | tmp/bench/t36-boot.jsonl | v21 receipts/val-nfr-migrate |
| v26.10.21/bench/t42-json.jsonl | tmp/bench/t42-json.jsonl | v21 ENGINEERING-REVIEW |
| v26.10.21/bench/t43-p99-hunt.jsonl | tmp/bench/t43-p99-hunt.jsonl | v21 PRD, v22 receipts/bkard21b-drift-fixes |
| v26.10.21/bench/t45-boot-phases.jsonl | tmp/bench/t45-boot-phases.jsonl | v21 receipts/t45-boot-phase-profile |
| v26.10.21/bench/ttv6-cold-boot.jsonl | tmp/bench/ttv6-cold-boot.jsonl | v21 receipts/ttv6-cold-boot-gate |
| v26.10.21/bench/ttv7-warmed-p99.jsonl | tmp/bench/ttv7-warmed-p99.jsonl | v21 BENCH-ERLANG, receipts (gl9-governance-tax, ttv7-warmed-p99-standard, ttv7b-quiesced-rerun) |
| v26.10.21/bench/ttv7-warmed-p99.load132.jsonl | tmp/bench/ttv7-warmed-p99.load132.jsonl | v21 receipts/ttv7b-quiesced-rerun |

## 4. Citation re-points (minimal addenda; original evidence untouched)

Appended one italic addendum block each to the 4 non-receipt citing docs
(BK-BMIR2 precedent: receipts stay as written, their anchor role unchanged;
mirrors are reachable through PROVENANCE.md and this register):

- `docs/jira/v26.10.20/DFLSS-CHARTER.md` (ctq2-txn, scvd-soak — the BK-BMIR2 "first in line" pair)
- `docs/jira/v26.10.21/PRD.md` (impl21-postupgrade-sdk, t43-p99-hunt)
- `docs/jira/v26.10.21/ENGINEERING-REVIEW.md` (t42-json)
- `docs/jira/v26.10.21/BENCH-ERLANG.md` (court_bench_20261021T223254.701Z, ttv7-warmed-p99)

## 5. Final census — zero cited-tmp-jsonl paths untracked

```
$ for p in $(grep -rEho 'tmp/bench/[A-Za-z0-9_./-]+\.jsonl' docs/ | sort -u); do
    b=$(basename $p)
    ls docs/jira/*/bench/$b docs/jira/v26.10.16/bench/$b docs/jira/v26.10.21/whitepaper/artifacts/$b >/dev/null 2>&1 || echo "UNTRACKED $p"
  done
untracked=0 of 59
```

Every one of the 59 uniquely-cited tmp/bench jsonl names now resolves to a
tracked byte-identical mirror (or was already a tracked whitepaper/BENCHREG
artifact). BK-BMIR residue fully closed.

Standing ALIVE: all 25 sources existed on this machine at snapshot time, all
25 paired sha256 verified equal, census exits clean. Note: the mirrors remain
byte-identical only as of snapshot; tmp/bench/ sources stay gitignored and
machine-local (expected — that is what the mirrors now protect against).
