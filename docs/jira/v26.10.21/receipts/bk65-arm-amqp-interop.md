# BK-65 — Cross-plane interop witness: ARM queue → AMQP (rhea) → crash-only amqp10

**Standing: ALIVE (5/6 probe legs PASS; the 1 FAIL is the namespace-PUT 202 face, below)**
**Context: solo**

Subject: smalt HEAD `6174068d82212201f95da708f4f22eaab8c50caf` (branch main), shared
substrate block **b65** (amqp=39650, eh=39651, arm=39652, egress=39653, tls=39654,
mcp=39655), auth `:enforce`, booted via `scripts/substrate-ctl up --block b65 --auth
enforce` with `MIX_BUILD_ROOT=_build-bk65`, fd-closed spawn, pinned toolchain
(asdf: erlang 29.1.2 / elixir 1.20.4-otp-29, OTP 29 verified via `erl -noshell
-e 'io:format("~s", [erlang:system_info(otp_release)])'` → `29`).

Probe: `verification/ts/bk65.probe.cjs` (real rhea, `verification/ts/node_modules/rhea`),
final run log `/Users/sac/smalt/tmp/bk65-probe-final.log`, **exit 1** (the ns-202 leg):

```
FAIL arm-ns-put: status=202
PASS arm-q1-put: status=201
PASS rhea-send-q1: accepted=true condition=- desc=
PASS rhea-receive-q1: drained=1 len=27/27 exact=true err=-
PASS neg-q2-refusal: condition=amqp:not-found desc=MessagingEntityNotFound: The messaging entity "q2-never-created" could not be fo…
PASS neg-conn-survives: accepted=true
```

## Per-leg evidence

| # | Leg | Command | Exit / wire evidence | Verdict |
|---|-----|---------|----------------------|---------|
| 1 | ARM PUT queue | `node verification/ts/bk65.probe.cjs` (armPut ns, then `PUT /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/bk65-rg/providers/Microsoft.ServiceBus/namespaces/bk65-ns/queues/q1?api-version=2021-04-01`, bearer minted from local STS `/dev/oauth2/v2.0/token`) | `arm-q1-put: status=201` | ALIVE |
| 2 | rhea send → q1 | same probe, leg `rhea-send-q1` | CBS put-token 200, sender link attached, disposition **accepted** on the real AMQP wire. Entity reached via ARM materialization only — `sb_auto_ensure` never set (static: `grep -rn sb_auto_ensure config/` → no match, exit 1; default false per `lib/smalt/messaging/amqp/queue_store.ex:59`), behavioral: leg 4 refusal | ALIVE |
| 3 | receive + complete | same probe, leg `rhea-receive-q1` | receiver attach + credit → delivery settled `accepted` (delivery.accept()); payload **byte-exact**: len 27/27, `exact=true` | ALIVE |
| 4 | negative: never-created q2 | same probe, legs `neg-q2-refusal` + `neg-conn-survives` | sender link detached with `amqp:not-found` + `MessagingEntityNotFound: The messaging entity "q2-never-created"…`; then the SAME connection put-token + send to q1 → `accepted=true` | ALIVE (after BK-65 witness fix, disclosed) |
| 5 | crash-only amqp10 stack | `MIX_BUILD_ROOT=_build-bk65 MIX_ENV=test mix test test/integration/amqp10_crash_only_court_test.exs:193` | `1 passed, 5 excluded` — raw gen_tcp client, link ATTACHed with target address `q1` flavor (the stack is address-agnostic — see gap below), settled transfer → `accepted` disposition on the wire, payload byte-exact in the settled ledger (`:amqp10_settled` `[{_, ^payload, _ts}]`) | ALIVE (with a scope note) |

## Scope note on leg 5

`lib/smalt/messaging/amqp10/` (crash-only AMQP 1.0 family) is a frame-level router with
its own settled ledger (ETS `:amqp10_settled`) and does NOT read the
ARM/queue store: a link ATTACHed with `target.address="q1"` round-trips payloads
address-agnostically. The leg-5 witness is therefore a real raw-wire round-trip through
the crash-only stack (transfer → accepted disposition + byte-exact ETS read-back), with
the queue name carried on the link ATTACH, not a shared-store round-trip. The
cross-plane store-sharing leg remains the rhea legs (2–4) against the main AMQP broker
(`lib/smalt/messaging/amqp/connection.ex`).

## Surfaced defects (evidence, not fixed in this lane unless noted)

1. **FIXED (BK-65 witness fix, disclosed)**: after the `amqp:not-found` error-detach,
   the link stayed in `state.links`, so the client's echo detach re-echoed a second
   detach and rhea died with `ERR_STREAM_WRITE_AFTER_END` — "connection survives" was
   NOT true before the fix (put-token on the same connection then timed out). Fix:
   `lib/smalt/messaging/amqp/connection.ex` `handle_transfer` `{:error, :messaging_entity_not_found}` clause now also drops the
   link from `state.links` (mirrors the normal detach path, connection.ex). Landed in
   the coordinator tick commit `6174068` (verified present on HEAD: `grep -c "BK-65 witness fix" → 1`).
2. **OPEN — ARM queue DELETE does not purge the AMQP message store.** The probe does
   ARM DELETE + re-PUT of q1 each run, and each run receives 1–2 stale deliveries from
   deleted-queue generations before our own message (drained=1..2, three consecutive
   runs). Real Service Bus drops the messages on queue delete. Candidate KD row.
3. **OPEN — namespace-level ARM PUT returns 202** (long-running-operation face) on
   fresh namespace create; real ARM returns 201. Queue-level PUT is 201 as required.
   The probe FAIL line is this face, not the queue leg.
4. **OPEN — crash-only court 2 (client RST → cascade <10ms) is load-flaky**: failed at
   1009ms (missing 3 DOWNs) when run with the full 6-test file under concurrent lane
   traffic, passed twice solo (`mix test …:139`). Timing-budget class, pre-existing;
   my edits do not touch the amqp10 family.
5. **Compile-freeze unblock fixes (disclosed, minimal)**: `lib/smalt/store/heir.ex` +
   `lib/smalt/store/partition.ex` (keyword-list-before-`{:heir,…}` tuple = SyntaxError
   under pinned Elixir 1.20.4; reordered options, semantics unchanged);
   `lib/smalt/store.ex` (16x duplicate child id `Smalt.Store.Partition` —
   `{Mod, arg}` children default to id `Mod` — SUBSTRATE_DIED witnessed twice; the
   lane's rewrite re-broke it once, re-fixed on the current content, landed in
   `6174068`); `lib/smalt/storage/journal_sink.ex` (mid-edit stray duplicate
   `GenServer.call` line + dangling `end`, TokenMissingError — removed the stray two
   lines, restoring the original append/6 delegation).