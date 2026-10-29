# BK-BMIR2 — tmp/bench mirror wave 2: live-claim census + tracked snapshots

- **Standing**: PARTIAL_ALIVE (20 live-claim anchors mirrored and committed; 25 historical-citation jsonls remain gitignored, typed pending-with-owner)
- **Context**: solo
- **Date**: 2026-10-22 · **Repo**: /Users/sac/smalt · **Lane**: BK-BMIR2
- **Closes the live-claim slice of**: BK-BMIR residue ("55 other cited tmp/bench jsonls remain gitignored — same recoverability class")

## 1. Re-census (real outputs, 2026-10-22)

Starting from BK-BMIR's 59 committed citations (11 whitepaper anchors + 2
already-mirrored), 46 uniquely-named cited jsonls remained unmirrored. Each was
classified by whether a **live-claim doc** cites it (terminal-gate class:
VALIDATION.md, FINAL.md / FINAL-RELEASE.md, KNOWN_DIVERGENCES.md rows, SCVD.md
tier ladder, DFLSS-CHARTER.md) vs only receipts/run records:

```
$ grep -rEho 'tmp/bench/[A-Za-z0-9_./-]+\.jsonl' docs/ | sort -u | wc -l
      59
$ # minus 11 whitepaper artifacts + 2 BK-BENCHREG mirrors:
$ comm -23 <(awk -F/ '{print $NF}' /tmp/bmir2_all.txt | sort -u) \
           <(ls docs/jira/v26.10.21/whitepaper/artifacts/*.jsonl docs/jira/v26.10.16/bench/*.jsonl | xargs -n1 basename | sort -u) | wc -l
      46
```

Live-claim set = **21 names** (20 snapshotted this lane + scvd-soak pending,
see below). Historical-only = **25 names** (receipt/run-record prose only).

## 2. Snapshots (cp -p, paired sha256 verified equal to tmp/bench/ source)

All 21 snapshots verified byte-identical at snapshot time (paired `shasum -a
256` run; any mismatch aborts). One-line provenance per dir:
`docs/jira/v26.10.20/bench/PROVENANCE.md`,
`docs/jira/v26.10.21/bench/PROVENANCE.md`,
`docs/jira/v26.10.22/bench/PROVENANCE.md`.

```
$ shasum -a 256 docs/jira/v26.10.2{0,1,2}/bench/*.jsonl
60d7a23d8e2e53d47cc294bac8f170b75a68c015b11becb72037a795e6ff65a9  docs/jira/v26.10.20/bench/ctq2-bshape.jsonl
8ea047c8f4687e9b9e9243b43ac61fc70fcde9320ad3465eac8c8bdb1872c501  docs/jira/v26.10.20/bench/ctq4-memory.jsonl
6fb6bfa952bfe50eecb780b3751dc71d0ee5beb0a91f77bcfeb525844ae6fe3f  docs/jira/v26.10.20/bench/scvd-airgap.jsonl
77cf80ea73fe56382229f36a7ddce4ab7b85de8f4360008b301ba1fafd8683e5  docs/jira/v26.10.20/bench/scvd-blob.jsonl
7944fc3084431adb63067b12b8ff7461a4e868e22ef754df45232c35cccd95a0  docs/jira/v26.10.20/bench/scvd-chaos-conn.jsonl
62ea4bbd5ea8c1fd9417cc50163812c562349ede697ba18f12e73a35005547e7  docs/jira/v26.10.20/bench/scvd-eh.jsonl
7b156bb5fe80c6a9d3c51dd8da82c53652756a25c86e47e98a1bd7e50a10be29  docs/jira/v26.10.20/bench/scvd-sb.jsonl
ef6ce64ae8c8a736d4af8ab3a30a7bfac266e26f502b0d046ef8029b8c3f01f0  docs/jira/v26.10.20/bench/scvd-soak2.jsonl
b352ad5109d74a99e5a3ab051f8bc9cd1be7ca82d7ef7ae52fdeb5b6d2df14ac  docs/jira/v26.10.20/bench/scvd-tail.jsonl
aa4f5b08878bfc7fdf101fc030d75ac9c96ca1c9cc5b0824e70d193a8a31bbcc  docs/jira/v26.10.20/bench/scvd-tier1.jsonl
02d9a4a20d9493c668f66b5c18984507003a09fce011a8a5c19d2ba5fa565558  docs/jira/v26.10.20/bench/scvd-tier2.jsonl
918b9bc18ec2b252452db4b3fdb4ecb86fe30b1d5fb497ab345606fd45fe11c3  docs/jira/v26.10.20/bench/scvd-tier3.jsonl
0fec66206521e6c5c3c3c796cabb4dc8b5db7fbbc252e9fe043c463bbbf0ef24  docs/jira/v26.10.20/bench/scvd-wasm-vs-host.jsonl
7bf633916507bf99fb5733f89256f6e12d7159872c0c27028e95fd38f1014c03  docs/jira/v26.10.21/bench/bk33-warm-restart.jsonl
cdd5e23d802450f41a809588c35e89e95b29abb2e80639802859884af731751e  docs/jira/v26.10.21/bench/bkcells-floor.jsonl
d8f9fe96d15bc0fa1315b142d452071aed8281e5d830274bd5a47f308fd64edc  docs/jira/v26.10.21/bench/pb2-reductions-step.jsonl
354b2fb9b537cc5d0d4f85c453b1d451985ab7ff17f430b10b0894f65c116b8b  docs/jira/v26.10.21/bench/pb3-escalated-bkcells.jsonl
13f4f9dd96d0a3a09ad0fc2abbda5e7e072f12e45742379c64dfa7cdbbe8a7b6  docs/jira/v26.10.21/bench/pb3-executor-ceiling.jsonl
9adfe8edc6165960da64ca4cb72e19a9f47904833e7ef310c9d9bf341d5193fc  docs/jira/v26.10.21/bench/pb6-dual-boundary.jsonl
3837d6a9e452acfad68bde25a2d594908bc514c666e4e36f5043b184fa087fb9  docs/jira/v26.10.21/bench/t47-release-boot.jsonl
197773b19a89ce306a4aa35099c11788aec84f476ee1d2baffa2350348126968  docs/jira/v26.10.22/bench/t35-lro.jsonl
```

