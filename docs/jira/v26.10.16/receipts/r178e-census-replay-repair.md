# Receipt — Repair lane R178e: census replay witness (2/11 → 11/11)

Standing: **ALIVE** (census exit 0, 11/11 probes PASS, substrate log clean)

Date: 2026-10-16. Repo: /Users/sac/smalt. Build root: `_build-lane210`.

## Verification

```
MIX_BUILD_ROOT=_build-lane210 SMALT_SDK_ROOT=/Users/sac/smalt/test/sdk-smoke/node_modules \
  scripts/sb_census_replay.sh
# exit 0
#   ✔ probe: authentication ... ✔ probe: deferred-receive
# ℹ pass 12 / fail 0 (11 probes + suite)
# census-substrate.log: 0× :bad_protocol_header, 0× GenServer terminating
```

```
MIX_BUILD_ROOT=_build-lane210 mix test test/amqp --include amqp_wire
# 358 tests, 0 failures
```

## Root causes fixed

1. **Lock-token echo dialect (8× MESSAGE_LOCK_LOST cascade)** —
   `management_rpc.ex`: the 7.10.0 SDK echoes lock tokens in two wire
   dialects. Non-session receivers format the delivered tag straight
   (rhea `uuid_to_string`) and echo the .NET-GUID permuted bytes; session-dialect
   receivers run the tag through `reorderLockToken` first
   (serviceBusMessage.js `shouldReorderLockToken`), so their management echo
   carries the straight bytes of the store key. The old unconditional
   unpermute (`normalize_token/1`) made exactly one family miss the lock
   store on every settle/renew → 410. Fix: `resolve_token/2` — disjunctive,
   store-adjudicated (unpermuted key first, straight-form fallback, only a
   key present in the lock store wins), wired into `renew_each/4` and
   `settle_each/6`.

2. **Deferred receive envelope (DEFERRED_DELIVERY_COUNT)** —
   `management_rpc.ex` + `connection.ex`: the SDK reads deliveryCount from the
   decoded message HEADER section and the settle token from
   `msg["lock-token"]`; the receive-by-sequence reply carried neither. Fix:
   reply now carries `delivery-count` (normalized to an AMQP header section)
   and `lock-token` (AMQP uuid).

3. **KD-45 closed: ATOM+XML management plane on the AMQP port
   (HPE_INVALID_CONSTANT)** — new `lib/smalt/messaging/amqp/atom_bridge.ex`: the
   `ServiceBusAdministrationClient` derives its base URL from the sb://
   endpoint, so admin HTTP PUTs land on the AMQP port. `Smalt.Amqp.Connection`
   sniffs the request line and delegates to `Smalt.Amqp.AtomBridge.serve/2`
   (PUT/GET/DELETE `/{queue}`; queue properties land as an ARM-shaped
   `:smalt_resources` record so `queue_settings/1` reads lockDuration/
   requiresSession). Response XML carries the full required
   QueueDescription shape (12 fields; buildQueue throws on missing).

4. **Session locks ignored the queue's lockDuration** —
   `connection.ex` attach: `session_acquire/2` passed no duration, so every
   session lock rode the 30s default; a PT15S queue's post-expiry re-acquire
   was refused SessionCannotBeLocked (stale-handle probe). Fix: pass
   `duration_ms: QueueStore.queue_settings(address).lock_duration_ms`.

5. **Sweeper crash-loop (bare `LockManager` alias)** — `sweeper.ex`
   `doomed_message_locks/0` called `LockManager.expired?/2` with no
   `alias`/full name → UndefinedFunctionError every 250ms tick, killing the
   broker tree (ECONNREFUSED cascade). Fix: full module name. Disclosed
   minimal unblock of another lane's in-flight edit (compile-freeze SLA).

## Disclosed cross-lane touch

- `test/test_helper.exs` — another lane's mid-flight `defp wait_gone` /
  `def wait_gone` mixed-visibility clauses broke the suite compile; restored
  uniform `def` with a comment (minimal unblock, disclosed here).

## Notes

- `:bad_protocol_header` in the witness was a symptom, not a cause: the two
  teardowns were ATOM admin HTTP PUTs (`"PUT /cen"`) hitting the AMQP header
  negotiation. Now served by the bridge; no AMQP frame-path change needed.
- KD-45 flip is receipt-gated: this receipt postdates the shim (`atom_bridge.ex`
  carries `KD-COVERS: KD-45` via the connection.ex wiring comment);
  `scripts/kd_flip.py --apply` may flip the row.
- Concurrent-lane churn was heavy during this lane (connection.ex/queue_store/
  management_rpc edited in flight several times); the final census + suite run
  on the current tree is the receipt above.
