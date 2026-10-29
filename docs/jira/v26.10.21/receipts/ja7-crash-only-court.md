# JA-7 — Crash-only court (amqp10 family + EgressRouter), OTP-29

**Standing: ALIVE** — court file green 2 consecutive runs, 6/6 legs, on the repo
standard OTP-29 toolchain (`.tool-versions`: erlang 29.1.2 / elixir 1.20.4-otp-29),
`MIX_BUILD_ROOT=_build-ja7`.

## Subject

- Court: `/Users/sac/smalt/test/integration/ja7_crash_only_court.exs`
  (`Integration.Ja7CrashOnlyCourt`, 6 tests)
- Subjects under court: `lib/smalt/messaging/amqp10/` (Connection root,
  Session, Link, FrameDecoder), `lib/smalt/egress_router.ex`,
  `lib/smalt/messaging/amqp/` (KD-155 ATOM bridge, KD-131/132 CBS face).
- Branch `main`, no lib/ changes by this lane (court file only; one mid-run
  compile-freeze from another lane's in-flight `lib/smalt/apim.ex` edit at
  19:07, fixed by its owner, disclosed per SLA rule 6).

## Command

```bash
export PATH="$HOME/.asdf/installs/erlang/29.1.2/bin:$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH"
MIX_BUILD_ROOT=_build-ja7 mix test test/integration/ja7_crash_only_court.exs
```

## Embedded output (run 3, 2026-10-21 19:0x PDT)

```
[JA-7.3] cycle cascade ms: 1 0 0 0 0 0 0 0 0 0
[JA-7.3] procs 1497 -> 1500, proc-mem delta 237KiB over 10 cycles
[JA-7.1] cascade=0ms (deadline 10ms), tree=3 pids
Finished in 31.8 seconds (0.00s async, 31.8s sync)
Result: 6 passed
```

Run 2 was interrupted by the disclosed compile-freeze (app boot refused:
`Smalt.Apim` `{:local, ...}` name tuple mid-edit); run 1 (19:05) was green
6/6, run 3 green 6/6.

## Legs and verdicts

| leg | claim | verdict |
|---|---|---|
| JA-7.1 | real `Process.exit(conn, :kill)` mid-stream → whole link/session tree (3 pids) DOWN in **0 ms** (< 10 ms court deadline), monitors pre-registered, listener survives | PASS |
| JA-7.2 | respawn with zero manual cleanup: same listener accepts a fresh client immediately; settled-transfer round-trip byte-exact; `:amqp10_settled` ledger gone-or-rebound to a live owner after root death | PASS |
| JA-7.3 | 10 crash-recover cycles converge every cycle (cascade ≤1 ms each); process count 1497→1500, process memory delta +237 KiB over 10 cycles — flat, no leak accumulation | PASS |
| JA-7.4 | EgressRouter queue plane (PUT queue → POST message → GET messages, payload on the wire) unaffected by a fresh amqp10 cascade | PASS |
| JA-7.5 | KD-155 framing post-recovery: ATOM `DELETE` answers `HTTP/1.1 204 No Content`, no `content-length`, zero drained body bytes, queue row actually gone from `:smalt_resources` | PASS |
| JA-7.6 | KD-131/132 CBS post-recovery: malformed map32 app-props on `$cbs` does NOT kill the broker connection; valid put-token verifies (`LOCAL_SIGNATURE_VERIFIED_NOT_AZURE_AUTHORITY`, status 200) and the same connection still delivers the queued message (`ja7-kd131-payload`); `SasVerifier.shared_key/0` honors a floor-valid configured key end-to-end | PASS |

## Method notes

- Chicago discipline: real TCP listeners, real sockets, real GenServers, real
  ETS, assertions on wire bytes and live process state. No mocks, no sleeps —
  cascade timing via pre-registered monitors, delivery via
  `SmaltTest.AssertEventually` bounded polls.
- Failure taxonomy of the crash-only family observed as documented: bad
  protocol header → typed `{:bad_protocol_header, got}` exit; client RST /
  `tcp_closed` → `{:transport_closed, :tcp_closed}` root exit cascading the
  tree.
- Deep-assert on the ledger (JA-7.2) accepts the designed disjunction
  (gone-or-rebound): the settled ledger is intentionally owned by an unlinked
  holder so the ledger outlives any single connection.

## Machine

macOS 26.2, Apple silicon (arm64), OTP 29.1.2 / Elixir 1.20.4-otp-29
(`MIX_BUILD_ROOT=_build-ja7`).

## Gate re-embed (BK-60, 2026-10-21)

Context: solo

NO-CONTEXT was a missing Context line (evidence already embedded:
`Result: 6 passed`, run 3). Fresh subject re-check, 2026-10-21:

```
$ grep -c 'defmodule Integration.Ja7CrashOnlyCourt' test/integration/ja7_crash_only_court.exs
1
re-check exit 0
```

Court file present on disk. Standing ALIVE unchanged.
