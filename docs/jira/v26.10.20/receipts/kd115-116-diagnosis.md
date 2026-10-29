# Receipt — KD-115/KD-116 diagnosis + KD-115 surgical fix

**Standing:** **PARTIAL_ALIVE** — KD-115 root cause witnessed, surgical fix
landed, non-vacuity court flipped the fix (post-fix 3/3, revert-shim 0/3,
byte-exact restore). KD-116 shown to be probe premise rot at the wire level
(settlement works). Register rows NOT flipped here: flip is kd_flip.py
receipt-gated and coordinator-owned.
Context: solo
Lane: W13-J (substrate-op + writer)
Date: 2026-10-21
Subject: smalt working tree @ 934d21a + the kd115 fix hunk in connection.ex
Build isolation: MIX_BUILD_ROOT=_build-w13j; private beams on 39170-39175
(w13j block) and substrate-ctl block b13 for the probe; the shared substrate
was never touched.

## 1. KD-115 root cause (witnessed)

deliver_available/1 ran ONLY on the :flow path. Pre-fix call-site census
(verbatim):

```
$ grep -n "deliver_available" lib/smalt/messaging/amqp/connection.ex
497:    deliver_available(state)      # <- only call site (handle_amqp(:flow,...))
1998:  defp deliver_available(state) do
```

Mechanism: a receiver whose credit flow precedes the message starves
forever — the enqueue never re-runs the dispatch and nothing else will.
Reproduced on TWO independent real clients.

rhea 3.0.5 (repo-local node_modules), receive-first (attach+flow BEFORE send):

```
$ node tmp/w13j/probe3.mjs w13j-fix2
receive-first got: 0
```

real @azure/service-bus 7.10 streaming receiver (subscribe, credit-first):

```
$ node tmp/w13j/sdk_stream.cjs
streaming received after credit-first + send: 0
```

The wf3 sb-send20-receive-complete 0/20 cell (KD-115's original evidence) is
this mechanism: the SDK receiver link is credited before the sends land.

## 2. Fix

lib/smalt/messaging/amqp/connection.ex, queue-ingest tail (inside
ingest_message/4, the {:ok, state} arm after the accepted-echo):

    state = deliver_available(state)

plus the KD-COVERS: KD-115 comment block. The rebind is load-bearing: an
unrebound statement-form call leaked the session next_out counter and caused
a rhea "frame sequence error: expected 2, got 1" delivery-id reuse — caught
and fixed within the session.

## 3. Non-vacuity court (fix -> revert shim -> restore)

Probe: verification/ts/kd115.probe.cjs (boots private substrate block b13
via scripts/substrate-ctl, sweeps at exit; KD115_AMQP_PORT override for a
direct-port court). Verbatim outputs, all witnessed 2026-10-21:

POST-FIX (full standalone run, boots b13):

    $ node verification/ts/kd115.probe.cjs
    PASS plain-credit-first: received 3/3 (credit-first, no reflow)
    PASS session-credit-first: received 3/3 (credit-first, no reflow)
    PASS kd116-session-settle: settled 3/3, re-receive 0 (expect 0)

SHIM (fix hunk replaced by "# SHIM-COURT: KD-115 fix reverted (pre-fix
state)", private beam rebuilt on 39170-39175):

    FAIL plain-credit-first: received 0/3 (credit-first, no reflow)
    FAIL session-credit-first: received 0/3 (credit-first, no reflow)

RESTORE (sha256 byte-exact):

    $ sha256sum -c tmp/w13j/fixed.sha
    lib/smalt/messaging/amqp/connection.ex: OK

## 4. KD-116 disposition: probe premise rot; wire settlement works

KD-116's evidence predicate was "deliveries lack settle methods"
(typeof m.complete === 'function') — that reads @azure/service-bus v6 API
shape into v7.10. In v7 settlement lives on the receiver, not the message:

    $ grep -n "async completeMessage" verification/ts/node_modules/@azure/service-bus/dist/commonjs/receivers/receiver.js
    249:  async completeMessage(message) {

Settlement over the wire is NOT divergent — witnessed twice:

    real SDK (plain): receiver.completeMessage resolved;
    rhea settle leg: 3/3 accepted, re-receive after accept = 0 (message gone)

(verdict line: "PASS kd116-session-settle: settled 3/3, re-receive 0").
Typed suggestion for the register row: close with the divergence re-typed to
"probe assertion premise rot (v6 API shape)" and the close condition
re-pointed at the kd116-session-settle leg of verification/ts/kd115.probe.cjs
(receiver.completeMessage settles + re-receive empty). Flip remains
coordinator-gated via scripts/kd_flip.py.

## 5. Remaining scope (HEAVY, not landed)

Cross-connection dispatch: deliver_available/1 dispatches only the LINKS OF
THE INGESTING CONNECTION. A sender on connection A and a credited receiver
on connection B still starve (witnessed: two pure-Elixir wire clients,
rx credited first, tx sends on a second socket — rx timed out). Real
ServiceBusClient instances share ONE connection, so the SDK surface is
covered by the landed fix; the cross-connection surface needs a store-level
notify (e.g. QueueStore enqueue hooking a dispatch registry of connection
processes) — deliberately NOT improvised here; that is a real-SDK-lane
iteration with a two-connection wire falsifier.

## 6. Files touched / cross-lane notes

- lib/smalt/messaging/amqp/connection.ex — the fix hunk above (my only lib edit).
- verification/ts/kd115.probe.cjs — NEW probe (3 legs, b13 private block,
  swept at exit).
- test/internal/kd115_credit_first_delivery_test.exs — NEW internal-tier
  gate wrapping the probe (loud [SKIP] when node is absent; asserts all
  three PASS lines).
- test/internal/internal_tier_census_test.exs — @owned_files registration
  of the new test file (census fence; my file introduces no violations).
- tmp/w13j/* — scratch probes + fixed.sha (gitignored scratch, kept for
  replay).

Cross-lane compile-freeze events this session (both self-resolved by their
owners mid-session, NO edits from this lane): lib/smalt/application.ex:47
(transient SyntaxError then nil-child boot crash; owner added `else []`) and
lib/smalt/auth/shared_key.ex:69 (transient missing-end during probe b13
boot; owner fixed). test/internal census remains RED on master for OTHER
lanes' unregistered in-flight files (cosmos_kd65_scripts_test.exs,
kd128_partition_readout_test.exs — unregistered + status-literal fence
violations) and 4 cosmos TTL failures — pre-existing, not this lane's.

## 7. Replay

    MIX_BUILD_ROOT=_build-w13j MIX_ENV=test mix test test/internal/kd115_credit_first_delivery_test.exs
    node verification/ts/kd115.probe.cjs
    # direct-port court against a running private substrate:
    KD115_AMQP_PORT=<port> KD115_SHARED_KEY=<key> node verification/ts/kd115.probe.cjs
