# AMQP10-F4 — crash-only AMQP 1.0 router finisher (fifth pass)

Context: solo

Date: 2026-10-21 · Lane: AMQP10-F4 · Repo: /Users/sac/smalt
Toolchain: OTP 29.1.2 / Elixir 1.20.4-otp-29, `MIX_BUILD_ROOT=_build-a10f4`
**Standing:** **PARTIAL_ALIVE — crash-only court 6/6 green ×4; skeptic court 6/7 (one documented premise-rot leg, coordinator arbitration item)**

## Method (per dispatch)

F3's finding was that the crash was invisible because exits weren't traced.
This pass traced `[:send, :'receive']` on the live session/link pair during a
court-3 reproduction and dumped the loaded beam's abstract code
(`:code.which` + `:beam_lib.chunks(..., [:abstract_code])`) for
`Smalt.Amqp10.Link`:

```
T session :receive {:amqp10_frame, {:transfer, %{handle: 0, delivery_id: 7, settled: true, ...}}, "..."}
T5 session :send {:amqp10_frame, {:transfer, %{...}}, ...} -> link
T link :receive {:amqp10_frame, {:transfer, %{...}}, "..."}     # then: nothing
LINK-CATCHALL {:amqp10_frame, {:transfer, ...}}                  # instrumented link
```

The link received the transfer and produced zero sends and zero ETS rows while
staying alive — matched by the instrumented catch-all, never by the transfer
clause. A standalone `case` on the identical message matched the identical
pattern. Decisive evidence: the compiled receive clause's abstract code —
outer tuple of arity 2 whose second element is a 3-tuple
`{:transfer, %{} = _f, payload}` (payload NESTED in the inner tuple):

```
{:tuple, [{:atom, :amqp10_frame}, {:tuple, [{:atom, :transfer}, match, var]}]}
# clause arity: {:amqp10_frame, {:transfer, _f, payload}}  (payload INNER)
# routed:    {:amqp10_frame, {:transfer, fields}, payload} (payload OUTER)
```

while Connection/Session route `{:amqp10_frame, frame.performative, frame.payload}`
(2-tuple performative, payload as outer third element). F3's suspicion was
right in kind: no process ever crashed — the message fell through to the
catch-all and vanished.

## Root causes fixed (all in `lib/smalt/messaging/amqp10/`)

1. **Link message-shape mismatch (the invisible loss)** — `amqp10_link.ex`:
   receive clauses matched `{:amqp10_frame, {:transfer, fields, payload}}`
   (payload nested in the inner 3-tuple) against routed
   `{:amqp10_frame, {name, fields}, payload}`. Every transfer fell to the
   catch-all (previously a silent swallow). Fixed clauses to the routed shape.
2. **Silent catch-all removed** — the link's `_other -> loop(opts)` swallow is
   now a typed exit `{:amqp10_bad_internal_message, other}` → cascade
   (crash-only law: an unmatched internal routing message is a defect, not
   noise). This makes any future shape drift crash loudly instead of vanishing.
3. **`{:amqp10_tx, ...}` send-failure handling** — `amqp10_connection.ex`
   `handle_info({:amqp10_tx, ...})` had a `case` with only a `:ok` clause; a
   send on a dying socket was a FunctionClause crash. Now
   `{:error, reason} -> {:stop, {:transport_closed, reason}, state}` (RST race
   handled per the transport-death law). (Pending-fix #1 from dispatch.)
4. **Credit enforcement (SK3's audited law)** — the link previously
   dispositioned unboundedly. Now: single 100-credit grant on attach flow, one
   credit per settled transfer, exhaustion = typed exit
   `{:amqp10_link_credit_exhausted, handle, id}` → cascade. Measured: SK3
   dispositions=100/105, ets_rows=100, replenishing_flows=0.
5. **Settled-ledger lifetime defect** — `:amqp10_settled` was owned by an
   arbitrary connection process; it evaporated whenever its accidental owner
   died (SK3's post-cascade `:ets.member` hit "table does not exist"). The
   ledger is now owned by a dedicated unlinked holder process
   (`{Smalt.Amqp10.Connection, :settled_ledger_holder}` label); connection
   crashes never propagate to it; lazily re-created if the holder dies.
6. **FrameDecoder raise on valid remote input** — `positional_fields/2` did
   `list ++ pad` with `nil` (list0 bodies decode to nil) → `argument error` on
   `<<0, 0x53, 0x17, 0x40>>`-shaped `end` frames. `List.wrap(list)` fix;
   all SK2b bodies now `{:ok, _}`.

## Court harness fix (test-side, disclosed)

`collect_downs/3` returned only elapsed; the caller's `refset` was never
rebound, so `assert MapSet.size(refset) == 0` read the STALE original set —
court 1 read as "cascade incomplete (left: 3)" while the measured cascade was
**0 ms** (clone run: all three DOWNs at 0 ms). Legs 1–2 now rebind
`{elapsed, remaining}` and additionally assert full-tree death (leg 2 gained
the size==0 assertion). Not a weakening: the timing fence (10 ms) is intact
and correctness is now actually asserted against live data.

## Results

```
MIX_BUILD_ROOT=_build-a10f4 mix test test/integration/amqp10_crash_only_court_test.exs
Result: 6 passed   (×4 consecutive runs)
```

```
MIX_BUILD_ROOT=_build-a10f4 mix test test/integration/amqp10_skeptic_court.exs
Result: 6/7 passed (×3 consecutive runs)
  [SK1] root-kill cascade: 0ms, 3 pids
  [SK1b] RST cascade: 0ms, 3 pids
  [SK3] dispositions=100/105 replenishing_flows=0 ets_rows=100
  [SK4] 10/10 random mid-header/mid-body splits ok
  [SK2b] all bodies {:ok, _} (end_nil_value / list0_end / accepted_disposition)
  SK5: FAIL — see arbitration item
```

## Arbitration item (reported, not unilaterally rewritten)

**SK5 premise rot**: SK5 pins `after_size - before == 2_000` — unlimited
transfer storage — while SK3's audited law (claim 3: single 100-credit grant,
no replenishment, enforcement observed) caps stored+dispositioned transfers at
100 per link. The two skeptic legs are mutually exclusive for an alive,
credit-enforcing transfer path; SK5's 2000-row pin was authored against the
pre-fix subject whose transfer path was DEAD (silent catch-all swallow). The
credit law is the dispatched audit plan's claim 3; I implemented it and report
SK5 as the casualty. Rewriting SK5's assertion is coordinator work — the fix
is one line (assert the enforced 100-row boundary instead of 2000) but it
flips a pinned court assertion and was not mine to flip.

## Other notes

- Pending-fix #2 ("court leg-4 frame-length reconciliation"): leg 4 passes
  (malformed header → typed `{:bad_protocol_header, got}` exit); the
  frame-length surface is consistent — decoder `@max_frame_size` (1 MiB + 512)
  is the same value the connection advertises via
  `FrameDecoder.max_frame_size/0`. Closed by evidence, no code change.
- Two shared-compile freezes from a concurrent wasm lane (bridge.ex, then
  worker.ex) were ridden out per the compile-freeze SLA (~90 s and ~50 s);
  no cross-lane files touched. No `Process.sleep` added anywhere
  (`wait_ledger` polls `:ets.info` with receive-after; `park/0` is a receive
  loop). Scratch test files removed; only the court file and the family
  sources changed.
- `git status` (this lane's files):
  `lib/smalt/messaging/amqp10/{amqp10_link.ex, amqp10_connection.ex, frame_decoder.ex}`,
  `test/integration/amqp10_crash_only_court_test.exs`.
