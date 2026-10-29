# Whitepaper artifact snapshots (provenance)

Snapshotted 2026-10-22 (lane BK-BMIR) from `tmp/bench/` — the gitignored scratch
dir cited by `docs/jira/v26.10.21/whitepaper/lithography.tex` — into this tracked
dir so every figure anchor is recoverable on a fresh clone. Source files: live
`tmp/bench/<name>.jsonl` at snapshot time; byte-identical (`cp -p`, sha256 verified
against source at snapshot). Full census + table: `docs/jira/v26.10.22/receipts/bkbmir-jsonl-mirrors.md`.
The `.tex` was NOT modified (operator artifact, one-writer rule — BK-WP2).

| snapshot | sha256 |
|---|---|
| c10-affidavit-seal.jsonl | 943549e1b750d8d5f3c3039c4a0f05094abdbfdfe88d7ebe9dba41499bda39a1 |
| court_bench_amqp.jsonl | ede0331faad5dd453e2540851322e735d16220a056bb34bad50c31304925f225 |
| court_bench_ceiling.jsonl | 955365e2d0ac34fc93d4e76b803da40eb3f31e202b793abdff2e56881dd1743d |
| court_bench_cosmos.jsonl | 03b058fd2f2d0d52add7c49a6de782e47f867a02c120b3bca4ad00916b80ae98 |
| court_bench_json.jsonl | 9a269f121ce09f67acee7515f655a3a832415730a3adf3a8d7422f63e397e5e8 |
| court_bench_powl.jsonl | 45ba7e736b8c20e1e47056838910b360b8874f27d0715b7e93e5e42dfb549d43 |
| gl9-governance-tax.jsonl | 585539f561bc57ffbc68fd48e80e72a6e18c0cea8e19e4f2a62c7a0ab1555a5e |
| pb4-merkle-dual.jsonl | 5333225422f48c9772cad07debd38b0e094c4b0001572426f1a2204f9bfdb57f |
| pb5-crosslang.jsonl | 7a76778145a5b9af6d9d2f5e9150c62fa1c0044d28bb8b0cbda58ed81d0bc03e |
| powl-native-face.jsonl | d3add9ca0b4e136e639465219446bfcaf7062b2c0bfc1a6f723a9fe2088dc6d2 |
| sqld8-ingest-baseline.jsonl | d27305bd9bdc778115f44474a7d2744ecb13bd2aff6b3d12b8ab14f975b08f15 |
