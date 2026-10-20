# Receipt — ex2 retail-order-pipeline

- Date: 2026-10-19
- Lane: ex2 (examples wave), owner dir `/Users/sac/smalt/examples/retail-order-pipeline/`
- Subject: `index.ts`, `run.sh`, `README.md`, `receipt.md` (this file);
  `node_modules` symlink → `verification/ts/node_modules` (SDK reuse, no
  second install)
- Standing: **PARTIAL_ALIVE** — 4/8 GREEN (Event Hubs + Cosmos planes fully
  exercised end-to-end over official `@azure/*` SDKs); 4/8
  REGISTERED-DIVERGENCE#KD-115 (Service Bus plain-queue legs blocked by the
  witnessed, registered substrate gap KD-115; the legs record the divergence,
  never a fake pass).

## Checks

| Check | Verdict | Evidence |
|---|---|---|
| sb-send-receive-complete | REGISTERED-DIVERGENCE#KD-115 | received=0/10, send resolved — attach+flow+CBS OK, no delivery on receiver-link flow credit |
| sb-defer-receive-deferred | REGISTERED-DIVERGENCE#KD-115 | not exercisable under KD-115 — no delivery to defer |
| sb-lock-renewal | REGISTERED-DIVERGENCE#KD-115 | not exercisable under KD-115 — no lock to renew |
| sb-dlq-maxdelivery | REGISTERED-DIVERGENCE#KD-115 | not exercisable under KD-115 — poison order never re-delivered, DLQ never populated |
| eh-partitions-pinion | GREEN | partitionIds=[0,1] (pinion: fixed ["0","1"]) |
| eh-partition-pinned-send | GREEN | 50 events → partition 0, 50 → partition 1 |
| cosmos-order-etag-cas | GREEN | stale etag → typed 412; final status read back = "paid" |
| eh-checkpoint-exactly-once | GREEN | applied=100/100 duplicates=0 casErr=none, perPartition 0:50 1:50 (Cosmos etag-CAS checkpoint store) |

## Final run output (embedded, 2026-10-19)

Private substrate block `v2` (`scripts/substrate-ctl up --block v2`, auth
enforce, ports amqp=39720 eh=39721 arm=39722 egress=39723 tls=39724) — the
canonical/front block was flapping under concurrent lane boots, so the lane
used its own block per the reuse-else-boot law.

```
== ex2-retail: 4/8 GREEN, 4 REGISTERED-DIVERGENCE ==
  [REGISTERED-DIVERGENCE#KD-115] sb-send-receive-complete — zero-delivery (KD-115 registered): received=0/10, send resolved — attach+flow+CBS OK, no delivery on receiver-link flow credit
  [REGISTERED-DIVERGENCE#KD-115] sb-defer-receive-deferred — not exercisable: plain-queue zero-delivery (KD-115 registered) — no delivery to defer
  [REGISTERED-DIVERGENCE#KD-115] sb-lock-renewal — not exercisable: plain-queue zero-delivery (KD-115 registered) — no lock to renew
  [REGISTERED-DIVERGENCE#KD-115] sb-dlq-maxdelivery — not exercisable: plain-queue zero-delivery (KD-115 registered) — poison order never re-delivered, DLQ never populated
  [GREEN] eh-partitions-pinion — partitionIds=[0,1] (pinion: fixed ["0","1"])
  [GREEN] eh-partition-pinned-send — 50 events -> partition 0, 50 -> partition 1
  [GREEN] cosmos-order-etag-cas — stale412=true finalStatus=paid
  [GREEN] eh-checkpoint-exactly-once — applied=100/100 duplicates=0 casErr=none perPartition=[0:50 1:50]
EXIT=0
```

## Falsifier / replay

```
bash examples/retail-order-pipeline/run.sh
```

- The KD-115 classification is differential: `verification/ts` wf3 on the
  same block shows the identical zero-delivery signature on
  `sb-send20-receive-complete` while its session leg delivers (5/5, KD-116
  settle-shape note) — matching the register's witnessed KD-115 receipt.
- `scheduleMessage` is a typed loud skip (KD-118: schedule-message
  $management op unlanded, 501 UNSUPPORTED_OPERATION) — declared in
  README.md, not faked as a check row.
- Differential probe command (wf3 on the private block) and the minimal
  send→receive repro are in the session log; the harness itself is the
  replayable artifact.

## Honest notes

- Two initial runs against the shared front block failed with
  substrate-down/fetch-failed mid-run (the block was being torn down by
  other lanes concurrently); those failures were environmental, witnessed,
  and superseded by the private-block run above.
- No errors are hidden: the four KD-115 rows are the substrate's registered
  divergence, reproducible on demand by re-running the harness.
