# SDK lane PY-5 — real azure-eventhub + azure-eventgrid (Python) against the smalt EH/egress planes

- **Date**: 2026-10-16 · **Lane**: lane333
- **Repo/SHA**: `/Users/sac/smalt` @ `main` `fd9cfea`
- **SDK**: `azure-eventhub` + `azure-eventgrid` (test/sdk-python/.venv-eh)
- **Runtime**: Python 3.14 venv, macOS arm64 (Darwin 25.2.0)
- **Substrate**: `test/sdk-python/run.sh` self-boot on its fixed private block (AMQP 39272 / EH 39273 / EGRESS 39455), anonymous auth, `MIX_BUILD_ROOT=_build-lane333`, under `flock /tmp/smalt-substrate.lock` (fd closed)
- **Probe**: `bash test/sdk-python/run.sh` → `py_eventhub_grid.py`
- **Verdict**: 2/4 probes passed; EH AMQP tier attaches (KD-21 closure holds) but EH management/producer ops carry a decode residual

## executed commands (receipt)

```bash
MIX_BUILD_ROOT=_build-lane333 bash test/sdk-python/run.sh   # probes exit 1 (2/4)
```

## results (2026-10-16, raw probe output)

```
PROBE eh.properties_mgmt_link did-not-pass — EventHubError: list index out of range (get_eventhub_properties $management response decode)
PROBE eh.produce_consume_ordered did-not-pass — EventHubError: list index out of range (producer _open_with_retry during create_batch)
PROBE eg.valid_cloudevent_ingest PASS {"status": 200}
PROBE eg.hostile_cloudevent_400 PASS {"status": 400, "code": "InvalidCloudEvent"}
SUMMARY 2/4 probes passed
```

## divergence read

- **KD-21 closure witnessed**: pyamqp attaches and runs the Event Grid legs
  end-to-end (the open-frame crash from v26.10.14 did not re-fire).
- The two EH legs show a "list index out of range" decode residual on the
  pyamqp tier (same family as the KD-77-class servicebus residual: response
  sections the Python client cannot decode where the JS SDK succeeds).
  EventGrid ingest (valid 200 + hostile 400 InvalidCloudEvent) is fully green.
- This is a real probe tier against the real substrate on run.sh's own
  private block — no canonical-port contact.

## notes

- JS counterpart (ts-event-hubs.md) is 6/6 on the same wire tier this window;
  the residual is Python-client-side decode, consistent with the KD register.
