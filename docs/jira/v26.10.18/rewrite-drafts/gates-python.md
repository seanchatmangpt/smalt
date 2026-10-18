# Rewrite drafts: non-ExUnit tiers — deadline-based readiness probes (quiet-check pattern)

Window: v26.10.18. READ-ONLY audit of a frozen tree; drafts only, nothing applied.

Chicago rule: poll an observable readiness condition under a `time.monotonic()`
deadline with a typed failure on expiry; never a fixed sleep or a fixed
iteration count. A fixed sleep is doubly wrong: it wastes wall-clock when the
event fires early and lies (passes or masks) when the event never fires.

## Verdict per surface

| Surface | Status | Action |
|---|---|---|
| `gates/common.py` | CLEAN | none — already the canonical pattern |
| `scripts/stress/_substrate.py` | CLEAN | none |
| 6 invariant gates (cosmos/blob/appconfig/ledger/queue/lock) | CLEAN | all boot via `common.run_gate` → `spawn_substrate` → `wait_for_port` (deadline poll + proc-death check) |
| `gates/test_isolation_leak_gate.py` | CLEAN | static scan, no substrate, no sleeps |
| `workspace/scripts/e2e-court.mjs` | CLEAN (one optional gap) | see D6 |
| `smalt-cli/tests/conftest.py` | 3 fixed-sleep sites | D1, D2, D3 |
| `test/sdk-python/run.sh`, `run_ledger.sh`, `run_atlas.sh` | 2 fixed-sleep sites each | D4 |
| `test/sdk-python/py_auth_keyvault.py` | 1 fixed sleep | D5 |
| `test/sdk-python/py_servicebus.py` | 1 fixed sleep (domain wait) | D7 |

---

## D1 — smalt-cli/tests/conftest.py `_sweep_stale_listeners` (L209-213)

Current (fixed 10x1s iteration count, ~10s worst case on a dead port set):

```python
for _ in range(10):
    if not any(_port_open(p) for p in ports):
        return True
    time.sleep(1)
return False
```

Draft — monotonic deadline, 0.2s poll granularity (each `_port_open` already
costs up to 1s connect timeout; poll finer than that is meaningless, so the
real win is the deadline + typed return):

```python
def _sweep_stale_listeners(ports, timeout_s=10.0):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if not any(_port_open(p) for p in ports):
            return True
        time.sleep(0.2)
    return False
```

Observable condition: every lane port refuses connections. Typed expiry:
`False` (caller already fails closed to a fresh boot either way — keep that
call-site semantic).

## D2 — smalt-cli/tests/conftest.py `_ensure_substrate` boot wait (L317-323)

Current (fixed 120 iterations, 1s poll, NO proc-death check inside the loop —
a substrate that dies at iteration 3 still burns 117 more seconds, and each
failed `_port_open` adds up to 1s connect timeout on top, so worst case is
~4 minutes, not 120):

```python
up = False
for _ in range(120):
    if all(_port_open(p) for p in ports) and (ready is None or ready()):
        up = True
        break
    if proc.poll() is not None:
        break
    time.sleep(1)
```

Draft — mirrors `_substrate.wait_for_port` semantics (monotonic deadline,
fast poll, fail-closed with log tail). Also reuse `_port_open`'s timeout
lowered to 0.25s to match `_substrate.port_open`:

```python
def _wait_boot(ports, proc, ready, log_path, timeout_s=180.0, poll=0.25):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        rc = proc.poll()
        if rc is not None:
            tail = open(log_path).read()[-500:]
            raise RuntimeError(
                f"SUBSTRATE_DIED rc={rc} pre-ready — boot log {log_path} tail: {tail}")
        if all(_port_open(p, 0.25) for p in ports) and (ready is None or ready()):
            return
        time.sleep(poll)
    tail = open(log_path).read()[-500:]
    raise RuntimeError(f"SUBSTRATE_TIMEOUT after {timeout_s}s — boot log {log_path} tail: {tail}")
```

