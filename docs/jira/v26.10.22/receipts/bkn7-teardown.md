# BK-N7 — n7 SSE-herd teardown fix + same-class sweep

Standing: **ALIVE**
Context: solo
Date: 2026-10-22
Repo: /Users/sac/smalt (main)
Lane: BK-N7
Parent: BK-NREG (`bknreg-nfamily-disposition.md` defect 1), KD-173C harness finding

## Fix 1 — `scripts/bench/n7_sse_herd.mjs` (defect closed)

BK-NREG typed defect: n7 hangs at exit after its verdict — open SSE response
sockets hold the node event loop. Fix: after the verdict log line, destroy
every client socket, clear pending reconnect timers (`_pendingTimer`), and
`process.exit(0)` on the summary path. Verdict computation untouched.

## Witness (real leg, gate-ON server, private port 39827)

Server: `SMALT_DEBUG_FACES=1 npx next dev -p 39827` (per BK-NENV recipe;
torn down after). Bounded run via `perl alarm 120` proving no hang:

```
$ perl -e 'alarm 120; exec @ARGV' node scripts/bench/n7_sse_herd.mjs \
    --url http://127.0.0.1:39827/api/v1/stream --target 1 --jsonl tmp/bkn7-witness.jsonl
[n7] ulimit -n = 1048576, target = 1
[n7] ramp active=1 attachErrors=0 runAt=1
[n7] storm fired: {"aborted":1}
[n7] post-storm active=1
[n7] reconnect settled active=1
[n7] verdict divergence=0.0000% permanent=0 attachErr=0 overflows=0 handles=[5..5]
exit=0 elapsed=16s
```

Verdict row (tmp/bkn7-witness.jsonl):

```
{"lane":"n7","ts":"2026-10-22T12:21:04.523Z","phase":"verdict","target":1,"herd_size":1,"reattached_final_active":1,"permanent_drops":0,"attach_errors":0,"client_gaps_total":0,"diverged_clients":0,"divergence_rate":0,"divergence_threshold":0.001,"buffer_overflows":0,"listener_handles_min":5,"listener_handles_max":5,"server_seq":299,"server_ring_span":299,"elapsed_ms":15589}
```

Verdict class identical to the BK-NREG witness (divergence 0.0000%, permanent
0, attachErr 0, overflows 0, handles [5..5], server_seq 299) and the process
exits 0 promptly under a 120s alarm (used 16s) — the pre-fix hang is gone.

## Sweep — same-class teardown audit of scripts/bench/*.mjs

Swept every .mjs harness for EventSource / fetch-stream / raw-socket /
keep-alive-agent patterns relying on natural event-loop drain:

- **`c3_eh_blob_archive.mjs` — FIXED (same class)**: single persistent
  keep-alive `http.Agent` (`keepAlive: true, maxSockets: 1`) whose sockets
  hold the loop; both exit paths (`process.exitCode` assignment, natural
  drain) now call `agent.destroy()` before finishing. Mechanical fix.
- n6_isr_stampede.mjs, flood_autocannon.mjs, ctq2_txn.mjs, n8_soak_bot.mjs,
  c7_cross_soak.mjs — already end with explicit `process.exit`; no change.
- n4_ingest_saturation.mjs — undici default fetch agent; witnessed exit 0 in
  BK-NREG's real leg, no hang. No change.
- b4_messaging_ts.mjs / c2_sb_cosmos.mjs — kill the substrate and drain
  port-free before finishing (SDK clients are the handle holders and their
  close paths are inside the SDK); not mechanical, left as-is.
- t36_boot_court.mjs, lifecycle_harness.mjs — drain to exitCode via
  explicit client close/kill paths already; no change.

## kd173c-harness.mjs ENOTEMPTY — SKIPPED (owner in-flight)

`workspace/scripts/lib/kd173c-harness.mjs` carries an unstaged modification
at witness time (`git status --porcelain` shows ` M` on the file) — the
KD-173C lane's edit is in-flight, so per same-checkout fan-out law the
retry-once-then-leave-loud rmSync fix is left to that lane's owner.
Skip is loud, not silent.

## Standing

ALIVE — n7 teardown fix witnessed on a real gate-ON server (verdict
unchanged, exit 0 in 16s under bounded alarm); c3 same-class fix applied;
sweep dispositions typed; kd173c skipped-with-owner loudly.
