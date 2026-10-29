# BK-PORTS2 — F2/F3 reconcile

- **Standing**: PARTIAL_ALIVE
- **Context**: solo
- **Date**: 2026-10-22 04:28–04:37 local
- **Lane**: BK-PORTS2 (owns scripts/substrate.sh F3 fix + F2 reconcile)

## F3 — substrate-status dead-pid ORPHAN false positives (FIXED)

Diff in `scripts/substrate.sh` (14 lines): added `live_lock_holders()`
(`kill -0` liveness recheck over `lock_holders`), routed `orphan_holders()`
through it, and liveness-filtered the `lock HELD by:` listing. Landed by
coordinator tick checkpoint e3e351fc ("BK-PORTS2 substrate.sh").

### Non-vacuity (real shim, before/after)

**BEFORE-witness** (parent census, bkports-hygiene.md): dead pids
24844/24869/26836 listed as `ORPHAN ... no listening socket`.

**AFTER — live holder must still fire (not over-filtering)**:

```
$ ( exec 9>/tmp/smalt-substrate.lock; flock 9; sleep 30 ) & sleep 1; scripts/substrate.sh status
[STATUS] lock HELD by: sleep pid 43859 fd 9w;
[STATUS] ORPHAN: pid 43859 holds the lock with no under...
[STATUS] run 'just substrate-down' to clear it
```

A live no-listener lock holder is still reported (the recheck filters only
dead pids). One intermediate edit was caught and fixed by this court: the
first pid-extraction attempt (`${l##* }`) grabbed the fd token (`9w`) not the
pid, silently emptying the HELD-by line — the shim exposed it immediately.

**AFTER — post-shim, corrected extraction**:

```
[STATUS] lock HELD by: sleep pid 43859 fd 9w;   # live holder listed
[STATUS] ORPHAN: pid 43859 ...                  # live orphan still fires
== post-shim ==
[STATUS] lock FREE (flock -n succeeds)
```

No fixture/mocked holder: the court ran a real `flock`-holding subshell and
the real status path both ways.

## F2 — out-of-band canonical-port holder (self-resolved, no kill)

- Parent-census subject 21011 was **already gone** at reconcile start
  (`ps -p 21011` empty).
- 04:28:36 a fresh detached harness beam **38563** (ppid 1, 0 lock fds,
  `mix run --no-start --no-halt` full-smalt self-boot, kafka on 19092)
  held all five canonical ports with lock FREE — the exact F2 shape.
- Classified **live-lane, not killed**: spawned seconds before the check
  while lanes `bkseal`/`skepr2` were actively compiling (build roots touched
  04:28) → live consumers in flight.
- **04:31**: 38563 exited on its own; concurrently a real
  `substrate.sh up` window (bash 44311) appeared with a queue of flock
  waiters. Final observed state:

```
[STATUS] port 9443: free          [STATUS] substrate DOWN
[STATUS] port 9444: free          [STATUS] lock HELD by: (live flock waiters)
...                               [STATUS] ORPHAN: (live waiter pids)
```

Ports free, substrate DOWN, heavy live waiter traffic — another lane's
substrate-up loop was contending for the lock. Out-of-lane; not touched.

### Outcome

No kill, no drift marker minted: the out-of-band holder exited before
registration was needed, and a marker for a dead pid would itself be new
drift. The recurring F2 *class* (per-test harness self-boots binding
canonical ports outside the flock window) remains open — it recurred within
4 minutes of the parent census (21011 → 38563) — with the hazard landing as
predicted: the next substrate-up window had to out-wait the harness before
binding. Owner of the class fix: whichever harness template runs
`mix run --no-halt` against canonical ports instead of a private port block;
typed here, not fixed in lib/.

## Standing

PARTIAL_ALIVE: F3 fixed with real before/after court (including a caught
intermediate defect); F2 reconciled by observation — self-resolved, no kill,
class remains open and typed. All output embedded is real command output from
this window.

---

## RE-WITNESS addendum (BK-REWIT wave 1, 2026-10-22)

Original evidence above untouched. F3 court re-run verbatim (real flock
holder, real status path, exit capture):

```
$ ( exec 9>/tmp/smalt-substrate.lock; flock 9; sleep 15 ) & sleep 1; scripts/substrate.sh status
[STATUS] lock HELD by: sleep pid 53402 fd 9w;
[STATUS] ORPHAN: pid 53402 holds the lock with no listening socket in its tree
status exit=0
$ # after holder exits:
[STATUS] lock FREE (flock -n succeeds)
post-holder exit=0
```

The corrected pid extraction still lists the live holder by pid (not the fd
token) and still fires the ORPHAN line for a live no-listener holder — the
F3 fix's two properties both reproduce. exit=0 both ways.
Standing: PARTIAL_ALIVE (unchanged; F2 class still open as typed above).
