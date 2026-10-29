# Receipt: SK5/SK3 credit-law arbitration (REL-3 lane)

**Standing**: ALIVE
- **Date**: 2026-10-21
- **Lane**: REL-3 (OTP-29 toolchain: Erlang 29.1.2 / Elixir 1.20.4-otp-29 via asdf shims; `MIX_BUILD_ROOT=_build-rel3`)
- **Subject**: `test/integration/amqp10_skeptic_court.exs` (SK3/SK5 legs) — no `lib/` changes.

## Ruling applied

Coordinator ruling: SK3's enforced-100 credit law is canonical (measured post-fix:
`lib/smalt/messaging/amqp10/amqp10_link.ex` consumes one credit per settled transfer and
exits typed `{:amqp10_link_credit_exhausted, handle, id}` at the 101st transfer; the
crash cascade kills the connection). SK5's 2000-row pin predates the enforcement fix and
was re-pinned to the enforced-credit contract.

## Diff (65+/31-, one file)

`test/integration/amqp10_skeptic_court.exs`:

1. **SK3** (canonical law, tightened): delivery ids rebased to base 300_000 (unique base);
   `Process.monitor(conn)` moved before the sends; new assertion of the typed credit
   exhaustion — `{:DOWN, conn, {:child_crash, _session, {:amqp10_link_credit_exhausted, 0, 300_101}}}`
   within 5s; `dispositions == 100` exactly (the old `dispositions in [0, 100]`
   disjunction and the `UNOBSERVABLE` dead-path branch are removed — the boundary is
   observable post-fix); `ets_rows == 100`, `flows == 0`.
2. **SK5** (re-pinned, growth intent preserved): 2000 attempted transfers (base 400_000)
   against the 100-credit link; sends past the exhaustion boundary tolerate
   `{:error, _dead}` (graceful close or RST — same typed boundary seen through a dead
   socket); typed exhaustion asserted on the connection DOWN
   (`{:amqp10_link_credit_exhausted, 0, 400_101}`); bounded-window growth asserted:
   `after - before == 100`, 100/100 ids settled in window, id 400_101 absent. The
   growth-intent assertion survives: the ledger grows, by exactly the credit boundary,
   never unbounded.
3. **Cross-court ETS collision fix (disclosed)**: the settled ledger intentionally
   outlives connections (`amqp10_connection.ex` `ets_table/0`, unlinked holder), so SK3's
   old ids 1..100 deterministically polluted crash-only court 5's
   `refute :ets.member(:amqp10_settled, {0, 9})` in a shared-VM run. SK3's id rebase to
   300_000 removes the collision; the crash-only court file is untouched.
4. **Load-bound budgets widened (disclosed)**: `recv_n` recv timeout 5s → 15s (with
   concurrent lanes saturating the machine, a 5s handshake recv timed out in one run);
   SK5's send loop tolerates post-exhaustion transport death (`{:error, :enotconn}` /
   `{:error, :closed}`).
5. `wait_rows!/3` re-signed to `(wanted, base, deadline)` — bounded poll, no sleeps
   (no-sleep doctrine respected).

## Courts green x2

Exact command, both runs (asdf shims on PATH; OTP 29.1.2 / Elixir 1.20.4-otp-29):

```
export PATH="$HOME/.asdf/shims:$PATH"
MIX_BUILD_ROOT=_build-rel3 mix test test/integration/amqp10_skeptic_court.exs test/integration/amqp10_crash_only_court_test.exs
```

Run A (exit 0):

```
[SK1] root-kill cascade: 0ms, 3 pids
[SK3] dispositions=100/105 replenishing_flows=0 ets_rows=100
[SK5] ETS rows before=2 after=102 (+100) settled_in_window=100
Result: 13 passed
```

Run B (exit 0):

```
[SK1] root-kill cascade: 0ms, 3 pids
[SK3] dispositions=100/105 replenishing_flows=0 ets_rows=100
[SK5] ETS rows before=102 after=202 (+100) settled_in_window=100
Result: 13 passed
```

SK5's `before`/`after` deltas differ between runs because the ledger persists within the
same VM across tests; the assertion is on the delta (+100) and the per-id window, both exact.

## Pre-fix evidence (why the arbitration was needed)

Baseline run before the re-pin (same toolchain/build root): SK5 failed mid-flood with
`{:error, :closed}` at the exhaustion boundary and SK3 measured
`dispositions=100/105 ets_rows=100` only via its tolerant `in [0, 100]` branch; crash-only
court 5 failed deterministically from SK3's `{0,9}` pollution.

## Disclosures / session-introduced notes

- One interim run was blocked by an unrelated lane's in-flight compile break in
  `lib/smalt/telemetry/ocel_emitter.ex` (compile-freeze violation by that lane; it was
  fixed by its owner mid-window; no action taken by this lane).
- SK1b (RST cascade <10ms) timed out once in the first baseline run under machine load;
  it passed 0ms/8ms in the two green runs. No change made to its 10ms budget — it is the
  claim under test.

## Logs

Full run logs: `/tmp/rel3_run6.log` (run A), `/tmp/rel3_run7.log` (run B).

## Gate re-embed (BK-60, 2026-10-21)

Context: solo

NO-CONTEXT was a missing Context line (evidence already embedded: two
`Result: 13 passed` runs, exit 0 both). Fresh subject re-check, 2026-10-21:

```
$ grep -n 'amqp10_link_credit_exhausted' test/integration/amqp10_skeptic_court.exs | head -2
262:                    {:child_crash, _session, {:amqp10_link_credit_exhausted, 0, 300_101}}},
377:                    {:child_crash, _session, {:amqp10_link_credit_exhausted, 0, 400_101}}},
re-check exit 0
```

Both re-pinned credit boundaries (SK3 300_101, SK5 400_101) present in the
court file on disk. Standing ALIVE unchanged.
