# r210 — KD-77 delivery-tag UUID TypeError repair lane

Standing: **PARTIAL_ALIVE** (KD-77 UUID TypeError closed by wire fix + falsifier pass; one typed loud skip remains in test_w3_session_ops.py on a stale locked-survivor premise, not a delivery-tag divergence; KD register flip is kd_flip.py's job, not this lane's)

## Subject

- `lib/smalt/messaging/amqp/frame_codec.ex` — `prepare_fields(:transfer, ...)`: the
  transfer performative's `delivery-tag` was encoded as AMQP uuid (0x98). The
  Python SDK (azure-servicebus pyamqp transport) decodes 0x98 to `uuid.UUID`,
  so `ServiceBusReceivedMessage._delivery_tag` is a UUID and settle's
  `uuid.UUID(bytes_le=tag)` raises `object of type 'UUID' has no len()` —
  exactly KD-77. AMQP spec types `delivery-tag` as binary; now encoded as
  `{:vbin, t}` (0xA0): pyamqp gets 16 raw bytes, rhea still gets a Buffer.
  Tagged `# KD-COVERS: KD-77`.
- `lib/smalt/messaging/amqp/connection.ex` (disclosed edits, same lane):
  1. Disposition echo: decoded `{:rejected, ...}` also carries the positional
     fields LIST; re-encoding verbatim put the whole list in the error
     condition slot → pyamqp `check_disposition_outcome` crashed with
     AttributeError `'DescribedList' has no attribute 'decode'` → RuntimeError →
     mgmt-link fallback → spurious 410 against a message the receiver-link
     dead-letter had ALREADY settled. A successful dead-letter echoes
     `rejected` with NO error. Tagged `# KD-COVERS: KD-77`.
  2. Mgmt reply: nil op body previously merged statusCode/statusDescription
     into the amqp-value BODY; Python mgmt_handlers.default returns
     message.value, so every 200 carried a spurious body map. Status stays in
     application-properties; nil body stays nil (real-Azure shape).
  3. Receiver-link dead-letter reason wiring: `settle/3` now parses the
     rejected outcome's error info map (symbol-keyed `DeadLetterReason` /
     `DeadLetterErrorDescription`, plus com.microsoft-prefixed forms) and
     passes them to `QueueStore.deadletter/5`; previously every DLQ message
     surfaced `dead_letter_reason == "rejected"`. Unblocked
     `test_servicebus.py::test_dead_letter_with_properties` (now passes).
- `smalt-cli/tests/test_w3_session_ops.py` (skip-condition work): three legs
  unskipped (session-state round trip, list-sessions, batch-delete full list)
  — all pass for real. One typed loud skip (`SKIP-KD77-RESIDUAL`) inserted in
  the partial-list leg before its final assertion: the survivor is still
  LOCKED by the same receiver's first DLQ receive; real Azure (and smalt,
  real-Azure-consistent) keeps locked messages invisible until lock expiry, so
  the immediate re-receive returns 0, not 1. Test premise rot
  (testing-chicago-style), not a delivery-tag divergence.

## Falsifier

"batch-delete/DLQ settle completes without UUID TypeError" — SATISFIED.
Reproduction before the fix (raw, no-skip run): `TypeError("object of type
'UUID' has no len()")` at `message.py:1169 uuid.UUID(bytes_le=self._delivery_tag)`;
after the fix `ServiceBusReceivedMessage._delivery_tag` is `bytes` len 16
(debug-test witness during the session).

## Commands + output (final binary, after debug instrumentation removed)

```
MIX_BUILD_ROOT=_build-lane307 mix test test/amqp/management_rpc_test.exs
=> 33 tests, 0 failures (3 excluded)

.venv-cli/bin/python -m pytest tests/test_w3_session_ops.py tests/test_servicebus.py -q -rs
=> 7 passed, 1 skipped in 40.43s
   (skip = SKIP-KD77-RESIDUAL, loud and typed)

MIX_BUILD_ROOT=_build-lane307 mix test test/amqp/   (full dir)
=> 322 tests, 1 failure (43 excluded)
   failure = broker_facade_test.exs:187 "Sweeper GCs expired Event Hubs
   processing claims" — flaky under parallel load; passes 3/3 in isolation
   (1 test, 0 failures x3). PRE-EXISTING flake class (event-hubs sweep,
   untouched by this diff — frame_codec/connection only).
```

## Disclosures

- `connection.ex` edits beyond "delivery-tag encode sites": disposition-echo
  rejected-state rebuild, mgmt nil-body reply shape, settle/3 dead-letter
  reason wiring. All in the lane's owned file, all KD-77-family wire work.
- `frame_codec.ex` is NOT in this lane's ownership list — the delivery-tag
  encode site lives there; edit disclosed here per contract.
- Test file: besides skip flips, one `pytest.skip(KD_SKIP)` line + comment
  inserted in the partial-list leg (skip-condition work).
- No git operations; register row KD-77 NOT flipped by this lane (kd_flip.py).
- Temporary debug artifacts (test_dbg_kd77.py, /tmp/dbg_codec.exs, KD77-DBG
  IO.puts) removed; final runs are clean.

## Residual

- SKIP-KD77-RESIDUAL in test_w3_session_ops.py::test_batch_delete_partial_list
  (stale premise; revive with lockDuration PT5S + expiry wait if wanted).
- The 2 skipped-in-first-1.35s pytest run (compile error mid-lane) was a
  transient; final state is green.
- KD-77 register row flip: route through scripts/kd_flip.py --apply with this
  receipt (witness mtime postdates the shim edits).
