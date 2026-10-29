# BK-NENV — N-lane harness vs gated debug faces (SMALT_DEBUG_FACES)

**Standing:** **ALIVE**
Context: solo
Date: 2026-10-22
Repo: /Users/sac/smalt (main)
Lane: BK-NENV
Parent: EXPL7-R1 (`expl7r1-bff-repairs.md` E7-3), census `bkbffsec-census.md` (KD-171 gate)

## Finding (typed, per lane)

No n-lane harness in `scripts/bench/` spawns its Next server with the gated
env, and only one n-lane spawns Next at all:

| lane | spawns Next? | calls gated faces? | action taken |
|---|---|---|---|
| n5_compute.spec.mjs | YES (`npx next start -p 39555`) | NO (`/bench/compute` only) | typed comment: gate stays OFF, no env (no cargo-cult) |
| n6_isr_stampede.mjs | no — external server via `N6_URL` | YES (`POST /api/bench/isr-stats` reset + stale witness) | startup preflight: probe POST reset; 404 -> typed FATAL, exit 3 |
| n7_sse_herd.mjs | no — external server via `--url` | YES (`GET ?stats=1`, `POST` storm abort) | startup preflight: probe `?stats=1`; 404 -> fatal jsonl row + log, exit 3 |
| n1/n2/n3/n4/n8 | no | no | untouched (no gated-face calls) |

Since n6/n7 drive externally-launched servers, the harness cannot export the
env into the server process — the lawful fix is a loud preflight that converts
the confusing mid-phase 404 ("stats reset 404" / permanently `-1` stats) into
a typed boot-time exit naming the env and the EXPL7-R1 receipt.

## Witness (real Next dev server, port 39826, torn down after)

Gate OFF (server without the env):

```
$ curl -s -w " status=%{http_code}\n" "http://127.0.0.1:39826/api/v1/stream?stats=1"
{"error":"not_found"} status=404
```

Gate ON (`SMALT_DEBUG_FACES=1 npx next dev`):

```
$ curl -s -w " status=%{http_code}\n" "http://127.0.0.1:39826/api/v1/stream?stats=1"
{"active":0,"seq":0,"ring_len":0,"ring_span":0} status=200
$ curl -s -X POST -H 'content-type: application/json' -d '{"reset":true}' -w " status=%{http_code}\n" \
    "http://127.0.0.1:39826/api/bench/isr-stats"
{"ok":true,"reset":true} status=200
```

Non-vacuity (preflight flips): n7 run against the gate-OFF server exits 3 at
boot, before the herd ramp:

```
$ node scripts/bench/n7_sse_herd.mjs --url http://127.0.0.1:39826/api/v1/stream --target 1 --jsonl tmp/nenv-n7-probe.jsonl
[n7] ulimit -n = 1048576, target = 1
[n7] FATAL: /api/v1/stream?stats=1 -> 404 (debug faces gated). Relaunch the workspace server with SMALT_DEBUG_FACES=1 (EXPL7-R1 E7-3, docs/jira/v26.10.22/receipts/expl7r1-bff-repairs.md).
n7 exit=3
```

Teardown: all three dev servers killed; `lsof -nP -iTCP:39826 -sTCP:LISTEN`
-> exit 1 (port free).

## Standing

ALIVE — preflights are fail-closed (they can only block a lane whose server
lacks the env; a lane whose faces are open passes the preflight unchanged).
Note: the n-family is RETIRED per REGISTRY.md v26.10.19 (64f6099); these edits
arm the harnesses for a lawful revival (which still requires re-registration
with a port block + successor receipt per REGISTRY.md).
