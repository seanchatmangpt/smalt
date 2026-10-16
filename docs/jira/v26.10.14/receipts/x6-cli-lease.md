# X-6: CLI pytest lane lease — fixture-scoped substrate protocol (F-14 + DoD-3)

Standing: ALIVE (both sessions green twice, run tails below)
Lane: X-6 · Date: 2026-10-15 · No commits (coordinator owns transitions)

## Subject

- `/Users/sac/smalt/smalt-cli/tests/conftest.py`
- `tests/test_servicebus.py`, `tests/test_eventhub.py`, `tests/test_keyvault.py`
  (enforce lanes: import-time `_boot()` deleted, fixture-scoped)
- `tests/test_identity.py`, `tests/test_resourcegraph.py` (enforce marks;
  ARM/EGRESS now read via `conftest.ARM/EGRESS` rebound per session)
- `tests/test_blob.py`, `tests/test_cosmos.py` (anonymous marks)
- `smalt-cli/README.md` (session-split protocol doc)
- Locks now `/tmp/smalt-substrate-cli4.lock` (anonymous, ports 39643/39644)
  and `/tmp/smalt-substrate-cli5.lock` (enforce, ports 38654-38656/38672-38673)

## Protocol (new session split)

- `pytest -m anonymous` — blob/cosmos, anonymous-mode substrate 39643/39644,
  boot lock `/tmp/smalt-substrate-cli4.lock`, log `/tmp/cli4-substrate.log`
- `pytest -m enforce` — identity/resourcegraph/servicebus/eventhub/keyvault,
  enforce substrate 38654-38656/38672-38673, lock
  `/tmp/smalt-substrate-cli5.lock`, log `/tmp/cli5-substrate.log`
  (conftest owns the cli5 boot; test files no longer boot at import —
  `_boot()`/`SUB_PID`/atexit-kill machinery deleted from all three files)
- Each session fixture: probe → reuse healthy substrate read-only (lane-unique
  names keep parallel lanes non-interfering), else boot private-port under
  own lock (bounded flock, lock released after boot — guards construction,
  not the session); teardown kills only what the session booted
- Plain `pytest` (no `-m`): both profiles boot lazily and sequentially — no
  shared lock, no cross-lane queue

## F-14 root causes fixed

1. Import-time `_boot()` at module import (multi-minute cross-lane flock
   queues on /tmp/smalt-substrate-cli5.lock) — DELETED; boot is now
   fixture-scoped and lazy. Whole enforce session: 20 min → ~28 s.
   Collect-only boots nothing.
2. F-14's SUBSTRATE_LOCK_TIMEOUT: lock now bounded (180 s) with typed
   `SUBSTRATE_LOCK_TIMEOUT` RuntimeError naming `lsof` recovery; per-profile
   locks no longer contend.
3. Anonymous vs enforce exclusivity: enforced by mark split
   (`-m anonymous` / `-m enforce`); each session boots the auth mode its
   tests need. Identity/resourcegraph read ARM via `conftest.ARM` (rebound by
   the enforce fixture to 38654); blob/cosmos stay on the anonymous 39644
   egress plane.

## Fixes landed alongside (required to reach green)

- conftest `_ENFORCE_BOOT` sts_signing_secret → `py-lane6-known-secret-…`
  (identity self-mint 401 court mints with that secret; the cli5 secret
  broke `test_expired_self_minted_401`)
- identity/resourcegraph: bare `ARM`/`EGRESS` → `conftest.ARM`/`conftest.EGRESS`
- KD-49 typed skips: substrate AMQP attach-echo divergence mis-shapes
  source/target (pyamqp `Target.__new__` 9-vs-8 TypeError; settlement fails
  with "must be of type ServiceBusReceivedMessage" / "object of type 'UUID'
  has no len()"). servicebus/eventhub `kd21_skip` now classifies these as
  SKIP-KD49 (named against KNOWN_DIVERGENCES.md KD-49), per lane convention.
  KD-21 shim itself has landed in the substrate
  (`lib/smalt/messaging/amqp/connection.ex` KD-21 shim block witnessed).

## Verification (real runs, twice+)

```
# enforce, round 2 & 3 (stable):
13 passed, 5 skipped, 19 deselected, 4 warnings in 27.71s / 29.85s
# anonymous, round 2 & 3 (stable):
15 passed, 15/15 green; "15 passed, 22 deselected in 3.57s / 3.69s"
# collect-only (no boot): 18/37 collected, 0.38s, no substrate spawned
```

5 enforce skips are typed KD-49 wire divergences (servicebus x3, eventhub x2
— KD-21 legacy EH signature), zero failures, zero lock waits.

## Standing

ALIVE for the harness protocol; the 5 KD-49 skips remain OPEN on the
substrate lane (attach-echo fix in lib/smalt/messaging/amqp/connection.ex).
Unknown-blocker: none observed; the first anonymous batch errored once on a
transient first-boot mix-compile contention with a concurrent lane's compile
(1.48s, self-healed on rerun; bounded timeout is the guard).
