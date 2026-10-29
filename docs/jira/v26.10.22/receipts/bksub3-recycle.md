# BK-SUB3 — shared substrate recycle (stale-beam remediation)

**Standing**: ALIVE · **Context**: solo · **Date**: 2026-10-22 · **Subject**: `/Users/sac/smalt` shared substrate recycled onto the current tree (post-`daea2d87` fixes incl. BK-MON-2 `368c32d5`)

Ops lane. No lib/, test/, or CLI code edits; this receipt is the only artifact.
Closes the stale-beam artifact recorded in `docs/jira/v26.10.22/receipts/bkmon4-final-verify.md`
(shared beam pid 76687, booted 05:19, predated the 06:55 BK-MON-2 monitor fix — metrics 500).

## Pre-bounce lane check (quiet, typed-orphan law)

- `just substrate-status`: UP pid **76687** on 9443/9444/5672/5673 (+9545), lock FREE.
- **BEFORE lsof** (embedded):

```
COMMAND    PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
beam.smp 76687  sac   65u  IPv4 0x7274183549e5deaa      0t0  TCP 127.0.0.1:9443 (LISTEN)
beam.smp 76687  sac   66u  IPv4 0xbbcf7ca3437911bc      0t0  TCP 127.0.0.1:9444 (LISTEN)
beam.smp 76687  sac   67u  IPv4 0x2ed4ce4a11b73cfb      0t0  TCP 127.0.0.1:5672 (LISTEN)
beam.smp 76687  sac   68u  IPv4 0x571beabbe0e08692      0t0  TCP 127.0.0.1:5673 (LISTEN)
beam.smp 76687  sac   69u  IPv4 0x6fe7d83d97aaa70a      0t0  TCP 127.0.0.1:9545 (LISTEN)
```

- **ESTABLISHED client connections to shared ports: zero** — no lane was riding the shared
  substrate. All other live beams are lane-private (ephemeral ports 39600–65463 range, private
  build roots `_build-*`): witness boot 1788, bkkfkskep 2652, bkgwsskep 5450 (`--hang`,
  lane-private), and three pytest-fixture boots. Not orphans by the tree-aware law (private-port
  lanes are live); none touched 9443/9444/5672/5673, so no wait-bounded hold was needed and no
  lane is disturbed by the bounce.

## Bounce

- `just substrate-down`: killed pid 76687, all four ports reported free, post-down lsof empty.
- `SMALT_UP_TIMEOUT=600 9>&- just substrate-up` with `$HOME/.asdf/shims` first on PATH:
  lock held on fd 9, spawned pid **81426** with lock fd CLOSED, lock released after listener
  verification. Listeners polled ready in ~10 s.

### AFTER lsof (embedded)

```
COMMAND    PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
beam.smp 81426  sac   65u  IPv4 0xf6fd3f2ff6071381      0t0  TCP 127.0.0.1:9443 (LISTEN)
beam.smp 81426  sac   66u  IPv4 0x328fd08fa4ee5001      0t0  TCP 127.0.0.1:9444 (LISTEN)
beam.smp 81426  sac   67u  IPv4 0xfd65013ff672d745      0t0  TCP 127.0.0.1:5672 (LISTEN)
beam.smp 81426  sac   68u  IPv4 0x571beabbe0e08692      0t0  TCP 127.0.0.1:5673 (LISTEN)
beam.smp 81426  sac   69u  IPv4 0xbd0ff7d527f0d51e      0t0  TCP 127.0.0.1:9545 (LISTEN)
```

## Post-bounce proof

1. **Metrics 200-with-rows on the shared :enforce substrate** (the BK-MON-2 falsifier, re-run
   against the recycled beam): real STS mint → storageAccounts PUT (202) → custom-metric emit
   POST `microsoft.insights/metrics` (200, `Bksub3Metric`=7) → CLI
   `monitor metrics … --metric Bksub3Metric -o json` → **exit 0, `"series_count": 1`,
   `"total": 7`** — `METRICS-PROOF-OK`. No 500 anywhere; the stale-beam artifact is gone.
2. Health set, all on pid 81426:

| Face | Probe | Result |
|---|---|---|
| 9444 TLS twin | tokenless GET `/subscriptions?api-version=2024-02-01` | **401** (challenge) |
| STS | POST `/…/oauth2/v2.0/token` | **200** (minted) |
| 9443 ARM | GET `/metadata/endpoints?api-version=2024-02-01` | **200** (plain HTTP — 9444 is the TLS face) |
| 9545 MCP | `tools/list` | **37 tools** |

## Standing

ALIVE — shared substrate now runs the current tree on pid 81426; the monitor metrics face serves
200-with-rows on the shared beam, closing the stale-beam note in BK-MON4. Zero lanes were
connected at bounce time (typed-orphan check embedded above); lane-private beams elsewhere on the
machine are live lanes, not orphans, and were left untouched.
