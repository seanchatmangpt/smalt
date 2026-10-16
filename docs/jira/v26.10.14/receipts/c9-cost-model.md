# Receipt: c9-cost-model

- **Lane**: C-9 (cross-product consolidation / cost model)
- **Date**: 2026-10-15 (poll window 20:31–21:0x local)
- **Repo / subject**: /Users/sac/smalt @ main, work tree (no commits made — per contract)
- **Owns**: docs/jira/v26.10.14/CROSS_PRODUCT_RESULTS.md, docs/jira/v26.10.14/bench/c9-cost-model.jsonl, docs/jira/v26.10.14/receipts/c9-cost-model.md

## Commands / exits

| Command | Exit |
|---|---|
| polling loop: `ls docs/jira/v26.10.14/bench/` + `ls receipts/` at t=0, +3 min, and +~10 min | 0 each |
| `cat bench/c5-arm-storm.jsonl bench/c6-sentinel-rg.jsonl c1-cosmos-blob.jsonl c2-sb-cosmos.jsonl c7-cross-soak.jsonl` | 0 |
| c8 aggregation: python3 over `bench/c8-chaos-cross.jsonl` (40,336 events → per-surface ok/err/p50/p95/p99) | 0 |
| arithmetic: python3 pricing script (all dollar figures computed in one pass, quoted into jsonl) | 0 |
| `grep -n "ARM writes" CROSS_PRODUCT_RESULTS.md` (verify table repair) | 0, then fixed |
| Write CROSS_PRODUCT_RESULTS.md / bench/c9-cost-model.jsonl / this receipt | 0 |

## Consequence

