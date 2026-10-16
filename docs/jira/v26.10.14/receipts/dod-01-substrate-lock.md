# DoD-1: substrate lock leak fix

- Date: 2026-10-15
- Repo: /Users/sac/smalt
- Files: `scripts/substrate.sh` (new), `justfile.d/01-substrate-lock.just`
  (was a placeholder comment, now 3 recipes)
- Recipes: `just substrate-up` / `just substrate-down` / `just substrate-status`

## Defect

The SDK boot harness held `/tmp/smalt-substrate.lock` via `flock` and spawned
`mix run --no-halt` as a child; the beam inherited the lock fd, so after the
harness exited the orphaned beam held flock + ports forever, starving queued
lanes (one held 27 min). Witnessed live during this fix: orphaned
`flock -x /tmp/smalt-substrate.lock mix run ...` (pid 47479, ppid 1, 22 min)
with leaked beam child 48109 holding the exclusive lock while two active
lanes queued behind it.

## Fix

`scripts/substrate.sh` acquires the lock per-WINDOW: held only while
spawning + verifying listeners, spawned child runs with `9>&-` (lock fd
closed), lock releases on script exit while the substrate stays up, tagged
with its pid in `/tmp/smalt-substrate-state/substrate.pid`.

- `up`: queue on `flock -w $SMALT_LOCK_WAIT (default 300) 9`, spawn
  `mix run --no-start --no-halt -e ...` with `9>&-`, verify all 4 listeners
  (9443 9444 5672 5673) + `GET /metadata/endpoints` 200, release.
- `down`: pid file + port-holder sweep + orphan lock-holder sweep
  (orphans = lock holders whose whole tree has NO listening socket —
  private-port lanes are correctly classified LIVE, no false kill), verify
  ports free. Exit 1 if a port is still held.
- `status`: port probes, lock probe (`flock -n`), holder listing, orphan
  detection (report-only; points at substrate-down).

## Proof (real output, 2026-10-15 ~17:40-18:10 local)

```text
$ just substrate-up           # queued ~22 min through fleet contention
[UP] lock held on fd 9; spawning substrate with fd 9 CLOSED (9>&-)
[UP] spawned pid 47855 (lock fd NOT inherited); verifying listeners...
[UP] lock released (fd 9 closed); substrate stays up, pid tagged in
     /tmp/smalt-substrate-state/substrate.pid

$ lsof -p 47855 | grep -c smalt-substrate.lock
0                                  # beam holds ZERO lock fds

$ # harness exited exit=0; substrate kept serving:
port 9443/9444/5672/5673 LISTENING (pid 47855)
GET /metadata/endpoints -> 200

$ just substrate-down
[DOWN] killing substrate pid 47855
[DOWN] port 9443 free ... port 5673 free
exit=0
curl health after down: 000 (connection refused, exit 7)

$ just substrate-status        # with a private-port lane mid-window
[STATUS] port 9443: free ... port 5673: free
[STATUS] substrate DOWN
[STATUS] lock HELD by: beam.smp pid 52776 fd 3w;flock pid 52775 fd 3w;
                                  # no false ORPHAN flag; detector run:
52775: LIVE (listener in tree)    # beam listening on *:39643 (private lane)
52776: LIVE (listener in tree)
```

Orphan cleanup performed this session: killed pids 47479 (orphaned flock,
ppid 1, 22 min lock hold) + 48109 (its leaked beam, 0 established conns);
lock immediately transferred to the queued live lane (48096 acquired).

## flock -n witness note

A deterministic "second `flock -n` succeeds immediately after harness exit"
line could not be witnessed: live fleet lanes held the lock continuously
(14 min of 5s-interval polling found zero free windows — the starvation
symptom this fix removes). Release is nonetheless deterministically proven:
the harness exited 0, and `lsof -p <beam> | grep -c smalt-substrate.lock`
= 0 — fd 9 closed means the flock was released at script exit; no pid from
the up run appears in any subsequent lock-holder listing.

## Standing

ALIVE — full up/serve/down cycle executed on the canonical lock and ports
during live fleet contention. Not committed (per task scope).
