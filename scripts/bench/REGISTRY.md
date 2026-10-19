# Bench Lane Registry — v26.10.14

Shared infra owned by lane B-1 (`scripts/bench/lib.sh`, `justfile.d/15-bench.just`,
`scripts/bench/report.py`, this file). Every active lane B-2..B-9 (plus
sub-lanes b2b/b3b):

```bash
source "$REPO_ROOT/scripts/bench/lib.sh"  # REPO_ROOT = checkout root
pid=$(bench_boot b3)          # private port block, MIX_ENV=test, anonymous auth
# ... run ops, collect latencies (ms) ...
read p50 p95 p99 <<<"$(latencies | bench_percentile)"
BENCH_LANE=b3 bench_emit "$(bench_result_file b3)" <surface> <op> <n> <ops_per_sec> $p50 $p95 $p99 <errors>
bench_down "$pid"
```

Port law: lane `bN` -> ports `39000+10N` .. `39000+10N+5`
(ARM, egress/data, AMQP, event_hubs, arm_tls, mcp). Pre-flight collision check in
`bench_boot` refuses to boot on a held port.

Result files: one `.jsonl` per lane in `docs/jira/v26.10.14/bench/`. Row schema:
`{lane, surface, op, n, ops_per_sec, p50_ms, p95_ms, p99_ms, errors, machine}`.

| lane | result file | scope (assigned by coordinator) |
|---|---|---|
| b1 | b1.jsonl | core harness (this dir, lib.sh, report.py, 15-bench.just, BENCH_RESULTS.md) |
| b2 | b2-blob-ts.jsonl | blob SDK (TypeScript) |
| b3 | b3-cosmos-ts.jsonl | Cosmos SDK (TypeScript) |
| b4 | b4-messaging-ts.jsonl | Service Bus + Event Hubs SDK (TypeScript) |
| b5 | b5-python-mirror.jsonl | blob SDK (Python) (`b5_python_mirror.py`) |
| b6 | b6-lro-sdk.jsonl | LRO / SDK latency (`b6_lro_sdk.py`) |
| b7 | b7-store-beam.jsonl | in-BEAM native store ops (`b7_store_beam.exs`) |
| b8 | b8-amqp-beam.jsonl | Service Bus, BEAM-native AMQP (`b8_amqp_beam.exs`) |
| b9 | b9-eh-beam.jsonl | Event Hubs, BEAM-native AMQP (`b9_eh_beam.exs`) |
| e1 | e1-enclave-loop.jsonl | terraform enclave loop: provision -> data plane -> console -> residue (`scripts/tf_enclave_loop.sh`, 2026-10-16) |

Disjointness: lanes write ONLY their own result file and must not edit
`scripts/bench/`, `justfile.d/15-bench.just`, `Justfile`, or this file.

## Non-b lane port allocations (audited 2026-10-15, lane R3)

`bench_lane_ports` enforces the b-law only for `b1..b12` (39010..39125). Other
lane families must stay disjoint from that band:

- **c-law**: `cN -> 39200 + 10N .. +5` (c1 39210..39215, c2 39220..39225,
  c4 39240..39245, c6 39260..39265, c7 39270..39275, c8 39280..39285).
  c7's KV leg uses the port-keyed dev cert `tmp/dev-certs/dev-cert-<atls>.pem`
  (`lib/smalt/tls.ex`), so the cert path follows the arm_tls port.
  c9 (enclave loop, `scripts/bench/enclave_loop.exs`): 39290..39294
  (arm/egress/amqp/ehub/arm_tls; 39295 spare). Defaults in the harness are the
  c9 block — any row embedding the global substrate ports (9443/8443/5672/5673)
  is VOID. Identity note: `v26.10.14/bench/c9-cost-model.jsonl` is a RETIRED
  identity (a different, retired c9); the live c9 is the v26.10.16 enclave
  loop (`c9-enclave-loop.jsonl`).
- **Legacy self-booted blocks (pre-lib.sh, disjoint, do not move)**:
  b6 39840..39843, c3 39680..39684, c5 39850..39853,
  lifecycle_harness 39640..39650, a9 39490.
- **e-law (enclave loops, 2026-10-16)**: `eN -> 39370 + 10N .. +5`
  (e1 39370..39375). `e` is a new family, not `a/b/c/n`: the enclave loop is
  a full provision -> data-plane -> console -> residue lifecycle over a
  terraform-managed ephemeral environment, not an adversarial probe (a), SDK
  surface probe (b), cross/chaos soak (c), or Next.js lifecycle (n). The
  wrapper `scripts/tf_enclave_loop.sh` owns block 39370..39375; the lane
  writes only its own result file `e1-enclave-loop.jsonl`.
- **flood_autocannon** is a load harness, never emits bench jsonl; defaults
  39460/39464 (free band), env-overridable.
