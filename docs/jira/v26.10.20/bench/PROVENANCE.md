# BK-BMIR2 bench mirror provenance (2026-10-22, lane BK-BMIR2)

Byte-identical snapshots (cp -p) of gitignored tmp/bench/ sources; paired sha256 verified equal at snapshot time. Canonical recovery anchors for live-claim docs (VALIDATION.md, FINAL.md, KNOWN_DIVERGENCES.md rows, SCVD.md ledger, DFLSS-CHARTER.md). Register: docs/jira/v26.10.22/receipts/bkbmir2-mirror-wave2.md

```
60d7a23d8e2e53d47cc294bac8f170b75a68c015b11becb72037a795e6ff65a9  docs/jira/v26.10.20/bench/ctq2-bshape.jsonl  1178B
8ea047c8f4687e9b9e9243b43ac61fc70fcde9320ad3465eac8c8bdb1872c501  docs/jira/v26.10.20/bench/ctq4-memory.jsonl  4502B
6fb6bfa952bfe50eecb780b3751dc71d0ee5beb0a91f77bcfeb525844ae6fe3f  docs/jira/v26.10.20/bench/scvd-airgap.jsonl  841B
77cf80ea73fe56382229f36a7ddce4ab7b85de8f4360008b301ba1fafd8683e5  docs/jira/v26.10.20/bench/scvd-blob.jsonl  1016B
7944fc3084431adb63067b12b8ff7461a4e868e22ef754df45232c35cccd95a0  docs/jira/v26.10.20/bench/scvd-chaos-conn.jsonl  1545B
62ea4bbd5ea8c1fd9417cc50163812c562349ede697ba18f12e73a35005547e7  docs/jira/v26.10.20/bench/scvd-eh.jsonl  1338B
7b156bb5fe80c6a9d3c51dd8da82c53652756a25c86e47e98a1bd7e50a10be29  docs/jira/v26.10.20/bench/scvd-sb.jsonl  1034B
ef6ce64ae8c8a736d4af8ab3a30a7bfac266e26f502b0d046ef8029b8c3f01f0  docs/jira/v26.10.20/bench/scvd-soak2.jsonl  1880B
b352ad5109d74a99e5a3ab051f8bc9cd1be7ca82d7ef7ae52fdeb5b6d2df14ac  docs/jira/v26.10.20/bench/scvd-tail.jsonl  7085B
aa4f5b08878bfc7fdf101fc030d75ac9c96ca1c9cc5b0824e70d193a8a31bbcc  docs/jira/v26.10.20/bench/scvd-tier1.jsonl  5660B
02d9a4a20d9493c668f66b5c18984507003a09fce011a8a5c19d2ba5fa565558  docs/jira/v26.10.20/bench/scvd-tier2.jsonl  4120B
918b9bc18ec2b252452db4b3fdb4ecb86fe30b1d5fb497ab345606fd45fe11c3  docs/jira/v26.10.20/bench/scvd-tier3.jsonl  6081B
0fec66206521e6c5c3c3c796cabb4dc8b5db7fbbc252e9fe043c463bbbf0ef24  docs/jira/v26.10.20/bench/scvd-wasm-vs-host.jsonl  1773B
```

## Wave 3 additions (2026-10-22, lane BK-BMIR3) — historical-citation jsonls

Byte-identical snapshots (cp -p) of gitignored tmp/bench/ sources; paired sha256 verified equal at snapshot time. These were cited by receipts/run records and design-era docs (historical class, typed pending-with-owner in BK-BMIR2). Register: docs/jira/v26.10.22/receipts/bkbmir3-mirror-wave3.md

```
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
```

## BK-BMIR4 classification (2026-10-22): b10-system-topics.jsonl is an original in-place artifact, not a tmp/bench mirror

`docs/jira/v26.10.20/bench/b10-system-topics.jsonl` is NOT a snapshot of a
gitignored `tmp/bench/` source. Its generator,
`scripts/bench/b10_system_topics.sh`, writes `RESULT_FILE` directly to this
path (line 19) — the tracked file IS the original run output. The BK-BMIR3
census "1 NO-SRC" row was a classification artifact: the file was grouped with
tmp-mirrors but has no tmp source by construction. Zero docs cite it as
numeric evidence (grep 2026-10-22: only the BMIR receipts themselves name it).
It is a crud-witness row (n=1, all-zero latency metrics), not a perf claim.
Regenerable by re-running the harness; re-measurement attempts on 2026-10-22
were typed-refused at boot (cold lane build timeout, then :eaddrinuse on 5675
held by the live shared substrate — not stopped; lane law). Original bytes
verified unchanged across all attempts:
sha256 e9f62865b51f58a58e27fde25e13d80131b6365c3e0e217fc4e5dddbcf8e46c9.
Register: docs/jira/v26.10.22/receipts/bkbmir4-b10-anchor.md