Call site becomes `up`-flag-free; the `SUBSTRATE_TIMEOUT` message keeps its
current format so the R186 loud-skip path (`_skip_substrate_unavailable`)
is unchanged. `_port_open(port)` gains an optional `timeout=1.0` param
(default preserved for `_sweep_stale_listeners`).

Typed-failure upgrade: `SUBSTRATE_DIED` is a NEW typed class distinct from
timeout — a dead mix is diagnosable in seconds, not at the 180s mark.

## D3 — smalt-cli/tests/conftest.py `_kill_substrate` (L340-353)

Current (blind `time.sleep(1)` between SIGTERM and SIGKILL — always pays 1s
even when the process exits in 20ms, and can kill mid-shutdown work):

```python
time.sleep(1)
try:
    os.killpg(proc.pid, signal.SIGKILL)
```

Draft — poll for actual exit, escalate only at the deadline:

```python
deadline = time.monotonic() + 5.0
while time.monotonic() < deadline:
    if proc.poll() is not None:
        return
    time.sleep(0.05)
try:
    os.killpg(proc.pid, signal.SIGKILL)
```

Observable condition: `proc.poll() is not None` (reaped). This is the same
escalate-only-at-deadline shape `_substrate.kill_substrate` already uses
(`proc.wait(timeout=5)`).

## D4 — test/sdk-python/run.sh L50/L56-64, run_ledger.sh L47/L52-58, run_atlas.sh L49/L54-62

Three copies of the same two fixed sleeps:

1. Cleanup: `sleep 1` between TERM and KILL — replace with the D3 pattern
   (bash form, poll `kill -0`):

```bash
for i in $(seq 1 100); do kill -0 -- -$SUB_PID 2>/dev/null || break; sleep 0.05; done
kill -KILL -- -$SUB_PID 2>/dev/null
```

2. Boot wait: fixed `seq 1 60` (run.sh, run_ledger.sh) / `seq 1 600`
   (run_atlas.sh — 10 minutes of fixed ceiling) with 1s `nc` polls and NO
   liveness check on `$SUB_PID` — a substrate that dies on boot makes every
   lane burn the full ceiling before SUBSTRATE_TIMEOUT. Draft:

```bash
deadline=$(( SECONDS + 180 ))
until nc -z 127.0.0.1 "$EGRESS_PORT" 2>/dev/null \
   && nc -z 127.0.0.1 "$AMQP_PORT" 2>/dev/null \
   && nc -z 127.0.0.1 "$EH_PORT" 2>/dev/null; do
  kill -0 "$SUB_PID" 2>/dev/null || {
    echo "SUBSTRATE_DIED rc=? — log: $LOG"; tail -20 "$LOG"; exit 2; }
  [ "$SECONDS" -lt "$deadline" ] || {
    echo "SUBSTRATE_TIMEOUT — log: $LOG"; tail -20 "$LOG"; exit 2; }
  sleep 0.2
done
```

(run_ledger.sh checks only EGRESS_PORT; run.sh checks AMQP+EH+egress — keep
each lane's own port set, change only the loop shape. The `9>&-` on the mix
spawn is load-bearing per same-checkout-fanout law 4 — do not drop it.)

Observable condition: TCP accept on the lane's port set. Typed failures:
`SUBSTRATE_DIED` (kill -0 fails) vs `SUBSTRATE_TIMEOUT` (deadline) — both
exit 2, both print the log tail, matching the repo's exit-code contract
(2 = substrate never up).

## D5 — test/sdk-python/py_auth_keyvault.py L151

Current: `time.sleep(0.5)` after starting the local TLS proxy on 19455,
hoping the listener is bound. Draft — poll the actual socket:

```python
import socket as _socket, time as _time
_dl = _time.monotonic() + 5.0
while _time.monotonic() < _dl:
    try:
        with _socket.create_connection(("127.0.0.1", 19455), timeout=0.25):
            break
    except OSError:
        _time.sleep(0.05)
else:
    raise RuntimeError("local keyvault TLS proxy never bound :19455 within 5s")
```

