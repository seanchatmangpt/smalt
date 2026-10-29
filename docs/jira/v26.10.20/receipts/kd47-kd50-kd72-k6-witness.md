# K6 SB/EH-face witness + dispositions (lane K6, trapped by ENOSPC, persisted by coordinator 2026-10-21)

**Standing:** PASS
Context: solo

Evidence gathered before machine-wide disk exhaustion; content verbatim from the
K6 lane receipt. Real SDK: @azure/service-bus 7.10 (verification/ts/node_modules
installed by the lane, which also fixed the pre-existing
`SMALT_SDK_ROOT: unbound variable` bug at scripts/dev_env.sh:94).

## KD-47 (SB scheduleMessage) — FLIP-ELIGIBLE

KD-118's shim already covers it: `com.microsoft:schedule-message` /
`cancel-scheduled-message` implemented in
lib/smalt/messaging/amqp/management_rpc.ex (`# KD-COVERS: KD-118`).

```
verification/ts/sb-extra.probe.cjs:
PASS scheduleMessage / PASS receiveAndDelete-delivery /
PASS acceptNextSession-no-session / SUMMARY pass=3 fail=0
```

Honest caveat: harness watchdog later fired on a `client.close()` hang → typed
exit 3; harness-level, not a falsifier failure.

## KD-50 (queue properties readback) — STALE, divergence absent

Private b12 substrate: ARM PUT queue with camelCase `lockDuration: PT2S` → 201;
GET readback camelCase; delivery falsifier PASSED via real SDK
(tmp/k6_sb_sdk.probe.cjs): peek-lock receive → close receiver → 2.6s →
redelivery with deliveryCount 1→2; default-30s control queue does NOT redeliver
at 2.6s. PT2S enforced end-to-end.

**New unregistered finding (candidate KD row):** with the first receiver still
attached (SDK auto-renew disabled), expired locks are never reclaimed — no
redelivery at 2.6s or 31.5s on PT2S and default queues; only link close
restores re-claimability. Subject seam: connection.ex claim path / sweeper.

## KD-72 (session-state ops) — WITNESSED PASS

Real SDK: acceptNextSession on an ARM requiresSession queue,
setSessionState("k6-state-v1") → getSessionState byte-equal, 4 runs.
(Emulator divergence disclosed in code: state dies with the session lock record.)

## KD-73 / KD-74 — implementations exist; wire witness NOT obtained; rows stay OPEN

management_rpc.ex serves get-message-sessions (KD-120 SDK-key fix,
skip/top/since) and batch-delete-messages (sequence-number based — the row's
falsifier text says "lock-token outcomes"; disposition note added, falsifier
not silently re-worded). Raw $management probe hit a SASL handshake-order
deadlock (witnessed twice); economical successor is a ~60-line rhea client
(rhea 3.0.5 in verification/ts/node_modules).

## KD-69 (EH epoch) — row STALE but unwitnessed; stays OPEN

Enforcement already implemented (connection.ex eh_attach_epoch /
eh_epoch_admit, typed EPOCH_EVICTION/EPOCH_REFUSED detaches). Falsifier (two
epoch receivers, epoch-1 evicted) not run — blocked by disk.

## KD-51 (SB admin URL space) — not probed; HEAVY/OPEN

## Operational

- Shared live substrate went DOWN 18:50:37Z from external SIGTERM (substrate.log,
  no shutdown banner) — not this lane. Private block b12 (ports 39120-25,
  MIX_BUILD_ROOT=_build-k6) was booted for witnesses; sweep:
  `bash scripts/substrate-ctl down --block b12 --mode sweep`.
- Scratch probes: tmp/k6_sb_sdk.probe.cjs, tmp/k6_abandon.probe.cjs,
  /tmp/k6_closebefore.probe.cjs, tmp/k6_mgmt.exs, /tmp/k6_dbg.exs, /tmp/k6_key.txt.
