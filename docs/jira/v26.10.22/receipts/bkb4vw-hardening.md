# BK-B4VW — B4RC court hardening: both falsifier shapes flip

- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22 · **Repo**: /Users/sac/smalt · **Lane**: BK-B4VW
- Closes the court-sharpening finding in
  `docs/jira/v26.10.22/receipts/bkb4rv-composed-verify.md` §2.

## Environment pin

Baseline sha256(`lib/smalt/messaging/amqp/queue_store.ex`) =
`a2cc304f76e6f2138e6586be804f2494f2e8dc8314d152b2efcd1fbb6a5013ef`
(matches B4RC + B4RV receipts byte-for-byte). Lane build root
`_build-bkb4vw`. Subject: `test/internal/b4rc_send_gate_court_test.exs`
(only file edited; queue_store.ex untouched at HEAD state).

## 0. Correction to the B4RV sharpening finding

Re-derivation on the live source: the B4RV first-clause insertion shape
`false -> ensure_queue(name)` is a **dead clause** — a literal `false` head
never selects in `cond`, so the mutation is behaviorally INERT, not an
auto-create re-route. B4RV's mechanism claim ("routes every send through the
auto-create path") is wrong; the court stayed green because the clause does
nothing, not because ensure_queue auto-creates around it. Corollary: no
behavioral assertion can flip on that literal shape by construction — a
court cannot be hardened against a no-op. I witnessed the inertness directly:
court 3/3 green with the literal shim compiled in (shimmed file sha256
`121c37f6eabda490eefb9fca6f61102bd00b3da1f057a93ff3bd18611a6bdca8`), RESTORE
byte-exact after. The LIVE form of the same insertion (`true ->
ensure_queue(name)` — unconditional auto-create bypass) is the real hazard
shape, and the hardened court flips on it (§3).

## 1. Hardened court fresh — 3/3 ×3

```
for i in 1 2 3; do MIX_BUILD_ROOT=_build-bkb4vw MIX_ENV=test mix test \
  test/internal/b4rc_send_gate_court_test.exs; done
Result: 3 passed   (run 1)
Result: 3 passed   (run 2)
Result: 3 passed   (run 3)
```

Hardening (Chicago: final store state, no mocks/sleeps):
- Leg A now carries the store witness: before the send it snapshots
  `Smalt.Store.keys(:smalt_sb_queues)` and `:smalt_resources`; after the send
  it asserts EXACTLY ONE new lazy row materialized, for the ARM-created name
  and nothing else (`MapSet.difference == [name]`), the ARM record set is
  unchanged by send + dequeue, and a SECOND send still admits and delivers
  (ARM record consulted, not consumed — kills one-shot materialization hacks).
- Leg B now asserts the refusal creates NOTHING in either store (no lazy row,
  no management record). This leg is the M2 flip point.

## 2. M1 falsifier (in-place ARM-clause replacement) — Leg A flips

Shim: `arm_entity?(name) -> ensure_queue(name)` → `false -> ensure_queue(name)`
(in place, `# SHIM-COURT BK-B4VW M1`).

```
  1) test BK-B4RC leg A: send to an ARM/ATOM-created queue is admitted,
     resolves via the ARM record, and delivers
     code:  assert {:ok, _seq} = QueueStore.enqueue(name, "b4rc-arm-payload")
     left:  {:ok, _seq}
     right: {:error, :messaging_entity_not_found}
Result: 2/3 passed
Failed: 1 test
```

## 3. M2 falsifier (unconditional auto-create bypass clause) — Leg B flips

Shim: first clause `true -> ensure_queue(name)` (`# SHIM-COURT BK-B4VW M2`).

```
  1) test BK-B4RC leg B: KD-86 pin holds — flag off refuses never-created
     queue, silent creation in neither store
     code:  assert {:error, :messaging_entity_not_found} =
              QueueStore.enqueue(name, "x")
     left:  {:error, :messaging_entity_not_found}
     right: {:ok, 1}
Result: 2/3 passed
Failed: 1 test
```

Both mutations flip DISTINCT assertions (leg A / leg B), RESTORE byte-exact
back to `a2cc304f…13ef` after each run (verified by sha256 after the final
restore).

**Checkpoint race note**: the coordinator tick 44cfa665 committed the tree
while this lane's literal-M2 shim was mid-window (it snapshotted the shimmed
blob `121c37f6…dca8` into HEAD); the working tree was already restored
byte-exact at that moment. Fix-forward restore landed as commit 767b9b52
(HEAD carries baseline `a2cc304f…13ef`, zero `SHIM-COURT BK-B4VW` markers in
lib/).

## 4. KD-86 pins compose — 6/6

```
MIX_BUILD_ROOT=_build-bkb4vw MIX_ENV=test mix test \
  test/internal/bk27_kd86_auto_ensure_gate_test.exs \
  test/internal/b4rc_send_gate_court_test.exs
Result: 6 passed
```

## Standing

ALIVE — both live mutation shapes flip distinct legs of the hardened court on
fresh runs, the literal `false ->` insertion shape is typed as inert (dead
clause, not a court vacuity), and KD-86's original pins re-pin green. The
task-suggested witness "no new lazy row materialized by the send" was NOT
adopted as written: the BK-B4R fix itself materializes exactly that row on
every ARM-path send, so that assertion would fail on the FIXED code; the
adopted witness (exactly-one new row, ARM record untouched, second send
admits) distinguishes fixed vs bypassed without penalizing the fix.
