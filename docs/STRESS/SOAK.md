# SOAK Stress Receipt

Harness: `scripts/stress/soak.py` (stdlib-only; boots its own substrate via
the SMALT_TEST_* env contract on private ports, kills it in a cleanup trap).
Receipt file: `/tmp/soak-results.json`.

## Load Model

Steady 50 rps for 25 minutes (~75,000 requests), 16 workers, scheduled send
times (token-bucket pacing), per-worker zero-based C/R/U/D cycles so every
read follows its create:

- ARM (60%): PUT then GET per pair on 8 resource groups
  (`soak-rg-0..7`), 9443, anonymous auth (test env), PUT accepts 200 (update)
  or 201 (create).
- Cosmos (25%): doc C/R/U/D per 4-op cycle on `soakdb/soakcoll` (pk `/pk`),
  egress 8443-class port, x-ms-documentdb-partitionkey header carried on all
  four ops (pk value must equal header value or create_doc 400s).
- Blob (10%): PUT/GET/DELETE per 3-op cycle on mutable container
  `soakacct/soak-cont` (x-ms-version required; egress default is immutable
  WORM — create the container with `x-ms-immutable-policy: false`).
- Sentinel (5%): DCR-stream ingest POST
  `/dataCollectionRules/soak-dcr/streams/Custom-soak?api-version=2023-01-01`
  (bounded append: ~3.7k rows over the run).

Sampling every 60s: substrate beam RSS via `ps`, ETS table sizes via a
`mix run --no-start -e` distribution introspection snippet
(Node.connect + :rpc.call(:ets.info/2) per Smalt.Store table), error counts.

## Failure Conditions (any -> FAIL)

1. Any 5xx (or unexpected status vs the per-op expected status).
2. RSS grows monotonically >20% after minute 5.
3. Error rate > 0 (bad statuses + connection errors).

## Environment Caveats (hit live, 2026-10-14)

- `Smalt.Amqp.Sweeper` crashes the app at boot when `CbsRouter` is not yet
  started (CbsRouter starts lazily on first AMQP connection):
  `GenServer.call(Smalt.Amqp.CbsRouter, :gc, 5000)` — soak boots with
  `mix run --no-start -e` + `Application.put_env(:smalt, :amqp_sweeper_tick_ms, 600_000_000)`
  (deferred-start pattern) to move the first sweep tick past the soak window.
  Real fix belongs to the amqp lane (catch/log in `Sweeper.run_pass/0`).
- Another lane's substrate was holding 19443/18443 — soak uses 29443/29444/
  28443/25672/25673 via the SMALT_TEST_* overrides.
- Shared-tree churn: boot broke twice on other lanes' transient broken edits
  (`egress_router.ex` syntax error, `ledger_entry.ex` Ash DSL error); soak
  retries boot up to 3 times (poll until /subscriptions 200).

## Receipt

Run 2026-10-14 22:16-22:41 local, 1500s at 50 rps, ports
29443 (ARM) / 28443 (egress) / 29444 (TLS) / 25672/25673 (AMQP/EH),
beam pid 50296. 75,000 requests, achieved 50.00 rps, error rate 0.

Mix: arm 45045 / cosmos 18667 / blob 7446 / sentinel 3842.

| min | RSS KB | ETS total | reqs | bad |
|---|---|---|---|---|
| 1.00 | 219136 | 167 | 3010 | 0 |
| 2.03 | 223488 | — | 6097 | 0 |
| 3.01 | 224080 | 478 | 9036 | 0 |
| 4.00 | 225376 | 654 | 12009 | 0 |
| 5.03 | 224640 | — | 15076 | 0 |
| 6.00 | 227408 | — | 18015 | 0 |
| 7.02 | 229648 | — | 21058 | 0 |
| 8.03 | 229680 | — | 24097 | 0 |
| 9.01 | 230048 | — | 27038 | 0 |
| 10.03 | 233760 | — | 30081 | 0 |
| 11.01 | 231520 | — | 33022 | 0 |
| 12.02 | 231408 | — | 36068 | 0 |
| 13.00 | 234512 | — | 39010 | 0 |
| 14.02 | 238176 | — | 42061 | 0 |
| 15.00 | 233504 | — | 45012 | 0 |
| 16.03 | 232528 | 2509 | 48093 | 0 |
| 17.02 | 241152 | 2680 | 51063 | 0 |
| 18.01 | 243440 | 2815 | 54037 | 0 |
| 19.01 | 244304 | 2962 | 57024 | 0 |
| 20.00 | 246352 | 3112 | 60004 | 0 |
| 21.03 | 250960 | 3270 | 63100 | 0 |
| 22.03 | 249552 | 3429 | 66076 | 0 |
| 23.03 | 223824 | 3584 | 69095 | 0 |
| 24.03 | 225200 | 3723 | 72081 | 0 |
| 25.03 | 225888 | 3865 | 75000 | 0 |

("—" = ETS probe round failed; see caveat below.)

## Verdict

PASS. Zero 5xx, zero connection errors, error rate 0.00000 over 75,000
requests. RSS post-minute-5: 224640 KB -> 225888 KB (1.006x, non-monotonic —
peak 250960 KB at min 21 followed by a BEAM GC drop to 223824 KB at min 23),
well inside the >20%-monotonic-growth fail gate.

## ETS growth attribution

Per-table counts at the final probe (min 25.03):

- `smalt_sentinel_rows: 3842` — exactly the ingest count (5% x 50 rps x
  1500s); linear-by-design bounded append, the only growing table.
- Everything else bounded: `smalt_resource_groups 8` (the PUT/GET set),
  `smalt_blobs 4`, `smalt_blob_containers 2`, `smalt_cosmos_pk_meta 3`,
  `smalt_cosmos_docs 1`, `smalt_cosmos_lsn 1`, `smalt_sentinel_streams 1`,
  `smalt_subscriptions 1` — the C/R/U/D cycles are net-zero as designed.
- No unattributed growth; no leak found. Substrate log over the window:
  zero 5xx (`grep -c "Sent 5" /tmp/soak-substrate.log` -> 0) and zero
  `[error]` lines between 22:16 and 22:42.

## ETS probe caveat

The probe is a separate `mix run --no-start -e` VM that compiles the shared
tree first; minutes 2-15 it failed (recorded as `—`) because concurrent
lanes had transiently broken files in `lib/` (cosmos.ex, frame_codec.ex,
shacl_projection.ex, support.ex, admission.ex, semconv/registry.ex,
trust_profile/deployment.ex). Once lane churn settled (min 16+) every probe
succeeded. The substrate itself never saw these failures — it was compiled
before the churn began.
