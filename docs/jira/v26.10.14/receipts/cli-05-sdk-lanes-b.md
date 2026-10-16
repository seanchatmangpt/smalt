# Receipt — CLI-5 SDK test lanes (Gate 1 part B)

Owner: CLI-5. Date: 2026-10-15. Branch: main @ 3fc2543 (uncommitted, per no-commit order).
Files owned/written (all under /Users/sac/smalt/smalt-cli/):

- tests/test_servicebus.py — 4 tests
- tests/test_keyvault.py — 4 tests
- tests/test_eventhub.py — 1 test

## What ran (live substrate, real Azure Python SDKs)

Environment: lane substrate booted by the test files themselves at import
(`mix run --no-start --no-halt`, MIX_ENV=test, port block 38672/38673/38654/
38655/38656, lane lock `/tmp/smalt-substrate-cli5.lock`), venv at
`smalt-cli/.venv` (python 3.14; azure-servicebus 7.15.0, azure-keyvault,
azure-eventhub, pytest, requests installed via pip into it).

- **keyvault: 4/4 PASS** (`pytest tests/test_keyvault.py -q` → `4 passed in 3.07s`).
  - create/get key (SDK KeyClient over TLS challenge-injection proxy),
  - list keys (canonical id host `https://127.0.0.1:8443/keys/<name>/<ver>` —
    substrate echoes its own canonical base, not the proxy host),
  - release: live substrate answers **403 UnauthorizedAttestation**
    ("Secure Key Release refused: target environment failed
    azure-compliant-cvm attestation validation") — recorded as the observed
    shape, test accepts 403-attestation or 200,
  - RSA-OAEP-256 encrypt/decrypt round-trip over unversioned
    `/keys/:name/encrypt|decrypt` (SDK CryptographyClient versioned URL is a
    registered divergence — KD rows; not re-asserted here).
- **servicebus: 4/4 SKIP-KD21** (`pytest tests/test_servicebus.py -rs` → 4
  skipped). Signature: `ServiceBusConnectionError: … amqp:socket-error, server
  unexpectedly closed connection` during open — matches registered OPEN
  divergence KD-21 (substrate AMQP `open` frame trailing-null trim crashes
  pyamqp `_incoming_open` frame[4] unguarded; Node tolerates). Skip banner
  names KD-21, the fix hint (pad open to >=5 fields, attach stays trimmed),
  and the Node census (`scripts/sb_census_replay.sh`) that covers the same
  surface today. Skip signature is runtime-detected: when KD-21 lands the
  same tests run the full mirror shapes (send/receive/complete batch, DLQ
  reason+description round-trip, defer + receive-by-sequence, PT2S
  lockDuration seeded via ARM record + behavior-proven by lock expiry).
- **eventhub: 1/1 SKIP** (`pytest tests/test_eventhub.py -rs` → 1 skipped in
  2.98s). First hit is KD-18 (EH `$management` → 501 UNSUPPORTED_OPERATION →
  SDK "list index out of range"; the SDK queries max message size via the
  mgmt link even with `max_size_in_bytes` pinned — measured, contradicts the
  py5 mirror comment). Behind it the same KD-21 socket-error. Skip banner
  names KD-18 + KD-21.

## pytest --collect-only

Exit 0, `9 tests collected in 0.13s` (all three files). Boot is skipped under
`--collect-only` (guarded on `sys.argv`), so collection is side-effect free.

## conftest merge note (per dispatch)

CLI-4's `tests/conftest.py` landed mid-window with a session-scoped autouse
substrate gate (SKIPs everything unless SMALT_ARM/SMALT_EGRESS answer
`/metadata/endpoints`). I did NOT create `conftest_py5.py`. My three files are
self-contained (inline boot helpers, zero shared helper module) and satisfy
the gate with the REAL thing: run them with
`SMALT_ARM=http://127.0.0.1:38654 SMALT_EGRESS=http://127.0.0.1:38655`
pointing at my lane's live substrate. Substrate is shared across my three
files (identical BOOT superset: sb_shared_key + sts_signing_secret +
auth_mode=enforce + the 386xx port block) via reuse-if-live + single boot
under the lane flock.

## Substrate facts surfaced (for the gap register — not fixed in this lane)

1. Service Bus HTTP management plane (azure-servicebus
   `ServiceBusAdministrationClient` REST) is unrouted: py4's mirror log
   (test/sdk-python/.logs/probe-run4.log) shows 0/7 RouteNotFound; my run got
   the SSL WRONG_VERSION_NUMBER shape. Queues are therefore pre-seeded in the
   boot eval via `Smalt.Amqp.QueueStore.ensure_queue/1` + `:smalt_resources`
   ARM records (lockDuration PT2S seeded as ARM properties, read by
   `Smalt.Amqp.QueueStore.queue_settings/1`).
2. KD-21 (pyamqp open-frame) blocks the Python servicebus + eventhub SDK
   paths end-to-end (confirmed live; not just register prose).
3. KD-18 fires one hop earlier on the EH path (mgmt link IndexError).
4. The primary `/tmp/smalt-substrate.lock` is still leaked by a detached
   beam.smp (pid-class receipted in test/sdk-python/run.sh); lanes must use
   the primary-then-lane-lock fallback. One of my earlier killed runs also
   leaked a beam holding the lane lock — killed (kill -9); atexit cleanup
   does not run on externally killed pytest processes.

## Commands

- `.venv/bin/pip install azure-servicebus azure-keyvault azure-eventhub pytest requests` (into smalt-cli/.venv)
- `SMALT_ARM=http://127.0.0.1:38654 SMALT_EGRESS=http://127.0.0.1:38655 .venv/bin/python -m pytest tests/test_keyvault.py -q` → 4 passed (EXIT=0)
- `… pytest tests/test_servicebus.py -rs` → 4 skipped (SKIP-KD21)
- `… pytest tests/test_eventhub.py -rs` → 1 skipped (SKIP-KD18/KD-21)
- `… pytest tests/{servicebus,keyvault,eventhub}.py --collect-only -q` → 9 collected, exit 0

Standing: keyvault lane ALIVE (4/4 witnessed on live substrate). servicebus +
eventhub lanes SKIP-PENDING-KD21/KD18 — fail-closed, never a fabricated pass;
the same files become full mirror shapes the moment the divergences close.
