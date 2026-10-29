# Witness receipt: KD-120 close-condition probe (EH per-partition consumer isolation)

- **Standing: PASS** (close condition met, 3/3 runs; register NOT flipped — flip is registrar-gated via `scripts/kd_flip.py`)
- Subject: smalt @ `c72e47c3d17364b2af288f714e234cd8accf3e96` (working tree; popcorn_demo W2-7 wire client as client-side basis)
- Lane: W8-E (bench-runner, witness-only), 2026-10-20
- Substrate: live smalt EH plane on 127.0.0.1:5673; substrate pid 11444, lock FREE at the final runs; machine: `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}` (probe itself ran under the popcorn_demo toolchain pin, Elixir 1.20.3-otp-28)
- Probe: throwaway `/tmp/kd120_probe.exs` — self-contained AMQP 1.0 client over :gen_tcp, adapted from `popcorn_demo/lib/popcorn_demo/live_eh.ex` (W2-7)

## Close condition

KD-120 (registered in `docs/jira/v26.10.19/KNOWN_DIVERGENCES.md`, row minted by commit dc98f48): per-partition consumer isolation absent — a $Default subscription pinned to partition "0" received ALL hub events. Close condition: a per-partition $Default subscription receives exactly its partition's events; falsifier = the 10+10 dual-subscription probe delivers 10/10 disjoint.

## Method

- Fresh hub per run (`kd120-<epoch-ms>`), run-tagged tokens (`kd120r<epoch-ms>-p{0,1}-<i>`).
- Publish 10 distinct tokens per partition (senders at `/eventhubs/<hub>/partitions/{0,1}`), each transfer broker-`accepted`.
- Publish FIRST, then attach two concurrent per-partition receivers, each on its OWN TCP connection.
- Drain until 10 run-tokens or 4s idle timeout; classify by suffix; assert set equality + cross-set disjointness + zero duplicates.

## Verbatim console output (all 3 runs)

Run 1 (full):
```
PUB p0={10, 0} p1={10, 0}
RECV p0-link distinct=10 scanned=11 tokens=[kd120r1792549003346-p0-0 .. p0-9, all 10] dups=[]
RECV p1-link distinct=10 scanned=11 tokens=[kd120r1792549003346-p1-0 .. p1-9, all 10] dups=[]
ASSERT exactly-p0=true exactly-p1=true sets-disjoint=true
VERDICT hub=kd120-1792549003346 run=kd120r1792549003346 PASS 10/10 disjoint
```
Run 2:
```
PUB p0={10, 0} p1={10, 0}
ASSERT exactly-p0=true exactly-p1=true sets-disjoint=true
VERDICT hub=kd120-1792549015591 run=kd120r1792549015591 PASS 10/10 disjoint
```
Run 3:
```
PUB p0={10, 0} p1={10, 0}
ASSERT exactly-p0=true exactly-p1=true sets-disjoint=true
VERDICT hub=kd120-1792549016143 run=kd120r1792549016143 PASS 10/10 disjoint
```

## What was proven

1. Two concurrent per-partition receivers (own TCP connections, partitions "0"/"1") each deliver exactly the 10 tokens published to their partition — set equality, zero cross-partition tokens, zero duplicates — 3/3 runs. 10/10 disjoint.
2. Send-side partition pinning preserved (10 accepted per partition; each receiver saw only its own tokens).
3. Same-session control: `PopcornDemo.LiveEh.run()` returned `{:ok, "eh=OK(popcorn-eh/0:w27-evt-1792548963005-roundtrip-12-events-scanned)"}` on the same substrate during the window — the EH delivery path was servable throughout.

## Named gaps (what was NOT proven)

1. **Consumer-group address form not exercised.** Probe receivers used the legacy address form `/eventhubs/{hub}/partitions/{n}` (broker maps it to `$Default`, `lib/smalt/messaging/amqp/connection.ex:1191`). The real-SDK form `/eventhubs/{hub}/ConsumerGroups/$Default/Partitions/{n}` (parsed at connection.ex:2036) was never attached. "Per-partition $Default subscription" is proven via the legacy form's $Default mapping, not the SDK-native address shape.
2. **Hand-rolled client, not the official SDK.** Receivers are a raw AMQP 1.0 :gen_tcp client adapted from the W2-7 client; not `@azure/event-hubs` with its pump/checkpoint path.
3. **Cursor/epoch semantics unprobed.** Fresh hubs, cursor 0, publish-then-attach. Cursor advance and epoch contention (KD-88 face) untouched.
4. **Substrate churn during the window**: the substrate was bounced repeatedly by concurrent lanes during the probe window (pids 57559 → 82830 → 3474 → 11444; two probe attempts hit econnrefused mid-run and one partial run recorded zero deliveries before the substrate stabilized). All 3 PASS runs completed on a stable substrate, lock FREE.

## Probe-side findings (disclosure)

- **Flow-shape hazard (client-side, not a substrate defect claim)**: my first flow shape `[handle=1, delivery-count=0, credit=100, available=null, drain=false]` silently received ZERO deliveries (only attach echoes), across both attach orders, while the live_eh shape `[handle=1, delivery-count=1000, credit=1, available=1000, drain=uint(1), echo=null, props=uint(100)]` delivers immediately. The load-bearing clause was not isolated — exactly which field difference flips delivery is unprobed. Flagged as a hazard for future raw-AMQP probes; register-worthy only if it reproduces against SDK-attached receivers.
- Ordering: publish-then-attach delivers all stored events (cursor-0 read); attach-then-publish delivered nothing with my (non-delivering) flow shape, so ordering alone was not isolated as the discriminator.

## Commands

- Probe: `cd popcorn_demo && mix run /tmp/kd120_probe.exs` (toolchain 1.20.3-otp-28) — 3/3 PASS
- Control: `mix run -e 'IO.inspect(PopcornDemo.LiveEh.run())'` → OK roundtrip

**Remainder**: the register row is NOT flipped by this lane; flip is receipt-gated via `scripts/kd_flip.py --apply` (witness must postdate any shim mtime). Open residue: the consumer-group address-form gap (gap 1) and the flow-shape hazard.