- **n5** boots its own `next start` on 39555 (b-band 39010..39125 reserved).
- **Retired b10/b11**: result files `b10-soak-spike.jsonl` / `b11-chaos.jsonl`
  exist on disk from lanes with no script in `scripts/bench/` — historical
  artifacts only, no active lane. No b12 lane ever existed.
- Dual-instrument sub-lanes b2b/b3b share their parent lane's block
  (b2 39020..39025, b3 39030..39035) by design and write their own result
  files (b2b-blob-hdr.jsonl, b3b-cosmos-hdr.jsonl).
- c10 affidavit seal bench (scripts/bench/c10_affidavit_seal.exs) — admit_and_seal latency, in-BEAM Wasmex engine; ports 39250..39255; result affidavit-seal.jsonl (tmp/bench/; mirrored to docs/jira/v26.10.16/bench/affidavit-seal.jsonl — canonical name, no c10- prefix).
- b42 dataplane saturation lane (`docs/jira/v26.10.16/bench/b42-dataplane-saturation.jsonl`)
  — ports UNAUDITED: no port block registered for it in this file; register or
  retire before its next run.
- lc1 lifecycle-8hop (result files `lifecycle-8hop.jsonl` in v26.10.14 and
  v26.10.16 bench dirs) — cross-ref legacy block 39640..39650 (same block as
  `lifecycle_harness`, pre-lib.sh, do not move).
- a-family / n-family (a1-a9, n1-n8 in `docs/jira/v26.10.14/bench/`):
  register-or-retire — no port blocks for these lanes are registered in this
  file beyond a9 39490 (a-family) and n5 39555 (n-family). Any re-activated
  a/n lane must register its block here or be retired; result files without an
  active registered lane are historical artifacts (same rule as b10/b11).
- c11 terraform lifecycle lane (scripts/bench/c11_tf_loop.sh) — tf init/plan/apply -> read-your-write (blob/secret/cosmos) -> destroy against a lane-private substrate; ports 39310..39315; result c11-tf-loop.jsonl (tmp/bench/; mirrored to docs/jira/v26.10.16/bench/c11-tf-loop.jsonl).

## Container burn lanes (v26.10.18, lane B-1 burn section)

Container burn lanes — `boot-burn`, `chaos-kill`, `soak`, `matrix` — run in
per-container network namespaces, so the host port law (lane `bN` ->
`39000+10N..+5` and friends, above) is superseded inside containers: port
collisions across burn lanes are impossible by namespace isolation, not by the
host `bench_boot` pre-flight check. Receipts land as JSONL with the
`smalt-burn/v2` row schema under `docs/jira/v26.10.18/burn/` (NOT the
`docs/jira/v*/bench/` dir host lanes use). Host lanes and container lanes never
share a result directory; do not point a container lane at `bench/`, and do not
point a host lane at `burn/`.

## v-law (v26.10.19 bench re-registry, staleness-repair lane)

Drafted in the v26.10.19 plan; landed here because REGISTRY.md is the bench
registry of record.

- **v-law port bands**: lane `vN` -> `39700 + 10N .. +5` (v1 39710..39715,
  v2 39720..39725, ... verification-surface lanes); spare block
  `39826..39839` reserved for ad hoc probes; the substrate spawn lock is the
  `flock -x 9` fd-9 namespace on `/tmp/smalt-substrate.lock` (spawn with the
  lock fd CLOSED: `9>&-`, fan-out law 4).
- **LIVE-vs-ORPHAN**: a substrate holder is LIVE only when its whole
  flock->mix->beam tree owns a LISTEN socket; a tree with no LISTEN socket is
  an ORPHAN and may be swept (`scripts/port_sweep.sh -y`). Private-port lanes
  are LIVE, not orphans.
- **Retire markings (v26.10.19 reset, 64f6099)**: the a-family (a1-a9),
  n-family (n1-n8) and b42 lanes are RETIRED — their subjects (test/sdk-full
  SDK corpora, workspace lifecycle surfaces they drove) were deleted or their
  result files have no active registered lane. Result files in
  docs/jira/v*/bench/ are historical artifacts. No v-lane may revive an a/n
  subject without re-registering here with a port block + successor receipt.
- **Collision-storm falsifier**: the v-law's disjointness is falsifiable —
  run all v-lanes concurrently; the run is VOID if any two lanes share a port
  or any lane's `bench_boot` pre-flight fails spuriously (witness: hold port
  39711 and boot v1 -> `bench_boot` must REFUSE with the held-port row; a
  boot that succeeds over a held port = registry is vacuous).
- SDK-dependent host lanes b2/b2b/b3/b3b/b4/b5/b6 are DORMANT pending
  V261019-08/09: their SDK resolution paths (test/sdk-full/node_modules,
  test/sdk-python) were deleted at 64f6099 and verification/ts+py are not
  landed. They have no scripts on disk until repointed to verification/ —
  running one before the repoint fails loudly at SDK import, which is the
  honest verdict; do not fake a SKIP.