### Snapshot table

| mirror | source (gitignored) | sha256 (first 12) | bytes | citing live docs |
|---|---|---|---|---|
| v26.10.20/bench/scvd-airgap.jsonl | tmp/bench/scvd-airgap.jsonl | 6fb6bfa952bf | 841 | v21 VALIDATION, v21 FINAL-RELEASE, v20 SCVD |
| v26.10.20/bench/scvd-blob.jsonl | tmp/bench/scvd-blob.jsonl | 77cf80ea73fe | 1016 | v20 SCVD, _LANES |
| v26.10.20/bench/scvd-chaos-conn.jsonl | tmp/bench/scvd-chaos-conn.jsonl | 7944fc308443 | 1545 | v20 SCVD, _LANES |
| v26.10.20/bench/scvd-eh.jsonl | tmp/bench/scvd-eh.jsonl | 62ea4bbd5ea8 | 1338 | v20 FINAL, v20 SCVD |
| v26.10.20/bench/scvd-sb.jsonl | tmp/bench/scvd-sb.jsonl | 7b156bb5fe80 | 1034 | v20 KD-155/156, v14 KD mirror |
| v26.10.20/bench/scvd-soak2.jsonl | tmp/bench/scvd-soak2.jsonl | ef6ce64ae8c8 | 1880 | v20 FINAL |
| v26.10.20/bench/scvd-tail.jsonl | tmp/bench/scvd-tail.jsonl | b352ad5109d7 | 7085 | v20 SCVD, _LANES |
| v26.10.20/bench/scvd-tier1.jsonl | tmp/bench/scvd-tier1.jsonl | aa4f5b08878b | 5660 | v20 SCVD, _LANES |
| v26.10.20/bench/scvd-tier2.jsonl | tmp/bench/scvd-tier2.jsonl | 02d9a4a20d94 | 4120 | v20 SCVD, _LANES |
| v26.10.20/bench/scvd-tier3.jsonl | tmp/bench/scvd-tier3.jsonl | 918b9bc18ec2 | 6081 | v21 VALIDATION, v20 SCVD/DFLSS-CHARTER |
| v26.10.20/bench/scvd-wasm-vs-host.jsonl | tmp/bench/scvd-wasm-vs-host.jsonl | 0fec66206521 | 1773 | v20 _LANES |
| v26.10.20/bench/ctq2-bshape.jsonl | tmp/bench/ctq2-bshape.jsonl | 60d7a23d8e2e | 1178 | v20 DFLSS-CHARTER |
| v26.10.20/bench/ctq4-memory.jsonl | tmp/bench/ctq4-memory.jsonl | 8ea047c8f468 | 4502 | v20 DFLSS-CHARTER |
| v26.10.21/bench/bk33-warm-restart.jsonl | tmp/bench/bk33-warm-restart.jsonl | 7bf633916507 | 512 | v21 VALIDATION |
| v26.10.21/bench/bkcells-floor.jsonl | tmp/bench/bkcells-floor.jsonl | cdd5e23d8024 | 304 | v21 VALIDATION |
| v26.10.21/bench/pb2-reductions-step.jsonl | tmp/bench/pb2-reductions-step.jsonl | d8f9fe96d15b | 1070 | v21 VALIDATION |
| v26.10.21/bench/pb3-escalated-bkcells.jsonl | tmp/bench/pb3-escalated-bkcells.jsonl | 354b2fb9b537 | 1087 | v21 VALIDATION |
| v26.10.21/bench/pb3-executor-ceiling.jsonl | tmp/bench/pb3-executor-ceiling.jsonl | 13f4f9dd96d0 | 2155 | v21 VALIDATION |
| v26.10.21/bench/pb6-dual-boundary.jsonl | tmp/bench/pb6-dual-boundary.jsonl | 9adfe8edc616 | 3406 | v21 VALIDATION |
| v26.10.21/bench/t47-release-boot.jsonl | tmp/bench/t47-release-boot.jsonl | 3837d6a9e452 | 2193 | v21 VALIDATION |
| v26.10.22/bench/t35-lro.jsonl | tmp/bench/t35-lro.jsonl | 197773b19a89 | 18796 | v14 KD-153 CLOSED-WITH-EVIDENCE (mirrored v20/22 KD) |

