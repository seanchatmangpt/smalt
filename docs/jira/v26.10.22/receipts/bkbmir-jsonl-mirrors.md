# BK-BMIR — tmp/bench jsonl citation census + whitepaper anchor snapshots

- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22 · **Repo**: /Users/sac/smalt · **Lane**: BK-BMIR

## What was done

Closed the hazard class BK-WP2 flagged ("the 10 bench .jsonl anchors live in
`tmp/bench/` — gitignored scratch… Recommend: canonical jsonl snapshots into
`docs/jira/v26.10.21/whitepaper/artifacts/`") and executed the BK-BENCHREG
canonical-mirror pattern repo-wide. The whitepaper `.tex` itself was NOT
modified (operator artifact, one-writer rule, per BK-WP2's own lane boundary).

### 1. Census (real outputs, 2026-10-22)

Every committed citation of a `tmp/bench/*.jsonl` path was extracted from
`docs/` and checked against disk:

```
$ grep -rEho 'tmp/bench/[A-Za-z0-9_./-]+\.jsonl' docs/ | sort -u | wc -l
      59
$ # existence check of the 59 cited paths:
$ grep -c '^EXISTS' /tmp/bmir_exist.txt; grep -c '^MISSING' /tmp/bmir_exist.txt
57
2
```

- 57 cited jsonls EXIST on disk today (but are gitignored = unrecoverable on a
  fresh clone — the class hazard).
- Only 2 cited paths are MISSING on disk, and both already have tracked
  canonical mirrors plus re-pointed registry rows (done by BK-BENCHREG,
  `scripts/bench/REGISTRY.md` lines 73/85, re-verified present):

```
MISSING tmp/bench/affidavit-seal.jsonl  -> tracked docs/jira/v26.10.16/bench/affidavit-seal.jsonl
MISSING tmp/bench/c11-tf-loop.jsonl     -> tracked docs/jira/v26.10.16/bench/c11-tf-loop.jsonl
$ ls docs/jira/v26.10.16/bench/affidavit-seal.jsonl docs/jira/v26.10.16/bench/c11-tf-loop.jsonl
docs/jira/v26.10.16/bench/affidavit-seal.jsonl
docs/jira/v26.10.16/bench/c11-tf-loop.jsonl
```

No additional citation re-points were needed: the only other committed mentions
of those two names are historical prose inside receipt/audit documents
(`docs/jira/v26.10.16/FINAL.md`, `cost3-egress-quantification.md`,
`bk11-kd-legacy-triage.md`) that name `bench/affidavit-seal.jsonl` as a run
record of the time, not as a live recovery anchor.

### 2. Whitepaper anchor snapshots (the whitepaper WO)

All jsonl artifact names cited by `\art{...}` / `\texttt{...}` in
`docs/jira/v26.10.21/whitepaper/lithography.tex` were extracted (11 unique
names — BK-WP2 counted 10; the extraction below is the honest census) and
snapshotted byte-identical (`cp -p`) into
`docs/jira/v26.10.21/whitepaper/artifacts/` with sha256s recorded in
`artifacts/PROVENANCE.md`. Source = live `tmp/bench/` at snapshot time.

```
$ shasum -a 256 docs/jira/v26.10.21/whitepaper/artifacts/*.jsonl
943549e1b750d8d5f3c3039c4a0f05094abdbfdfe88d7ebe9dba41499bda39a1  c10-affidavit-seal.jsonl
ede0331faad5dd453e2540851322e735d16220a056bb34bad50c31304925f225  court_bench_amqp.jsonl
955365e2d0ac34fc93d4e76b803da40eb3f31e202b793abdff2e56881dd1743d  court_bench_ceiling.jsonl
03b058fd2f2d0d52add7c49a6de782e47f867a02c120b3bca4ad00916b80ae98  court_bench_cosmos.jsonl
9a269f121ce09f67acee7515f655a3a832415730a3adf3a8d7422f63e397e5e8  court_bench_json.jsonl
45ba7e736b8c20e1e47056838910b360b8874f27d0715b7e93e5e42dfb549d43  court_bench_powl.jsonl
585539f561bc57ffbc68fd48e80e72a6e18c0cea8e19e4f2a62c7a0ab1555a5e  gl9-governance-tax.jsonl
5333225422f48c9772cad07debd38b0e094c4b0001572426f1a2204f9bfdb57f  pb4-merkle-dual.jsonl
7a76778145a5b9af6d9d2f5e9150c62fa1c0044d28bb8b0cbda58ed81d0bc03e  pb5-crosslang.jsonl
d3add9ca0b4e136e639465219446bfcaf7062b2c0bfc1a6f723a9fe2088dc6d2  powl-native-face.jsonl
d27305bd9bdc778115f44474a7d2744ecb13bd2aff6b3d12b8ab14f975b08f15  sqld8-ingest-baseline.jsonl
```

All 11 snapshot sha256s verified equal to the `tmp/bench/` sources at snapshot
time (paired shasum run, byte-exact).

### 3. Snapshot table

| snapshot (docs/jira/v26.10.21/whitepaper/artifacts/) | source (tmp/bench/, gitignored) | sha256 (first 12) | bytes |
|---|---|---|---|
| c10-affidavit-seal.jsonl | c10-affidavit-seal.jsonl | 943549e1b750 | 358 |
| court_bench_amqp.jsonl | court_bench_amqp.jsonl | ede0331faad5 | 286 |
| court_bench_ceiling.jsonl | court_bench_ceiling.jsonl | 955365e2d0ac | 940 |
| court_bench_cosmos.jsonl | court_bench_cosmos.jsonl | 03b058fd2f2d | 614 |
| court_bench_json.jsonl | court_bench_json.jsonl | 9a269f121ce0 | 386 |
| court_bench_powl.jsonl | court_bench_powl.jsonl | 45ba7e736b8c | 418 |
| gl9-governance-tax.jsonl | gl9-governance-tax.jsonl | 585539f561bc | 783 |
| pb4-merkle-dual.jsonl | pb4-merkle-dual.jsonl | 5333225422f4 | 6214 |
| pb5-crosslang.jsonl | pb5-crosslang.jsonl | 7a76778145a5 | 519 |
| powl-native-face.jsonl | powl-native-face.jsonl | d3add9ca0b4e | 2419 |
| sqld8-ingest-baseline.jsonl | sqld8-ingest-baseline.jsonl | d27305bd9bdc | 978 |

Notes:
- `pb5-crosslang.jsonl` snapshot carries BK-WP2's finding D4 as-is: the current
  run (1,788.8 / 8,410.8 ops/s) differs from the paper figure (2,117.5 /
  11,426) — the snapshot freezes what is on disk today; the paper-side
  cite-update remains the operator's D1–D4 residue, not silently resolved here.
- `pb4-merkle-dual.jsonl` snapshot includes PB4-R's fresh 16-row re-emit
  (post-GAP-6a), i.e. the D1-superseding data, not the paper's 320 B-era rows.
- mtimes preserved (`cp -p`) — snapshot dates read as the run dates.

## Residue (typed, not done here)

- 55 other cited `tmp/bench/*.jsonl` (v26.10.20/21/22 receipts + milestone
  docs) exist today but remain gitignored — same recoverability class. Out of
  this lane's scope (whitepaper WO + missing-file law); candidates for
  per-milestone `docs/jira/<milestone>/bench/` snapshots in a follow-up lane.
- BK-WP2 D1–D4 cite-updates to the `.tex` remain operator-owned.

## Falsifier

1. A fresh clone lacking any whitepaper figure anchor after this commit
   refutes the snapshot claim (`git show HEAD:docs/jira/v26.10.21/whitepaper/artifacts/<f>.jsonl`).
2. A sha256 of any snapshot mismatching its `tmp/bench/` source at snapshot
   time refutes the byte-exact claim (paired shasum output above is the witness).
3. Any new committed citation of a `tmp/bench/*.jsonl` that is neither on disk
   nor mirrored tracks-first (BK-BENCHREG pattern) re-opens this class.

## Evidence re-check (BK-SUSP5, 2026-10-22 ~09:03 PDT)

```
$ shasum -a 256 docs/jira/v26.10.21/whitepaper/artifacts/*.jsonl
```
All 11 recorded sha256s re-hashed from disk and diffed against the table
above: HASH-MATCH 11/11, diff exit 0 (shasum exit 0).

Re-check verdict: PASS — whitepaper anchor snapshots are byte-identical to
their receipt-recorded digests as of the re-check.
