# Receipt: HAVE component 3 — scripts/have/meta_watchdog.py (Level-2 30m watchdog)

Standing: ALIVE
Date: 2026-10-18
Subject: `/Users/sac/smalt/scripts/have/meta_watchdog.py` (new, imports `scripts/quiet_check.py` + `scripts/have/state_ledger.py`)
Milestone: v26.10.18, HAVE component 3

## Contract coverage

1. Heartbeat age > 600s -> `ALRT-SEV1-HEARTBEAT-DEADLOCK` -> RP-01 automated
   (dead-beam sweep, port reclaim of 9443/9444/8443/5672/5673/9545 gated on
   verified-dead tree, ledger sanitize via HAVE-1's
   `state_ledger.sanitize_truncated_lines`, restart row append). Witnessed in run 2 below.
2. Zombie audit: orphan beam count >= 3 -> SEV2 + targeted SIGKILL of
   verified-dead-tree pids only. Implemented (`check_zombies`); not witnessed
   killing on this machine — this run had 0 orphans (2 live beams, both with
   LISTEN sockets in tree, both spared). No fixture orphan beam was spawned:
   spawning throwaway beams on a shared checkout risks colliding with live
   lanes, so the kill path is code-reviewed + gate-structured (cwd-prefix +
   tree-LISTEN + self-ancestry triple guard) but carries no kill witness.
   Marked honestly: kill path PARTIAL_ALIVE (structured, unwitnessed).
3. Dangling listeners on court ports with no live owner -> typed
   `ALRT-DANGLING-LISTENER`. Witnessed: ssh tunnel pid 61023 on 9443/8443/5672.
4. Cron verify: reads `crontab -l`; machine crontab has 1 non-marker line ->
   `ALRT-CRON-MISSING`. Honest limitation stated in alert detail and docstring:
   session-scoped cron is invisible to this check.
5. `--dry-run` prints actions, executes nothing. Witnessed in run 1.

## Safety invariants (the port law)

- cwd-prefix rule imported from `quiet_check` (`in_checkout`) — beams with cwd
  under `/Users/sac/smalt` are never classified dead.
- tree LISTEN check: any LISTEN socket anywhere in a pid's descendant tree
  disqualifies kill.
- self-ancestry guard: the watchdog's own process chain is never classified dead.
- Port reclaim fires only on holders that pass `verified_dead_tree()`;
  every spared holder is named in the action log (no silent skips).

## Run 1 — `--dry-run` live (executes nothing)

Command: `python3 scripts/have/meta_watchdog.py --dry-run` (exit 1 — alerts present by design)

```
=== meta_watchdog (DRY-RUN) ===
ALERT [SEV2] ALRT-DANGLING-LISTENER: port 9443 held by non-runtime pid 61023 cmd='ssh' (no live owner class)
ALERT [SEV2] ALRT-DANGLING-LISTENER: port 8443 held by non-runtime pid 61023 cmd='ssh' (no live owner class)
ALERT [SEV2] ALRT-DANGLING-LISTENER: port 5672 held by non-runtime pid 61023 cmd='ssh' (no live owner class)
ALERT [SEV2] ALRT-CRON-MISSING: crontab has 1 lines but none match AZB/HAVE/smalt loop markers ('azb', 'have', 'smalt')
no actions
exit=1
EXIT=1
```

Non-vacuity note: the ssh tunnel (pid 61023) forwarding 9443/8443/5672 is
flagged as a non-runtime court-port listener. This is a typed finding for the
operator, not an auto-kill — reclaim requires verified-dead tree and ssh is
very much live.

## Run 2 — real (non-dry) SEV1 trip, fixture heartbeat + fixture ledger

Fixture: `/tmp/have-wd-fixture/hb` backdated 1200s; ledger seeded with 1 valid
line + 1 trailing half-written line. Command:
`python3 scripts/have/meta_watchdog.py --heartbeat-path /tmp/have-wd-fixture/hb --ledger-path /tmp/have-wd-fixture/ledger.jsonl`

```
=== meta_watchdog  ===
ALERT [SEV1] ALRT-SEV1-HEARTBEAT-DEADLOCK: heartbeat age 1208s > 600s
ALERT [SEV2] ALRT-DANGLING-LISTENER: port 9443 held by non-runtime pid 61023 cmd='ssh' (no live owner class)
ALERT [SEV2] ALRT-DANGLING-LISTENER: port 8443 held by non-runtime pid 61023 cmd='ssh' (no live owner class)
ALERT [SEV2] ALRT-DANGLING-LISTENER: port 5672 held by non-runtime pid 61023 cmd='ssh' (no live owner class)
ALERT [SEV2] ALRT-CRON-MISSING: crontab has 1 lines but none match AZB/HAVE/smalt loop markers ('azb', 'have', 'smalt')
--- actions ---
  RP-01 automated (SEV1)
  RP-01 spared beam pid 40499 cwd='/Users/sac/smalt' (live lane or in-checkout)
  RP-01 spared beam pid 83625 cwd='/Users/sac/smalt' (live lane or in-checkout)
  port 9443 held by 40499 (beam.smp) NOT verified-dead — port law, left in place
  port 9443 held by 61023 (ssh) NOT verified-dead — port law, left in place
  port 9444 held by 40499 (beam.smp) NOT verified-dead — port law, left in place
  port 8443 held by 40499 (beam.smp) NOT verified-dead — port law, left in place
  port 8443 held by 61023 (ssh) NOT verified-dead — port law, left in place
  port 5672 held by 40499 (beam.smp) NOT verified-dead — port law, left in place
  port 5672 held by 61023 (ssh) NOT verified-dead — port law, left in place
  port 5673 held by 40499 (beam.smp) NOT verified-dead — port law, left in place
  port 9545 held by 40499 (beam.smp) NOT verified-dead — port law, left in place
  ledger sanitize retained=1 dropped=1
  restart row appended to /tmp/have-wd-fixture/ledger.jsonl
exit=1
```

Ledger on disk after the run (half-written line dropped, restart row appended):

```
{"ts": 1.0, "kind": "heartbeat", "subject": "fixture", "detail": ""}
{"detail": "meta_watchdog SEV1 heartbeat deadlock; dead_beams=0", "kind": "dispatch", "subject": "RP-01-restart", "ts": 1792384325.435898}
```

Substrate beam 40499 (LISTEN 9443/9444/8443/5672/5673/9545) and mix-test beam
83625 both survived the real trip — live lanes untouched, port law witnessed
firing in the spare direction.

## Verification ladder

- `python3 -c "import ast; ast.parse(...)"` -> SYNTAX-OK
- `python3 -m py_compile scripts/have/meta_watchdog.py` -> COMPILE-OK (exit 0)
- Dry-run live + real fixture SEV1 trip (above), exit 1 both (alerts fired — expected).

## Known limits

- Kill path (RP-01 step a, zombie SIGKILL) has no kill witness on this run —
  no verified-dead trees existed and none were fabricated near live lanes.
- Cron check covers machine crontab only, not session-scoped loops.
- `--dry-run` still reads live process state (by design; it writes nothing).

## Replay

```
cd /Users/sac/smalt
python3 scripts/have/meta_watchdog.py --dry-run
python3 scripts/have/meta_watchdog.py \
  --heartbeat-path <fixture-hb-backdated->600s> \
  --ledger-path <fixture-ledger>
```
