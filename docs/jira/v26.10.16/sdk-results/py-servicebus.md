# SDK lane PY-4 — real azure-servicebus (Python/pyamqp) against the smalt Service Bus plane

- **Date**: 2026-10-16 · **Lane**: lane333
- **Repo/SHA**: `/Users/sac/smalt` @ `main` `fd9cfea`
- **SDK**: `azure-servicebus` (test/sdk-python/.venv-sb)
- **Runtime**: Python 3.14 venv, macOS arm64 (Darwin 25.2.0)
- **Substrate**: lane333 persistent substrate, anonymous auth, AMQP 39798 / ARM 39796, provisioning via the ARM queue surface (`Microsoft.ServiceBus/namespaces/{ns}/queues`), `MIX_BUILD_ROOT=_build-lane333`, under `flock /tmp/smalt-substrate.lock` (fd closed)
- **Probe**: `test/sdk-python/py_servicebus.py` with `SMALT_PY_AMQP_PORT=39798 SMALT_PY_ARM_PORT=39796 SMALT_PY_ARM_TLS_PORT=39800 SMALT_SB_SHARED_KEY=...`
- **Verdict**: 2/7 probes passed; the pyamqp-tier residual signature re-witnessed (KD-77 class; KD-49 attach-echo closure holds — the link attaches, CBS opens, probes reach their scenario)

## executed commands (receipt)

```bash
SMALT_PY_AMQP_PORT=39798 SMALT_PY_ARM_PORT=39796 SMALT_PY_ARM_TLS_PORT=39800 \
SMALT_SB_SHARED_KEY="$KEY" \
  test/sdk-python/.venv-sb/bin/python test/sdk-python/py_servicebus.py   # exit 1
```

## results (2026-10-16, raw probe output)

```
PASS  abandon_requeues — abandon re-delivered, delivery_count incremented to 2
PASS  defer_receive_by_sequence — defer + receive_deferred_messages(seq=1) + complete
did-not-pass  send_receive_batch_complete (90.0s) — TypeError: Parameter 'message' must be of type ServiceBusReceivedMessage
did-not-pass  peek (90.0s) — AssertionError: peek is destructive: 0
did-not-pass  dead_letter_surface (90.0s) — TypeError: Parameter 'message' must be of type ServiceBusReceivedMessage
did-not-pass  session_roundtrip (90.0s) — AssertionError
did-not-pass  lock_expiry_PT2S (90.0s) — lock never expired: second receiver got nothing
TOTAL 2/7 PASS
```

## divergence read

- The two green probes exercise defer/abandon + ARM provisioning; the five
  that did not pass carry the KD-77-class delivery-tag/received-message
  decode signature (received-message construction fails mid-batch; 90 s
  budgets burned by the retry ladder). KD-49 (attach echo) closure HOLDS —
  the earlier attach/detach/CBS-open failure signature did not re-fire.
- KD-50 (lockDuration readback / lock-expiry path) re-witnessed:
  lock_expiry_PT2S got no redelivery after expiry.
- KD-51 (Python admin client URL space) unchanged — provisioning stays on
  the plain-requests ARM route (documented probe pattern).

## notes

- No lib/ edits by this lane. pyamqp tier attaches and settles on the
  lane333 substrate; residuals are decode/semantic-tier, tracked in the
  register.
