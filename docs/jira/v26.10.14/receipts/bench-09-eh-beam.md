# Receipt — B-9: Event Hubs BEAM-level pipeline benchmark (v26.10.14)

- **Date**: 2026-10-15
- **Repo**: /Users/sac/smalt @ main (518b31a, working tree)
- **Lane**: B-9 — owns `scripts/bench/b9_eh_beam.exs`, `docs/jira/v26.10.14/bench/b9-eh-beam.jsonl`, this receipt
- **Subject**: `Smalt.Messaging.EventHubs` direct module calls (send_event/3, receive_events/3, next_sequence/1, reserve_processing/4) + `Smalt.Amqp.LockManager` acquire/release — ETS + named-GenServer tier, no AMQP wire framing
- **Artifacts**:
  - `scripts/bench/b9_eh_beam.exs` (mix run script, boot mirrors `scripts/bench/lib.sh` bench_boot: MIX_ENV=test, --no-start, private ports)
  - `docs/jira/v26.10.14/bench/b9-eh-beam.jsonl` (5 records, lib.sh record shape)
  - run command: `MIX_ENV=test SMALT_TEST_ARM_PORT=39860 SMALT_TEST_EGRESS_PORT=39861 SMALT_TEST_AMQP_PORT=39862 SMALT_TEST_EVENT_HUBS_PORT=39863 mix run --no-start scripts/bench/b9_eh_beam.exs`
- **Machine**: Apple M3 Max, 16 cores, 48 GB, Elixir 1.19.5 / OTP 28, macOS 15.x (darwin 25.2.0)

## Headline numbers (zero errors on all 5 ops)

| op | n | throughput | per-op |
|---|---|---|---|
| send_event/3, 1 KiB, sequential | 25,000 | **344 events/sec** | p50 2.81 ms, p95 5.74 ms, p99 6.12 ms |
| receive_events/3 drain (batch 500) | 25,000 (full set) | **217,000 events/sec** | p50 2.28 ms/batch, p95 3.12 ms, p99 6.13 ms |
| next_sequence/1 | 50,000 | 210,236 ops/s | **4.76 µs/op** |
| reserve_processing/4 (grant) | 20,000 | 126,774 ops/s | **7.89 µs/op** |
| LockManager acquire+release | 20,000 | **299,531 pairs/sec** | ~3.3 µs/pair |

## SDK→BEAM multiplier

**N/A — no SDK-tier throughput measurements exist to divide against.** B-4's
SDK lane artifacts (`docs/jira/v26.10.14/sdk-results/ts-event-hubs.md`,
`py-eventhub-eventgrid.md`) are pass/fail wire-parity probes: the TS-5 lane
concluded the real-SDK tier does NOT yet complete (3 typed gaps: missing
`message_format: 0` on EH deliveries, `$management` EH ops → 501, EH credit
not enforced), so the SDK tier never reached a throughput measurement. The
BEAM-level numbers above are the throughput baseline; the multiplier becomes
computable once the SDK tier passes its bootstrap gaps and a B-4 rerun emits
ops/sec into `docs/jira/v26.10.14/bench/`.

## Notes / caveats

- send_event per-event cost is dominated by the serialized `EHServer` GenServer
  round-trip plus table write of the full event list — send is ~630x slower
  than drain per event (2.9 ms vs 4.6 µs/event).
- Drain redelivers nothing: measured as one ascending-cursor pass over exactly
  the 25k ingested events (batch 500, `after_seq` advanced per batch).
- reserve_processing measured same-owner re-grant (always `:ok`), i.e. the
  grant-path cost without reclaim churn; errors=0.
- No lib/ edits, no commits, no other lanes' files touched. Substrate torn down
  with the mix run process exit; ports 39860-39863 were verified free pre-run
  and are released post-run.