Observable condition: TLS listener accepts. Typed failure: RuntimeError on
deadline — loud, never a masked connect-refused later in the probe.

## D6 — workspace/scripts/e2e-court.mjs (optional, lowest priority)

Clean today: zero sleeps; leg 3 is probe-once-SKIP. The one gap: if a
substrate is mid-boot when the court runs, the single fetch hits ECONNREFUSED
and the live leg SKIPs spuriously. Optional draft — a short deadline re-probe
before declaring SKIP:

```js
async function armProbeReady(armBase, deadlineMs = 5000) {
  const dl = Date.now() + deadlineMs;
  while (Date.now() < dl) {
    try { return await probeArm(armBase); }        // existing leg-3 fetch logic
    catch (e) {
      if (e.cause?.code !== 'ECONNREFUSED') throw e;   // non-boot errors SKIP now
      await new Promise(r => setTimeout(r, 250));
    }
  }
  return null;                                       // -> SKIP path, unchanged
}
```

Typed: only ECONNREFUSED (boot-class) is retried; any other error SKIPs
immediately. If the maintainers prefer probe-once semantics for the air-gapped
console court, leave as-is — flagged OPTIONAL, not a defect.

## D7 — test/sdk-python/py_servicebus.py L306

Current: `time.sleep(3.5)` after receiving a message under a PT2S lock,
waiting for expiry before a second receive. The 3.5 is a fixed pad over the
2s lock TTL. Draft — poll the observable condition (message re-deliverable)
under a deadline instead of sleeping past a computed wall-clock point:

```python
m2 = []
_dl = time.monotonic() + 10.0
while not m2 and time.monotonic() < _dl:
    with r2_ctx():                       # fresh receiver per attempt
        m2 = r2.receive_messages(max_message_count=5, max_wait_time=1.0)
    if not m2:
        time.sleep(0.2)
assert m2, "lock never expired: no re-delivery within 10s"
```

Caveat (Chicago disjunctive-law note from testing-chicago-style): a lock that
expires on the *server* is the domain mechanism here, and the receive probe
is the only wire-observable witness of it. The draft keeps the PT2S queue
setup intact and only converts the blind pad into a deadline poll; it does
weaken the "lock had actually expired, not merely not-yet-delivered"
distinction, so if the current assert message strings are receipt-cited
elsewhere, prefer the minimal variant: keep `time.sleep(3.5)` →
`time.sleep(2.2)` floor plus deadline poll above it. Flagged for owner
decision; do not apply blind.

---

## Cross-cutting draft: one shared helper, not four copies

D2/D3/D5 and the existing clean code in `_substrate.py` want the same
primitive. Draft (stdlib-only, drop-in beside `_substrate.wait_for_port`):

```python
def wait_until(pred, timeout_s, poll=0.05, fail=None, what="condition"):
    """Poll pred() until truthy or deadline; fail(message) on expiry."""
    if fail is None:
        def fail(message):
            raise RuntimeError(message)
    t0 = time.monotonic()
    while time.monotonic() < t0 + timeout_s:
        if pred():
            return time.monotonic() - t0
        time.sleep(poll)
    fail(f"{what} not observed within {timeout_s}s")
```

`wait_for_port` becomes `wait_until(lambda: port_open(port, conn_timeout),
...)` plus the proc-death check; conftest D2/D3 call it with their own preds;
D5 uses a socket probe. One implementation, one place to tighten poll
granularity later.

## Grounding

Every line number and code block above was read from the frozen tree at
audit time (2026-10-18): `gates/common.py`, `scripts/stress/_substrate.py`,
`gates/test_isolation_leak_gate.py`, `smalt-cli/tests/conftest.py`,
`test/sdk-python/{run.sh,run_ledger.sh,run_atlas.sh,py_auth_keyvault.py,py_servicebus.py}`,
`workspace/scripts/e2e-court.mjs`. No edits, no git commands beyond read-only
`grep`/`sed`/`ls`.