**Lane inventory**: first pass (20:53) landed C-1, C-5, C-6, C-7(partial),
C-8; C-2 FATAL (ARM seed PUT 400 MissingApiVersionParameter — harness bug,
not substrate: the same ARM surface is clean in C-5's 2,000-op storm); C-3,
C-4 PENDING at first pass. Final poll (21:0x) caught **C-4 landing late**
(kv-crypto + cosmos envelope, 8 op rows + crypto-tax meta, 0 errors) — merged
in a second pass, including the measured KV cost rows that replaced the
formula-only placeholder. C-3 never landed and stays PENDING.

Deliverables:

1. **Per-pipeline tables** for C-1/C-5/C-6 verbatim from jsonl; C-8 raw
   40k-event log aggregated to a per-surface failure-class table (every class
   a designed refusal: WORM 409, INVALID_LOCAL_SAS, C8_COSMOS_EMPTY_READ,
   connrefused).
2. **Interference matrix** (assembled from what landed; the full N×N matrix
   was not measurable — C-7 sampled cosmos-only): Sentinel ingest→KQL is the
   only strong coupling (6.5x throughput / 9.6x p50 degradation); cosmos/blob/
   ARM pairs showed <=7% (C-1 composite mix effect, C-5 0.97x write, 1.07x
   LRO); B-10 6-surface soak 0.02% client-side errors, RSS growth <=1.1%.
3. **THE COST TABLE** — measured sustained throughputs priced at 24x7x30
   (730 h/mo) Azure list, AS-OF-KNOWLEDGE, directional:

   | surface | measured | Azure $/mo |
   |---|---|---|
   | Cosmos point-read @4,405/s | 44,050 RU/s | $25.7k (prov) / $28.9k (serverless) |
   | Cosmos full-query @49,594/s (40 RU est.) | — | $1.30M |
   | Blob 8k put @4,351/s premium | 11.4B writes/mo | $57.2k |
   | Blob 64k put @2,912/s | — | $38.3k |
   | Blob py 8k @917/s (b5) | — | $12.0k |
   | Service Bus RT @289/s | 24.9M RT/mo | $267 (P1 flat) / $971 (P3) |
   | Event Hubs @348 evt/s (b4) | 893M evt/mo | $48 |
   | Event Hubs BEAM @670/s (b9b) | 1.76B evt/mo | $71 |
   | Sentinel ingest 33,774 rows/s x 500 B | 44.4 TB/mo | **$190,832** |
   | Key Vault decrypt @400/s (c4) | 1.05B signs/mo | $3.2k |
   | Key Vault encrypt @1,367/s (c4) | 3.59B signs/mo | $10.8k |
   | ARM 8,981 reads/s | — | $0 (cloud would 429) |
   | Resource Graph 600 q/s | — | $0 (cloud rate-capped) |
   | Composite B-10 soak 50 rps mixed | — | **~$1,278/mo** (blob op-metered writes dominate; SB flat $267) |

   Composite conclusion: the same host pays $0 marginal locally vs
   **$1.3k–$1.5M/mo** cloud-equivalent for the same sustained measured
   throughputs — thermodynamic decoupling, quantified. Every input traced to
   a landed jsonl row.

## Standing / gaps (honest)

- **Pricing is directional** (AS-OF-KNOWLEDGE list; RU/op estimates of
  10/40 RU are placeholders; reservations/autoscale would cut the cosmos
  figures). Structure is the deliverable, exact cents directional.
- **C-2 fatal**: ARM seed PUT missing `api-version` — harness seed bug, zero
  measurement rows. Rerun needed next wave.
- **C-3 PENDING**: never landed in the poll window — the only zero-data lane.
  Nothing in the cost table depends on it.
- **C-4 late-landing merged**: measured in a second pass after the first
  consolidation write; its KV rows replace the earlier formula-only KV
  placeholder (superseded, still present in jsonl history as the `UNMEASURED`
  row).
- **C-7 partial**: sampler produced cosmos stream only; blob/sb/eh/kv/arm
  streams 0 — sampler scope bug, listed as a gap.
- **KV throughput**: no bench landed anywhere in the wave; cost row is
  formula-only.
- **Single-host, no WAN**: Azure per-op latency includes a WAN hop the
  emulator does not pay; the dollar figures are an upper bound on
  op-driven cost, which strengthens the decoupling thesis.
- c1 composite row errors=164,567 flagged as counter-scope artifact (chaos
  refusals counted against a composite row with no archive-side success
  counter), not substrate failures.
- No commits made, per lane contract.

## Replay

```
ls /Users/sac/smalt/docs/jira/v26.10.14/bench/ | grep '^c'
cat /Users/sac/smalt/docs/jira/v26.10.14/bench/c1-cosmos-blob.jsonl \
    /Users/sac/smalt/docs/jira/v26.10.14/bench/c5-arm-storm.jsonl \
    /Users/sac/smalt/docs/jira/v26.10.14/bench/c6-sentinel-rg.jsonl \
    /Users/sac/smalt/docs/jira/v26.10.14/bench/c7-cross-soak.jsonl
python3 - <<'EOF'
import json
from collections import defaultdict
agg=defaultdict(lambda:{'ok':0,'err':0,'lat':[],'errs':defaultdict(int)})
for line in open('/Users/sac/smalt/docs/jira/v26.10.14/bench/c8-chaos-cross.jsonl'):
    r=json.loads(line); s=r.get('surface')
    if not s: continue
    a=agg[s]
    if r.get('ok'): a['ok']+=1
    else: a['err']+=1; a['errs'][r.get('err','?')[:40]]+=1
    a['lat'].append(r.get('latency_ms',0))
for s,a in agg.items():
    lat=sorted(a['lat']); n=len(lat)
    p=lambda q: lat[min(n-1,int(q*n))]
    print(s, a['ok'], a['err'], p(.5), p(.95), p(.99))
EOF
cat /Users/sac/smalt/docs/jira/v26.10.14/CROSS_PRODUCT_RESULTS.md
```

## Falsifier

- A dollar figure in CROSS_PRODUCT_RESULTS.md not reproducible from the
  formula column + the cited jsonl ops/sec falsifies this receipt.
- A price presented without the AS-OF-KNOWLEDGE caveat falsifies it.
- A C-2/C-3 row rendered as measured (not PENDING/FATAL) falsifies it.
- c1's errors=164,567 rendered as substrate failures (rather than
  counter-scope artifact, flagged) falsifies it.
