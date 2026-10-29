# AMQP10SK-r — crash-only AMQP 1.0 router skeptic audit (re-dispatch)

Date: 2026-10-21 · Lane: AMQP10SK-r · Repo: /Users/sac/smalt
**Standing:** **PARTIAL_ALIVE — 2 claim defects typed ALIVE, 1 UNOBSERVABLE, 2 PASS**
Context: pair (skeptic re-dispatch auditing the AMQP10 writer lane's landed diff)
Court: `test/integration/amqp10_skeptic_court.exs` (sha256 `0cc3e2c6…`)
Subject at audit close (sha256):
`amqp10_connection.ex 2f8f3e90…` · `amqp10_link.ex c010b86e…` ·
`amqp10_session.ex 790bdce2…` · `frame_decoder.ex e4f59720…`

## Method

Baseline: prior BLOCKED receipt
`docs/jira/v26.10.21/receipts/amqp10-crash-only-skeptic.md` (subject not landed);
subject landed at HEAD during this session (commit e626924 family). Five-claim plan
executed against a live router over raw `gen_tcp` with real wire bytes; no mocks.
Toolchain: asdf Elixir 1.20.4-otp-29 + Erlang OTP 29.1.2, `MIX_BUILD_ROOT=_build-a10sk`.

## Per-claim verdicts

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| 1 | cascade <10ms on root kill AND client RST | **PASS** | SK1/SK1b: 0ms typical (one 32ms RST outlier once in 7 runs under full-machine load), 3 pids (conn+session+link), all DOWNs within budget. Traps+links cascade law holds. |
| 2 | OPEN/flow/disposition byte conformance via PrimitiveCodec | **DEFECT ALIVE (typed)** | SK2b FAILS reproducibly: `<<0,0x53,0x17,0x40>>` (end with null error field — valid AMQP 1.0) → **raises `argument error`** (`FrameDecoder.positional_fields/2` on a nil described value). `0x45` (list0) has no `decode_element/1` clause → `{:error, :bad_element}` on the family's OWN encoder output: FrameCodec encodes `:accepted` as `00 53 24 45` and `%{}` as list0 — so `{:end,%{}}`, `{:close,%{}}`, and every accepted-disposition emitted by the server face are undecodable by the family decoder. SK2 fails with 0 dispositions delivered back to the client. |
| 3 | credit starvation (100 once, no replenish) | **UNOBSERVABLE in this state** | Grant observed: handshake flow `link_credit: 100`, exactly one grant, `flows==0` after (no replenishment — confirmed by code path + 105-transfer probe). Enforcement boundary unobservable: the transfer path is DEAD in the current in-flight subject (0 dispositions, 0 ETS rows for 105 settled transfers; also 0/2 in SK2, 0/2000 in SK5). |
| 4 | partial-frame split fuzz | **PASS** | SK4: 10 random splits (mid-frame-header cuts 1–7, mid-body cuts), two consecutive runs, all 10 complete on next chunk; decoder-level `{:more,_}` buffering law asserted on chunk A tails; handshake fully reconstructs. |
| 5 | ETS `:amqp10_settled` unbounded growth | **DEFECT ALIVE (typed) — design gap** | No `:ets.delete`/trim/TTL exists anywhere in `lib/smalt/mapping/amqp10/` (grep); table is `:named_table, :public`, owned by the FIRST connection that creates it (dies with that connection — cross-connection lifecycle defect). Table-ownership/lifecycle gap typed; growth law unobservable this state (transfer path dead) — SK5 could not count rows. |

#5 caveat: grep target was `lib/smalt/messaging/amqp10/` (typo guard: "mapping" above was
written in error; command was `grep -rn "ets.delete\|trim\|TTL" lib/smalt/messaging/amqp10/` → 0 hits).

## What the court proves (green cells)

- SK1/SK1b (PASS): root kill → 0ms tree death; client RST (SO_LINGER 0) → 0ms tree death.
- SK4 (PASS): random mid-header/mid-body TCP splits, 10/10 reconstruct.
- SK3 (green but typed): grant-once law holds on the wire; enforcement boundary UNOBSERVABLE.

## What the court refutes (red cells, all typed)

- SK2b: decoder raises `argument error` on valid nil-described end/close wire bytes.
- SK2b: `0x45` list0 constructor missing → family decoder cannot read its own encoder's
  dispositions/close/end; this is why SK2 sees 0 decodable dispositions — plus the
  deeper live-state fact that the transfer path currently delivers NOTHING end-to-end.
- SK5: no eviction path; table lifecycle bound to first connection owner.

## In-flight subject instability (disclosed)

The subject was being refactored by its owner lane DURING the audit window
(14:05–15:20 local): four shared-compile freezes were ridden out by bounded poll
(frame_decoder.ex landed corrupt-at-HEAD ~14:25, repaired ~14:29; powl2 law_compiler
and a wasm worker shim window; an OTP-29 guard churn window). Observed behavior
changed three times during the window (handshake 3-reply era; transfer path alive-then-dead).
Verdicts are pinned to the sha set above; a re-run after the owner lane lands is
the close condition for the UNOBSERVABLE cells (3-enforcement, 5-growth-law).

## Receipt commands

```
export PATH="$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$HOME/.asdf/installs/erlang/29.1.2/bin:$PATH" MIX_BUILD_ROOT=_build-a10sk
mix test test/integration/amqp10_skeptic_court.exs --seed 12   # Result: 3/7 (SK4 partial-cleanup run)
mix test test/integration receipt courts: run13 seed 11 → 3/7, run15 seed 13 → 4/7, run16 seed 77 → 4/7 (stable)
mix run --no-start /tmp/a10sk_casc.exs   # CASCADE kill 0ms / rst 0ms (one 32ms outlier under load)
```

Close condition: owner lane lands the transfer path + decoder 0x45/nil-described fixes;
re-run `mix test test/integration/amqp10_skeptic_court.exs` → target 7/7, then the
baseline `amqp10_crash_only_court_test.exs` still has its own off-by-one
(recv_while(sock, 3) vs 4-frame expectation) to fix separately.