## 3. Citation re-points (minimal addenda; original evidence untouched)

Appended one italic addendum block each to 7 live-claim docs, naming the tracked
mirror paths + provenance:

- `docs/jira/v26.10.21/VALIDATION.md` (14 mirrored anchors)
- `docs/jira/v26.10.21/FINAL-RELEASE.md` (scvd-airgap)
- `docs/jira/v26.10.20/FINAL.md` (scvd-eh, scvd-soak2)
- `docs/jira/v26.10.20/SCVD.md` (11 scvd-* tier-ladder anchors)
- `docs/jira/v26.10.20/DFLSS-CHARTER.md` (ctq2-bshape, ctq4-memory, scvd-tier3)
- `docs/jira/v26.10.20/KNOWN_DIVERGENCES.md` (scvd-sb, KD-155/156)
- `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (t35-lro, KD-153)

No citation text was rewritten; original evidence lines stand as written.

## 4. Pending-with-owner (25 historical-citation jsonls, not snapshotted)

Cited only by receipts/run records (historical prose) or design-era docs
(PRD, ENGINEERING-REVIEW, BENCH-ERLANG); same recoverability class, lower
priority than terminal-gate. Verified count from disk (46 remaining − 21
mirrored = 25):

cost5-sb-measured, cost5-sb-price, court_bench_20261021223808052,
court_bench_20261021T223254.701Z, court_bench_20261021T225058.824Z, ctq2-txn,
impl21-postupgrade-sdk, ja9-scaling, pb1-fond-sweep, powl-native-face-fresh,
powl-native-face-mutant, rg404-t21-verify, scvd-arm, scvd-floor, scvd-soak
(cited by v20 DFLSS-CHARTER + FINAL — first in line for the next mirror wave,
alongside ctq2-txn), spc-watch, spc-watch2, t36-boot, t42-json, t43-p99-hunt,
t45-boot-phases, ttv6-cold-boot, ttv7-warmed-p99, ttv7-warmed-p99.load132,
wire-parity

## 5. Verification

```
$ for f in $(find docs/jira/v26.10.2{0,1,2}/bench -name '*.jsonl'); do ... paired shasum ...; done
ALL-MATCH 21 files
```

Standing is PARTIAL_ALIVE, not ALIVE: the wave closed the terminal-gate class,
but 25 historical-citation anchors remain gitignored (pending-with-owner) and
the snapshots depend on `tmp/bench/` sources that still exist only on this
machine.

## Evidence re-check (BK-SUSP5, 2026-10-22 ~09:03 PDT)

```
$ shasum -a 256 docs/jira/v26.10.2{0,1,2}/bench/*.jsonl   # 47 files now
```
All 21 receipt-recorded sha256s re-hashed from disk and confirmed present
and equal (shasum exit 0; 26 additional mirrors landed post-receipt from
other lanes — superset, no conflict).

Re-check verdict: PASS — all 21 wave-2 mirrors byte-identical to their
receipt-recorded digests as of the re-check.
