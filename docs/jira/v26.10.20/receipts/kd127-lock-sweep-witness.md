# W21-B — KD-127 expired-lock redelivery: broker fix + premise-rot finding

**Standing:** PARTIAL_ALIVE (fix ALIVE with wire+SDK witnesses; the row's original
falsifier text is refuted as premise-rot — see "Premise rot" below; the row
itself is left OPEN for the registrar — flip is receipt-gated via
scripts/kd_flip.py and not this lane's file)

Context: solo

## What landed

`lib/smalt/messaging/amqp/connection.ex` — KD-COVERS: KD-127 — a bounded
in-pump redelivery sweep. When the broker-side Sweeper re-avails an expired
message lock, open connections are not otherwise notified, so a receiver
holding outstanding link credit without ever reflowing (rhea-style streaming
credit windows) never sees the redelivery. The sweep rides the pump's existing
recv-timeout slice (deadline-checked via `next_redeliver_at`; never a
sleep-coordination step — SLEEP-CLASS: POLL-STEP), re-runs
`deliver_available/1`, and re-arms at the SHORTEST lock-duration expiry of the
queues with credit-holding queue links (read from the ARM queue record via
`QueueStore.queue_settings/1`, clamped 250 ms..20 s; idle heartbeat 1 s when no
eligible links). Attached receivers are never dropped: no detach, no
settlement side effects, credit untouched.

`queue_store.ex`/`lock_manager.ex` are byte-identical to HEAD in the final
tree (instrumentation added during diagnosis was fully stripped; see
"Disclosures").

## Mechanism (witnessed, pre-fix)

Instrumented live substrate (block b21, ports 39210-39215, private beam,
`MIX_BUILD_ROOT=_build-w21b`):

- The store-side sweep IS correct: `QueueStore.do_sweep/0` re-avails the
  expired row to `:available` ~250 ms past PT2S expiry (traced live:
  `DBG-SWEEP rows=[{1, :available, nil}]` while the receiver held the
  delivery).
- The gap was delivery-path: `deliver_available/1` ran only on inbound `:flow`
  and on the enqueue path. A credit-holding receiver gets no :flow after its
  initial window is granted, so the re-availed message sat undelivered until
  the client reflowed or re-attached — "only link close restores
  re-claimability", exactly the K6 shape.
- Second, separate finding (witnessed live): `handle_disposition` deliverable
  matching is id-indexed into `outbound_deliveries` per connection, so a
  reflow on ANY credit-holding link can claim and deliver the re-availed
  message to the WRONG link (rhea leg B pre-fix: fresh rx2 starves while the
  transfer went to the idle first receiver). AMQP-wise any-credit delivery is
  legal; real Service Bus delivers to the requester. Not fixed here (no KD
  row minted — not this lane's file); flagged for the registrar.

## Premise rot (KD-127's original falsifier text is refuted)

The row's premise "expired locks are never reclaimed while the first receiver
stays attached — no redelivery at 2.6s/31.5s" does not survive a correct
client:

- `@azure/service-bus` 7.10's receiver option is
  **`maxAutoLockRenewalDurationInMs`**. The K6 probe (tmp/k6_sb_sdk.probe.cjs)
  passed `maxAutoRenewDurationInMs` — NOT an option — which the SDK silently
  ignores, so auto-renew ran at its 5-minute default. The lock was being
  renewed every 1 s (traced: DBG-RENEW every ~1000 ms) for as long as the
  receiver lived; "only link close restores re-claimability" is exactly "close
  stops the client's renew timer".
- Also witnessed: `maxAutoRenewDurationInMs: 0` would be falsy-coerced to the
  default even as a real option; `1` disables.
- With the option named correctly (probe: tmp/kd127_sb_sdk.probe.cjs), the
  pre-fix broker ALREADY redelivers to the attached receiver on its next
  `receiveMessages` (the SDK reflows per batch call). Shown by
  SHIM-COURT-eligible pair: sweep shimmed out (deadline frozen at 9.9e15,
  marker `SHIM-COURT KD-127: sweep disabled` in a checkpointed intermediate
  tree) → SDK falsifier still PASS (premise refuted), rhea streaming leg FAIL
  (real residual gap).

## Witnesses (final tree, block b21)

Block boot:
```
bash scripts/substrate-ctl up --block b21 --auth enforce
{"block":"b21","ports":[39210,39211,39212,39213,39214,39215],...,"auth":"enforce"}
```

Real-SDK falsifier (PT2S queue via ARM PUT, peekLock,
`maxAutoLockRenewalDurationInMs: 1`, receiver attached past expiry):
```
node tmp/kd127_sb_sdk.probe.cjs   (SMALT_KD127_BLOCK=b21)
  first delivery: id=kd127-m1 deliveryCount=1
  redelivery: id=kd127-m1 deliveryCount=2
PASS KD-127 redelivery with receiver attached (PT2S, deliveryCount 1->2)
KD127_SDK SUMMARY pass=1 fail=0
```

Raw-rhea wire falsifier (verification/ts/kd127.probe.cjs; CBS put-token,
ARM PT2S queue, streaming receiver holds credit without reflow):
```
SMALT_KD127_BLOCK=b21 node verification/ts/kd127.probe.cjs
first delivery to rx: {"id":"kd127-m1","tag":"..."}
PASS KD-127 leg A redelivery on attached rx (no header dc)
PASS KD-127 leg B redelivery on fresh rx2 while rx attached (dc=undefined)
KD127 SUMMARY pass=2 fail=0
```

BEFORE pair (same probes, sweep disabled via the frozen-deadline shim):
- SDK probe: PASS (premise-rot evidence — the falsifier's claim needs no fix
  when the client reflows).
- rhea streaming probe: `FAIL KD-127 leg B redelivery on fresh rx2 while rx
  attached: no transfer within 5s` (leg A reflows, so it passes pre-fix; the
  no-reflow starves). Post-fix both legs PASS. Honest note: the leg-B
  pre-fix failure is the wrong-link delivery-ordering finding above, not
  purely the missing sweep; the cleanest sweep witness is the SDK streaming
  receiver class (rhea credit-window holder, leg A of the credit-window
  probe form), which failed pre-fix repeatedly during this lane's
  first-generation runs (honestly marked polluted-by-probe-defect:
  rhea's default `autoaccept` completed the message instantly — earlier
  "before" outputs of that form are retracted).

Retracted evidence: the lane's earliest falsifier runs (both SDK and rhea)
were polluted (ignored-option auto-renew; rhea default autoaccept). The
receipt's standing claims rest only on the final-tree witnesses above.

## Test gate

`MIX_BUILD_ROOT=_build-w21b mix test --include amqp_wire` (full offline suite
on the private build root): 200 tests, 10 failures — ALL on foreign surfaces
(internal-tier census fence counting OTHER lanes' in-flight files
kd128_partition_readout_test.exs / cosmos_kd65_scripts_test.exs; cosmos
analytical-TTL undefined-fn; cluster two-node join). Zero failures on
connection/queue_store/lock_manager surfaces; the worktree diff vs HEAD is
debug-strip hunks only. sb_topic_fanout_test.exs: 5/5 PASS.

## Disclosures

- Compile-freeze disclosure: none (no cross-lane unblock fixes applied).
- Checkpoint sweep disclosure: another lane's checkpoint commits (ab348ff,
  4c26019) swept this lane's IN-FLIGHT connection.ex (with DBG prints and the
  fix) into HEAD. The final worktree carries the debug-free version; the
  remaining diff vs HEAD is the debug-strip hunks. Receipt-cited counts here
  are re-read from this file at use time.
- The rhea probe (verification/ts/kd127.probe.cjs) is NEW in this lane
  (uncommitted); tmp/kd127_sb_sdk.probe.cjs likewise. Both self-provision
  their PT2S queue via ARM and read the block's boot marker for ports/key.
- b21 block is swept (substrate-ctl down --mode sweep) after the final runs.
