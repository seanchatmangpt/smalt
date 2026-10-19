# External workflow receipt: wf3-messaging-eventing (py)

Workflow: wf3-messaging-eventing
Lang: py
Window: v26.10.19
SUBJECT_SHA: b847c020ee6b0a7ef426e27379f960228932feb0
Profile: primary-tier external suite (official Azure SDKs; surfaces: eventgrid, eventhubs, servicebus, cap:eh-consumergroups, cap:sb-eh-2024-children)
Generated: 2026-10-19T18:45:39.926385+00:00

## Cell tags

eventgrid:test-send20-receive-complete: eventgrid/test-send20-receive-complete PASS
eventhubs:test-send20-receive-complete: eventhubs/test-send20-receive-complete PASS
servicebus:test-send20-receive-complete: servicebus/test-send20-receive-complete PASS
eventgrid:test-lock-lost-pt1s: eventgrid/test-lock-lost-pt1s PASS
eventhubs:test-lock-lost-pt1s: eventhubs/test-lock-lost-pt1s PASS
servicebus:test-lock-lost-pt1s: servicebus/test-lock-lost-pt1s PASS
eventgrid:test-dead-letter-max-delivery: eventgrid/test-dead-letter-max-delivery PASS
eventhubs:test-dead-letter-max-delivery: eventhubs/test-dead-letter-max-delivery PASS
servicebus:test-dead-letter-max-delivery: servicebus/test-dead-letter-max-delivery PASS

## Runner output tail

```
_______ test_challenge_then_crypto_lifecycle _____________________
----------------------------- Captured stdout call -----------------------------
[wf4] KD-14/KD-105 DIVERGENCE RECORDED: vault RS256 sign treats the 'digest' input as a RAW MESSAGE (double-hashes) — real AKV expects a pre-hashed digest; external cryptography.hazmat verification over the digest FAILED rc=1; over the raw message it verifies.
------------------------------ Captured log call -------------------------------
WARNING  azure.keyvault.keys.crypto._client:_client.py:430 Local wrap operation failed: 'str' object has no attribute 'value'
___________________________ test_arm_rate_limit_429 ____________________________
----------------------------- Captured stdout call -----------------------------
[wf5] burst 200 in 0.08s: 20 x 200, 180 x 429 (retry-after=1)
=========================== short test summary info ============================
PASSED test_wf1_governance.py::test_governance_lifecycle
PASSED test_wf2_concurrency.py::test_cosmos_etag_race
PASSED test_wf2_concurrency.py::test_appconfig_race_and_write_conflict
PASSED test_wf2_concurrency.py::test_blob_legal_hold
PASSED test_wf3_messaging.py::test_send20_receive_complete
PASSED test_wf3_messaging.py::test_lock_lost_PT1S
PASSED test_wf3_messaging.py::test_dead_letter_max_delivery
PASSED test_wf4_crypto.py::test_challenge_then_crypto_lifecycle
PASSED test_wf5_throttling.py::test_arm_rate_limit_429
XFAIL test_wf3_messaging.py::test_eventhub_checkpoint_roundtrip - SUBSTRATE_EH_PYAMQP_OPENFRAME_DIVERGENCE: EH Open frame omits locale fields required by azure-eventhub pyamqp — list index out of range
list index out of range
XFAIL test_wf4_crypto.py::test_soft_delete_recover_purge - SUBSTRATE_VAULT_DELETED_STATE_LOST: :smalt_vault_deleted_keys ETS owned by per-request process, no heir — deleted-key bundle 404s across requests (witness GET -> 404, error ResourceNotFoundError)
9 passed, 2 xfailed, 6 warnings in 23.67s
[py-lane] PASS (or honest skips)
```
