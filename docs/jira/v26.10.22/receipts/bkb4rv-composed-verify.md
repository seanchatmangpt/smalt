# BK-B4RV — composed verify: BK-B4R fix + BK-B4RC court + b4 harness

- **Standing**: ALIVE — fix + court + harness compose on current HEAD
- **Context**: solo
- **Date**: 2026-10-22 · **Repo**: /Users/sac/smalt · **Lane**: BK-B4RV (read-only verify; only this receipt written)
- Input: `docs/jira/v26.10.22/receipts/bkb4r-sender-link.md` (the fix),
  `docs/jira/v26.10.22/receipts/bkb4rc-send-gate-court.md` (the court)

## Environment pin

Baseline sha256(`lib/smalt/messaging/amqp/queue_store.ex`) =
`a2cc304f76e6f2138e6586be804f2494f2e8dc8314d152b2efcd1fbb6a5013ef` — matches
the B4RC receipt byte-for-byte. All runs on lane build root `_build-bkb4rv`.

## 1. B4RC court fresh — 3/3

```
MIX_BUILD_ROOT=_build-bkb4rv MIX_ENV=test mix test test/internal/b4rc_send_gate_court_test.exs
...
Result: 3 passed
```

## 2. Falsifier independent re-run — court FLIPS (with a sharpening)

Mutation: replace `ensure_entity/1`'s ARM clause **in place** with
`false -> ensure_queue(name) # SHIM-COURT BK-B4RV`, bounded-poll recompile,
rerun:

```
  1) test BK-B4RC leg A: send to an ARM/ATOM-created queue is admitted and delivers
     test/internal/b4rc_send_gate_court_test.exs:41
     match (=) failed
     code:  assert {:ok, _seq} = QueueStore.enqueue(name, "b4rc-arm-payload")
     left:  {:ok, _seq}
     right: {:error, :messaging_entity_not_found}
...
Result: 2/3 passed
Failed: 1 test
```

Leg A flips to the pre-fix refusal exactly as the falsifier demands; the two
KD-86 pin legs stay green. RESTORE byte-exact:
sha256 back to `a2cc304f…13ef` — RESTORE-OK.

**Court sharpening (new finding this lane)**: shim PLACEMENT is load-bearing.
A first attempt inserted `false -> ensure_queue(name)` as the FIRST cond
clause (ahead of the `sb_auto_ensure` clause) and the court stayed 3/3 GREEN
with the shim compiled in (grep-verified) — `ensure_queue/1` auto-creates, so
the misplaced clause routes every send through the auto-create path instead
of the refusal arm. The mutation only flips when it replaces the ARM clause
at its own position, so the cond falls through to
`true -> {:error, :messaging_entity_not_found}`. B4RC's receipt describes the
in-place form; this lane witnessed that the alternative form is a vacuous
mutation. Anyone re-running this falsifier must mutate in place.

## 3. b4 harness end-to-end (provisioning) — exit 0

```
node scripts/bench/b4_messaging_ts.mjs        # self-boots private substrate 39040..39045
2026-10-22T16:07:27.202Z substrate up on ports 39040/.../39045 after 3007ms (pid 15340)
2026-10-22T16:07:27.238Z provisioned queue b4-send-1792685244190 (201)
2026-10-22T16:07:27.241Z provisioned queue b4-rt-1792685244190 (201)
(a) SB send: 2000 msgs in 40s = 50.3 msgs/s p50=0.34ms errs=4 clientRecycles=2
(b) SB round-trip: sent=2000 completed=2000 => 50.7 round-trips/s, p50=421.04ms errs=3
(c) EH producer: 5757 events in 30s = 191.9 events/s p50=4.89ms errs=0 recycles=23
(c) EH rhea wire-tier consumer: received 0 events (seq annotated: 0), sdk subscribe ok=true
B4_EXIT=0
```

Load-typed honestly: same residual as B4R — 4 (a) + 3 (b) fast
`AggregateError` aborts (0.2%, client-recycle idiom), every measured window
delivers its full 2000. Full log at `tmp/bkb4rv/b4_e2e.log`. The canonical
`docs/jira/v26.10.14/bench/b4-messaging-ts.jsonl` the harness overwrote was
restored byte-exact from HEAD (`git show HEAD:…`; `git status` clean;
sha256 `cc1a6caec2d9…40ef`) — verify lane writes no bench artifacts.

## 4. KD-86 original pins fresh

```
MIX_BUILD_ROOT=_build-bkb4rv MIX_ENV=test mix test \
  test/internal/bk27_kd86_auto_ensure_gate_test.exs \
  test/internal/b4rc_send_gate_court_test.exs
Result: 6 passed
```

KD-86 row stands in `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (line 195).

## Standing

ALIVE — BK-B4R's `ensure_entity/1` fix is pinned by a flipping court, the
management-plane admission delivers 2000/2000 sends through the real ARM
provisioning face, and KD-86's original semantics re-pin green. One lane
finding: the falsifier is placement-sensitive (see §2).
