# KD-127 Post-Shim Witness 2 (B-K3, mtime cure)

- **Standing: PASS**
- Date: 2026-10-21 10:19–10:24 PDT
- Subject: `/Users/sac/smalt` @ branch `main`, HEAD `63b42c7` (committed tree; this lane made no lib edits, no git ops)
- Shim: `lib/smalt/messaging/amqp/connection.ex` carries `# KD-COVERS: KD-127` — the bounded in-pump redelivery sweep (`deliver_available/1` re-run on the pump's recv-timeout slice, `next_redeliver_at` deadline-checked, SLEEP-CLASS: POLL-STEP)
- Shim mtime: **2026-10-21 00:38:49** (`stat connection.ex` re-read this lane, 10:04 PDT) — both falsifier artifacts below (10:19–10:24 PDT) postdate it, curing the receipt-predates-shim condition on `kd127-lock-sweep-witness.md` (Oct 20 23:46) for the `kd_flip.py --apply` gate.
- Toolchain: host asdf pin `elixir 1.20.3-otp-28`; private beam booted from the current tree via `scripts/substrate-ctl` (block b43, ports 39430–39435, auth enforce). Shared substrate untouched (still UP, pid 9849).

## Leg 1 — raw-rhea streaming falsifier (boots block b43 --fresh)

Command: `SMALT_KD127_BLOCK=b43 node verification/ts/kd127.probe.cjs`

```
block b43 AMQP 39430 ARM 39432; PT2S queue kd127-q
CBS put-token OK
first delivery to rx: {"id":"kd127-m1","tag":"1a897cbfeac3f645b112646483a8f882"}
PASS KD-127 leg A redelivery on attached rx (no header dc)
PASS KD-127 leg B redelivery on fresh rx2 while rx attached (dc=undefined)
KD127 SUMMARY pass=2 fail=0
EXIT=0
```

## Leg 2 — real-SDK falsifier (@azure/service-bus 7.10, same block via marker)

Command: `SMALT_KD127_BLOCK=b43 SMALT_KD127_NOBOOT=1 node tmp/kd127_sb_sdk.probe.cjs`
(PT2S queue via ARM PUT, peekLock, `maxAutoLockRenewalDurationInMs: 1`, receiver attached past expiry)

```
  first delivery: id=kd127-m1 deliveryCount=1
  redelivery: id=kd127-m1 deliveryCount=2
PASS KD-127 redelivery with receiver attached (PT2S, deliveryCount 1->2)
KD127_SDK SUMMARY pass=1 fail=0
EXIT=0
```

## Sweep

`bash scripts/substrate-ctl down --block b43 --mode sweep` run post-witness; ports 39430/39431/39432/39435 verified with no LISTEN sockets afterward.

## Disclosures (honest log)

- Compile-freeze window 10:06–10:09 PDT (concurrent lane's in-flight
  `egress_router.ex`/`blob_error.ex` break, healed by its owner before these
  runs) is receipted in `kd115-post-shim-witness2.md`; the b43 private beam
  booted from the post-heal tree.
- The KD-127 row's premise-rot finding (ignored-option auto-renew in the K6
  probe form) stands as receipted in `kd127-lock-sweep-witness.md`; this lane
  re-observed only the final-tree witnesses, it did not re-run the
  sweep-disabled SHIM pair.
- Prior receipt not superseded on findings — fresh mtime-cured re-witness of
  the same two falsifiers on the current committed tree.
- Flip NOT performed (witness-only lane; flip belongs to `kd_flip.py --apply`).
