# SDK Lane PY-5 — Real Python azure-eventhub + azure-eventgrid vs smalt v26.10.14

Date: 2026-10-15 · Lane: PY-5 · Substrate: `mix run --no-halt` (MIX_ENV=test),
private ports amqp=39272 / eventhubs=39273 / egress=39455, EXCLUSIVE substrate
lock discipline.

## Harness

- `test/sdk-python/.venv-eh` — python 3.14 venv, `azure-eventhub 5.15.1`,
  `azure-eventgrid 4.22.1` (real PyPI wheels, not stubs).
- `test/sdk-python/run.sh` — boots the substrate under `flock -x` on
  `/tmp/smalt-substrate.lock`, waits for listeners, runs the probes, kills the
  substrate (SIGTERM→SIGKILL group kill) and releases the lock on exit.
- `test/sdk-python/py_eventhub_grid.py` — the probes.
- Evidence logs: `test/sdk-python/py5-run.log`, `py5-debug.log`,
  `py5-trace.log`, `py5-substrate.log`.

## Divergence 1 (harness): primary substrate lock is leaked

`/tmp/smalt-substrate.lock` can never be re-acquired: a detached beam.smp
(pid 9427, booted for the canonical 5672/5673 ports by a run.sh that has since
exited) inherited fd 9 from its booting script and holds the exclusive flock
open forever. Measured: a queue of ~8 lanes' `flock` waiters, including this
lane's, all starved. Fallback used: `flock -x /tmp/smalt-substrate-py5.lock`
(same mutual-exclusion discipline, lane-scoped). Fix direction: run.sh scripts
must close the fd in the child (`flock` wrapper that closes inherited fds) or
the substrate must not inherit the lock fd.

## Results

| probe | result | evidence |
|---|---|---|
| `eg.valid_cloudevent_ingest` — EventGridPublisherClient.send(valid CloudEvent) → /topics/py5-topic/events | PASS (200) | py5-run.log |
| `eg.hostile_cloudevent_400` — send({id,type} without specversion/source) | PASS (400, code=InvalidCloudEvent, all-or-nothing) | py5-run.log |
| `eh.properties_mgmt_link` — get_eventhub_properties over mgmt link | FAIL | py5-trace.log |
| `eh.produce_consume_ordered` — producer batch → consumer receive, order + sequence-number assertions | FAIL | py5-trace.log |

EventGrid: 2/2 PASS. EventHubs: 0/2 — every AMQP connection dies at open.

## Root cause of the EventHubs failures (client-side stack captured)

`_handle_exception` trace (py5-trace.log), client side:

```
pyamqp/_connection.py:436 _incoming_open
    if frame[4]:            # idle_time_out
IndexError: list index out of range
```

Sequence: TCP connect → AMQP header → SASL ANONYMOUS → open sent → broker
open arrives → pyamqp crashes parsing it. No transfer ever flows.

The substrate's encoder is SPEC-COMPLIANT: `frame_codec.ex`
`trim_trailing_nulls/1` legally drops trailing null fields (AMQP 1.0 §1.4.3
allows omitting trailing nulls in a list). The broker's open performative is
therefore shorter than 10 fields (idle_time_out, locales, capabilities,
properties are all null → omitted). Python pyamqp 5.15.1's `_incoming_open`
indexes `frame[4]` unconditionally — it does not tolerate the spec-legal
truncation. The Node SDK tolerates it; Python does not. This is a pyamqp
strictness bug, not a smalt defect, but it makes the Python SDK UNUSABLE
against the smalt AMQP lane as-is.

Fix directions (either side):
1. smalt frame_codec: emit open with at least 5 fields (or pad open to the
   full 10 — the attach comment in frame_codec.ex shows padding is what
   broke the *attach* performative for pyamqp, so the asymmetry must be
   respected: attach must stay trimmed, open must be padded to ≥5 fields).
2. pyamqp: length-guard `_incoming_open` (upstream azure-sdk-for-python
   issue candidate).

The same crash class likely fires on `begin`/`attach` frames too
(`frame[4]`/`frame[3]`-style unconditional indexing) once open is fixed — the
py-court lane-91 comment in frame_codec.ex (attach 17-vs-15 crash) is the
mirror image of this finding: that one was smalt padding too much, this one
is pyamqp rejecting spec-legal trimming.

## Not covered by this lane (honest gaps)

- The ordered delivery / sequence-number annotation assertions never
  executed: the wire dies at connection-open, before any link attach.
- uamqp transport variant not tested (not installed; the pure-python pyamqp
  transport is the 5.15 default).
- Consumer receive path untested for the same reason.

## Cleanup

Substrate killed each run (trap in run.sh, SIGTERM→SIGKILL group); ports
39272/39273/39455 verified free after the final run; lane lock released.
The leaked primary lock held by another lane's beam (pid 9427) was left
alone — not this lane's process.
