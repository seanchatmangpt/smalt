# BK-41 — AMQP 1.0 settled-ledger owner (JA-1 finding #2 closed)

**Standing: ALIVE** · Context: solo · 2026-10-21 · Lane BK-41 (`MIX_BUILD_ROOT=_build-bk41`)

## Subject

- `lib/smalt/messaging/amqp10/amqp10_ledger.ex` (NEW) — `Smalt.Amqp10.Ledger`, a named
  GenServer owner of the settled-ledger ETS table `:amqp10_settled`.
- `lib/smalt/messaging/amqp10/amqp10_connection.ex` — `ets_table/0` rewritten: the bare
  `spawn` + `park()` holder and `wait_ledger/1` are deleted; the connection now calls
  `Smalt.Amqp10.Ledger.ensure()` then returns the table name.
- `test/integration/amqp10_ledger_owner_court_test.exs` (NEW) — the court.

## Defect (JA-1 census #2, re-confirmed in BK-28 re-witness)

`ets_table/0` (old amqp10_connection.ex:229-257) spawned an UNLINKED holder process that
created `:amqp10_settled` and parked in a receive loop. Holder death deleted the table
(no heir) — ledger contents silently lost; the discarded `spawn` return could race to a
no-holder window; no supervision, no proc_lib start hygiene.

## Fix

JA-R2 / `policy.ex` idiom, per the task authority:

- `Ledger.ensure/0`: `GenServer.start(__MODULE__, :ok, name: __MODULE__)` — deliberately
  UNLINKED (`start`, not `start_link`): a connection's crash cascade must not take the
  ledger owner with it, preserving the disclosed intentional-lifetime semantics (ledger
  outlives every connection). Idempotent: `{:error, {:already_started, _}}` → `:ok`.
  Name registration is atomic, so concurrent `ensure/0` callers can never race to two
  owners. Note: Elixir 1.20 rejects `name: {:local, _}` on GenServer.start — bare atom.
- `init/1`: `Process.set_label({__MODULE__, :settled_ledger_owner})`; creates the table
  only if undefined, with the 3-tuple `{:heir, Process.whereis(:init), []}` (policy.ex
  shadow-table law; a `heir:`/`heir_data:` keyword form is INVALID for `:ets.new/2`).
  An existing table (heir-passed to `:init` by a dead prior owner) is ADOPTED as-is —
  contents preserved.
- Connection `ets_table/0` is now 2 lines (`ensure()` + table name); `park/0` and
  `wait_ledger/1` deleted. No sleep loops anywhere (no-sleep doctrine: ownership is
  structural — atomic name registration + heir — not paced).

## Court (real kills, real wire, real ETS; no mocks, bounded polls only)

New `test/integration/amqp10_ledger_owner_court_test.exs`, 3 legs:

1. **BK-41.1 holder kill → heir survival + clean re-adoption.** Real settled transfer
   over real TCP; kill the owner `:kill` (DOWN observed); poll until the table owner is
   `Process.whereis(:init)` (heir fired); pre-kill row readable; next real connection
   re-adopts, fresh wire transfer lands byte-exact, pre-kill row STILL readable.
2. **BK-41.2 adversarial: 24 concurrent writers during owner death → zero lost-ledger
   window.** Writers race `ensure/0` + `:ets.insert` while the owner is killed mid-flight;
   every insert landed (public table + heir keeps the table in existence throughout);
   all 24 rows read back. Owner restart is lazy — the leg ends with an explicit
   `Ledger.ensure/0` and a liveness poll.
3. **BK-41.3 idempotence + adoption.** `ensure/0` twice → same owner; kill → heir to
   `:init`; pre-kill row survives; restart adopts without data loss.

Note (cosmetic, pre-existing pattern): when the owner dies, the `:init` process logs
`init got unexpected: {:'ETS-TRANSFER', :amqp10_settled, <dead owner>, []}` — the heir
receipt arriving at `:init`, which logs unknown messages. Harmless; disclosed.

## Verification (exact commands, exits, output tails)

Toolchain: asdf elixir 1.20.4-otp-29 / OTP 28 (PATH needs `~/.asdf/shims` ahead of the
homebrew 1.19.5 that fails the `~> 1.20` constraint).

```
$ MIX_BUILD_ROOT=_build-bk41 mix compile
...
Generated smalt app                                   # EXIT=0 (only pre-existing ash_r2rml/plug warnings)

$ MIX_BUILD_ROOT=_build-bk41 mix test test/integration/amqp10_ledger_owner_court_test.exs
20:50:47.473 [info] init got unexpected: {:"ETS-TRANSFER", :amqp10_settled, #PID<0.1958.0>, []}
Finished in 10.2 seconds ...
Result: 3 passed                                      # EXIT=0

$ MIX_BUILD_ROOT=_build-bk41 mix test test/integration/amqp10_crash_only_court_test.exs test/integration/amqp10_adversary_court_test.exs
Result: 11 passed                                     # EXIT=0

$ MIX_BUILD_ROOT=_build-bk41 mix test test/integration/ja7_crash_only_court.exs
Result: 6 passed                                      # EXIT=0
```

Before/after: before, killing the old holder deleted `:amqp10_settled` (contents gone,
`wait_ledger` recreated an empty table on the next connection); after, the identical kill
leaves the table alive under `:init` with every row readable, and `ensure/0` restarts an
owner that adopts it. Falsifier exercised for real: the court kills the owner and asserts
the row read-back — under the old code this leg fails at the first `:ets.lookup`.

No-sleep: zero `Process.sleep` in lane files (only the audited `poll_helper.exs` poll).

## Disclosures

- Concurrent-lane churn during the run: `SyncRoutes.ex`, `store.ex`, `frame.ex` were
  transiently mid-edit (compile-freeze SLA; waited and re-ran); BK-7's tick-checkpoint
  commit swept this lane's in-flight files into HEAD — all verification above is against
  the current on-disk content.
- 20 warnings appear from `ash_r2rml`/`plug` deps — pre-existing, not this lane's.

Not committed, per lane instructions.
