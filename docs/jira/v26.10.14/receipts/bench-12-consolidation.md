
## Replay (2026-10-19, i29 suspect-hygiene lane)
The receipt's Replay block re-run verbatim:

```
$ ls docs/jira/v26.10.14/bench/ && wc -l docs/jira/v26.10.14/bench/*.jsonl
a1-change-feed.jsonl
a2-cas-contention-sdk.jsonl
a2-cas-contention.jsonl
a3-cross-partition.jsonl
a4-crypto.jsonl
a6-port-exhaustion.jsonl
a7-hns-rename.jsonl
a8-lro-storm.jsonl
a9-auth-flood-rss.jsonl
a9-auth-flood.jsonl
b10-soak-spike.jsonl
b11-chaos.jsonl
b2-blob-ts.jsonl
b2b-blob-hdr.jsonl
b3-cosmos-ts.jsonl
b3b-cosmos-hdr.jsonl
b4-messaging-ts-run2.jsonl
b4-messaging-ts.jsonl
b5-python-mirror.jsonl
b6-lro-sdk.jsonl
b7-store-beam.jsonl
b7b-store-beam.jsonl
b8-amqp-beam.jsonl
b8b-amqp-beam.jsonl
b9-eh-beam.jsonl
b9b-eh-beam.jsonl
c1-cosmos-blob.jsonl
c2-sb-cosmos.jsonl
c4-kv-cosmos.jsonl
c5-arm-storm.jsonl
c6-sentinel-rg.jsonl
c7-cross-soak.jsonl
c8-chaos-cross.jsonl
c9-cost-model.jsonl
lifecycle-8hop.jsonl
n1-grid.jsonl
n2-action-storm.jsonl
n3-rsc-race.jsonl
n4-ingest.jsonl
n5-compute.jsonl
n6-isr.jsonl
n7-sse-herd.jsonl
n8-soak.jsonl
NEXTJS_LIFECYCLE_RESULTS.md
recon-soak.jsonl
       2 docs/jira/v26.10.14/bench/a1-change-feed.jsonl
      21 docs/jira/v26.10.14/bench/a2-cas-contention-sdk.jsonl
      65 docs/jira/v26.10.14/bench/a2-cas-contention.jsonl
      10 docs/jira/v26.10.14/bench/a3-cross-partition.jsonl
      14 docs/jira/v26.10.14/bench/a4-crypto.jsonl
       2 docs/jira/v26.10.14/bench/a6-port-exhaustion.jsonl
       1 docs/jira/v26.10.14/bench/a7-hns-rename.jsonl
       1 docs/jira/v26.10.14/bench/a8-lro-storm.jsonl
       5 docs/jira/v26.10.14/bench/a9-auth-flood-rss.jsonl
       4 docs/jira/v26.10.14/bench/a9-auth-flood.jsonl
       3 docs/jira/v26.10.14/bench/b10-soak-spike.jsonl
       3 docs/jira/v26.10.14/bench/b11-chaos.jsonl
       4 docs/jira/v26.10.14/bench/b2-blob-ts.jsonl
       1 docs/jira/v26.10.14/bench/b2b-blob-hdr.jsonl
       4 docs/jira/v26.10.14/bench/b3-cosmos-ts.jsonl
       2 docs/jira/v26.10.14/bench/b3b-cosmos-hdr.jsonl
       7 docs/jira/v26.10.14/bench/b4-messaging-ts-run2.jsonl
       6 docs/jira/v26.10.14/bench/b4-messaging-ts.jsonl
       4 docs/jira/v26.10.14/bench/b5-python-mirror.jsonl
       9 docs/jira/v26.10.14/bench/b6-lro-sdk.jsonl
      27 docs/jira/v26.10.14/bench/b7-store-beam.jsonl
       3 docs/jira/v26.10.14/bench/b7b-store-beam.jsonl
      18 docs/jira/v26.10.14/bench/b8-amqp-beam.jsonl
       5 docs/jira/v26.10.14/bench/b8b-amqp-beam.jsonl
      10 docs/jira/v26.10.14/bench/b9-eh-beam.jsonl
       5 docs/jira/v26.10.14/bench/b9b-eh-beam.jsonl
       7 docs/jira/v26.10.14/bench/c1-cosmos-blob.jsonl
      12 docs/jira/v26.10.14/bench/c2-sb-cosmos.jsonl
       9 docs/jira/v26.10.14/bench/c4-kv-cosmos.jsonl
       1 docs/jira/v26.10.14/bench/c5-arm-storm.jsonl
       5 docs/jira/v26.10.14/bench/c6-sentinel-rg.jsonl
      14 docs/jira/v26.10.14/bench/c7-cross-soak.jsonl
   47068 docs/jira/v26.10.14/bench/c8-chaos-cross.jsonl
      16 docs/jira/v26.10.14/bench/c9-cost-model.jsonl
      11 docs/jira/v26.10.14/bench/lifecycle-8hop.jsonl
      13 docs/jira/v26.10.14/bench/n1-grid.jsonl
       3 docs/jira/v26.10.14/bench/n2-action-storm.jsonl
     275 docs/jira/v26.10.14/bench/n3-rsc-race.jsonl
       3 docs/jira/v26.10.14/bench/n4-ingest.jsonl
       4 docs/jira/v26.10.14/bench/n5-compute.jsonl
       5 docs/jira/v26.10.14/bench/n6-isr.jsonl
      15 docs/jira/v26.10.14/bench/n7-sse-herd.jsonl
      15 docs/jira/v26.10.14/bench/n8-soak.jsonl
    5389 docs/jira/v26.10.14/bench/recon-soak.jsonl
   53101 total
exit code 0.
Note: the file set has grown since the receipt (B-3/B-8 rows exist now), consistent with the receipt's own fin-25 addendum. BENCH_RESULTS.md is generated (`just bench-report`); regenerate, do not hand-edit.
