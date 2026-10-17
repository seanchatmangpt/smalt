# r212 — DLQ reason echo + KD-77 residual debris sweep

Standing: ALIVE
Lane: repair (lane335), ownership lib/smalt/messaging/amqp/connection.ex (dead-letter disposition path), smalt-cli/tests/test_dbg_kd77.py (delete), smalt-cli/tests/test_w3_session_ops.py (skip premise text)
Date: 2026-10-16

## Subject

- `lib/smalt/messaging/amqp/connection.ex` (settle/3 :deadletter clause, ~L2224)
- `smalt-cli/tests/test_w3_session_ops.py` (SKIP-KD77-RESIDUAL skip text)
- `smalt-cli/tests/test_dbg_kd77.py` (debris)
- `test/amqp/connection_test.exs:209-211` (compile-freeze SLA unblock fix, disclosed)

## What was found and done

1. **DLQ reason echo (finding 1)**: the dead-letter reason threading fix was
   already present in `connection.ex` on lane start (KD-77 residual clause
   parsing `com.microsoft:dead-letter-reason` / `-error-description` from the
   rejected outcome's described-error info-map at settle/3 :deadletter,
   falling back to "rejected"). Verified rather than re-implemented; no edit
   made. KD-77 delivery-tag vbin encoding untouched.
2. **Debris delete (finding 2)**: `smalt-cli/tests/test_dbg_kd77.py` was
   already absent from the tree (no references anywhere in repo). Nothing to
   delete.
3. **Skip premise text (finding 3)**: `test_w3_session_ops.py` skip already
   carries the honest premise-rot wording (locked survivor invisible until
   lock expiry; real-Azure-consistent; KD-77 divergence itself FIXED).
   Verified loud skip fires with the honest text.

## New edit this lane (disclosed, compile-freeze SLA)

`test/amqp/connection_test.exs:209-211` — stale assertion
`assert {:uuid, <<_::128>>} = tag` predated the landed KD-77 vbin delivery-tag
encoding; replaced with `assert is_binary(tag) and byte_size(tag) == 16`.
Minimal unblock fix to another lane's file, disclosed here under the
same-checkout fan-out SLA. The test comment already described the raw 16-byte
lock token — the assertion was premise rot against the landed encoding.

## Verification (real output)

```
$ cd smalt-cli && .venv-cli/bin/python -m pytest tests/test_servicebus.py -q
4 passed in 27.29s

$ cd smalt-cli && .venv-cli/bin/python -m pytest tests/test_w3_session_ops.py -q -rs
3 passed, 1 skipped in 19.33s   (SKIP-KD77-RESIDUAL, honest premise-rot text)

$ MIX_BUILD_ROOT=_build-lane335 mix test test/amqp/management_rpc_test.exs \
    test/amqp/connection_test.exs --include amqp_wire
50 tests, 0 failures
```

The dead-letter test (`test_servicebus.py::test_dead_letter_with_properties`)
passes: DLQ receive surfaces `dead_letter_reason == "cli5-court"` and
`dead_letter_error_description == "intentional dead-letter probe"` as sent by
the SDK disposition.

Note: the amqp wire run failed 1/50 on lane start
(connection_test.exs:211 stale `{:uuid, _}` assertion vs landed vbin tags) —
introduced by the KD-77 frame_codec landing, repaired this lane as above;
post-fix run is 50/50 green.

## KD

KD-77 residual (DLQ reason echo) is covered by the existing KD-77 row;
register flip is `scripts/kd_flip.py`'s job (witness receipt = this file,
postdates the connection.ex shim).
