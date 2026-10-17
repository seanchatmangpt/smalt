# Court-Readiness Checklist — v26.10.16 (2026-10-16)

Skill lane: smalt-court (readiness portion only, freeze active).

## PASS

1. **court_x2.sh stages**: complete — two fresh `just court` runs, green
   predicate with compile-abort guard, failure-set diff, fail-safe court_emit.
2. **Invariant gates**: 7 gates + shared infra in gates/ (blob_worm,
   cosmos_etag_cas, ledger_chain, lock_clamp, queue_capacity, amqp driver,
   common).
3. **Shim-courts**: 25 `*_court.sh` + witnesses + lib.sh — count matches.
4. **MCP/descriptor parity**: verified by mcp-doctor lane (8 tools, TTL ↔
   generated descriptor).

## PENDING (resolve pre/at court-x2)

1. **bench-receipt stale + boot FAIL** (`tmp/bench-receipt.json`,
   2026-10-15T14:06; p95 10.8s vs 5.0 target) — bench-check fails the court on
   this receipt. **Coordinator action: re-run the bench receipt + bench-report
   regen post-freeze, before court-x2.**
2. **Bench aggregation drift**: 7 jsonl in window bench/ vs 3 in
   BENCH_AGGREGATE — `bench/report.py` regen post-freeze (fin-sweep covers).
3. **Two prior reds lack recorded owners**: orphan 404-vs-400 (fix artifacts
   on disk: smalt_arm_gateway_test :464-477/:1030-1038/:1065-1080) and corpus
   Helper compile (helper.exs intact, red unreceipted). **Owner: the in-flight
   pre-court-x2 repair lane's post-drain sweep; its receipt names both.**
4. Registry manifest bookkeeping stale (content-fresh) — freeze-orchestrator
   `mix smalt.gen` regen rewrites it.

## Verdict

Structurally ready; release-ready after bench re-receipt + regen + repair-lane
receipt naming the two reds.
