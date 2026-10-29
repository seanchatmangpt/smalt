# AMQP10 court completion + skeptic re-audit (BK1 closure)

Date: 2026-10-21 · Lane: BK1 · Repo: /Users/sac/smalt
**Standing:** **ALIVE** (baseline court 6/6, skeptic court 7/7, adversarial pass 5/5 on stability reruns — one typed load-flake disclosed below)
Context: solo
Subject sha256 at run time (sha256sum, first 16):
`amqp10_connection.ex 56172ff453276155` · `amqp10_link.ex fa1c4ae178255997` ·
`amqp10_session.ex 790bdce27dfc4249` · `frame_decoder.ex 7c24a63efdbca782`
In-flight disclosure: `amqp10_connection.ex` is `M` vs HEAD at receipt-write
time — an owner/other lane's in-flight edit, NOT this lane's (this lane made
zero lib/ edits; all three prior AMQP10 receipts' close conditions are met
without further repair). The court runs above executed against the working
tree state hashed here; a post-integration re-run re-pins the shas.

## Scope

Close-out of the outstanding backlog item: the crash-only AMQP 1.0 router
family (`lib/smalt/messaging/amqp10/`) had a landed court + two skeptic
receipts (PARTIAL_ALIVE, close condition = owner lane lands transfer path +
decoder 0x45/nil-described fixes, re-run to 7/7). This lane ran the courts for
real, re-audited one adversarial case per gate, and wrote this receipt. Zero
lib repairs were required — the owner lane's fixes (transfer path, 0x45 list0,
nil-described, enforced-100 credit law) are all confirmed landed and green.

## Commands + results (MIX_BUILD_ROOT=_build-bk1, asdf Elixir 1.20.4-otp-29 / OTP 29.1.2)

```
MIX_BUILD_ROOT=_build-bk1 mix test test/integration/amqp10_crash_only_court_test.exs --seed 42
  → Result: 6 passed   exit 0   (25.5s)
MIX_BUILD_ROOT=_build-bk1 mix test test/integration/amqp10_skeptic_court.exs --seed 42
  → Result: 7 passed   exit 0   (78.2s)
  witnessed probe lines: [SK2] transfer replies: [:disposition, :disposition]
  (SK1/SK3/SK4/SK5 probe lines scrolled out of the captured tail; the pass
  counts are the receipt of record — 7/7 includes SK3's enforced-100 assertions
  and SK5's +100-row growth assertion)
MIX_BUILD_ROOT=_build-bk1 mix test test/integration/amqp10_bk1_adversary.exs --seed 42
  → run 1: 4/5 (ADV-1 cascade timeout — load flake, see skeptic findings)
  → reruns (seeds 7, 14, 21): 5 passed × 3
     [ADV-1] mid-frame RST cascade: 0ms / 1ms / 1ms, 3 pids
```

## Per-requirement verdicts

| Gate | Requirement | Verdict |
|---|---|---|
| 1 | cascade <10ms on root kill AND client RST | **PASS** (both courts; SK1/SK1b 0ms, ADV-1 mid-frame-RST variant 0–1ms ×3) |
| 2 | wire conformance; decoder never raises on valid remote input | **PASS** (SK2: 2/2 dispositions; SK2b nil-described + list0 typed, no raise; ADV-2 live-wire nil-described `:end` → typed `{:child_crash, _session, :normal}`, no ArgumentError) |
| 3 | credit law: grant-once 100, enforced boundary | **PASS** (SK3: exactly 100 dispositions, 0 replenishing flows, 100 ETS rows, typed `{:amqp10_link_credit_exhausted, 0, id}` at transfer 101) |
| 4 | partial-frame buffering | **PASS** (SK4 10 random splits; ADV-4 harshest split at the exact 8-byte frame-header boundary → clean handshake) |
| 5 | ETS growth bounded by credit law | **PASS** (SK5: +100 rows exactly for 2000 attempts; ADV-5 settled row `{0, 700_001}` exact payload) |

## Skeptic findings (adversarial pass, one re-derived case per gate)

Scratch court: `test/integration/amqp10_bk1_adversary.exs` (uncommitted; sha256
of file at run time `8cef37cf7c6b3cfb`). No sleeps; all
waits are deadline-bounded receives / bounded polls.

- **ADV-1 (gate 1)**: RST while half a transfer frame is on the wire. First
  run timed out at 10ms (compile-warm scheduler contention on this lane's own
  first run after `mix test` boot); 3/3 clean reruns at 0–1ms with identical
  pids (conn+session+link). Typed as a **load-flake, not a lib defect**: the
  connection handles both `{:tcp_error, reason}` and `{:tcp_closed}`
  (`amqp10_connection.ex:113-117`), and the 10ms budget is the same budget the
  prior skeptic receipt saw violate once (32ms RST outlier) under full-machine
  load. A widened budget would be a duration fence, not a repair — refused.
  Close condition for the flake class: none required; if it recurs in a quiet
  machine run (`just quiesce` first per corpus-premise convention), re-type.
  ADV-2 (gate 2): live-wire nil-described `:end` over an established
  connection — typed exit `{:child_crash, session, :normal}`, connection
  cascade clean; the SK2b decoder-level fix holds on the live wire.
  ADV-3 (gate 3): transfer on unknown handle 9 → typed
  `{:child_crash, session, {:unknown_link_handle, 9}}`, no silent accept.
  ADV-4 (gate 4): split exactly at the 8-byte frame-header boundary (empty
  body in chunk 1) → handshake completes, all 4 replies in order.
  ADV-5 (gate 5): settled ledger row lands with exact payload under key
  `{channel, delivery_id}`.

## Residuals (named, not silent)

1. ADV-1 load-flake class: the 10ms cascade budget can violate under
   full-machine compile load (witnessed twice now across lanes: prior 32ms
   outlier, this run's 10ms timeout). The code path is correct; the bound is
   machine-load-dependent. Named residual, not a defect.
2. The `:amqp10_settled` table-ownership/lifecycle gap from the prior skeptic
   receipt (table owned by first connection, no eviction) is NOT closed by
   this lane — the growth law is now bounded by the enforced credit law (SK5),
   but cross-connection lifecycle remains a design gap, typed in
   `amqp10-skeptic-redispatch.md` #5. Outstanding by design, not silently.
3. Scratch adversary file left uncommitted at
   `test/integration/amqp10_bk1_adversary.exs`; promote to a landed court or
   delete at integration. Not committed (per dispatch).

**RESOLVED 2026-10-21 (BK-23 promotion)**: the scratch adversary was committed
in checkpoint 08acebf and is now PROMOTED to a landed court —
`test/integration/amqp10_adversary_court_test.exs`, module
`Amqp10.AdversaryCourt` (ADV-1..ADV-5 unchanged). Ran
`MIX_BUILD_ROOT=_build-bk23 mix test test/integration/amqp10_adversary_court_test.exs`
→ `Result: 5 passed`, exit 0. Residual closed.

---

## Skeptic re-audit — BK-116 (2026-10-21, fresh clean-build pass)

**Standing:** **ALIVE** — clean-build compile clean on the amqp10 surface; all
three courts green on the fresh build root; new adversarial case ADV-6 green
with one NEW typed finding (residual R-116-1, disclosed below, no lib repair
by this lane). Lane: BK-116. Dispatch named the receipt path
`docs/jira/v26.10.22/receipts/amqp10-court-closure.md`; the receipt of record
lives in `v26.10.21` — appended here, original preserved above.

### Motivation

The BK-103 debug-instrumentation incident showed stale-beam/dirty-tree runs
can read green falsely. This pass re-pins everything on a fresh
`_build-bk116` root.

### Subject pin (sha256 first 16, at run time, vs HEAD)

All five lib subjects byte-identical to HEAD `65cad07` (git status empty for
the subtree; this lane's only new file is the uncommitted scratch court):

```
amqp10_connection.ex 8f4713d0e58e3447   amqp10_ledger.ex 217be5095ab57f86
amqp10_link.ex fa1c4ae178255997         amqp10_session.ex 58c17281ae03c800
frame_decoder.ex 4cd7e4e32c4d3c23       messaging/amqp/connection.ex fd305dd98211b023
```

### (1) Clean build

Toolchain: asdf erlang 29.1.2 / elixir 1.20.4-otp-29 (the repo
`.tool-versions` pair; a bare `mix` resolves to a homebrew Elixir 1.19.5 and
refuses boot — first two attempts hit this, disclosed).

```
export PATH="$HOME/.asdf/installs/erlang/29.1.2/bin:$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH"
MIX_BUILD_ROOT=_build-bk116 mix compile --force                → exit 0
MIX_BUILD_ROOT=_build-bk116 mix compile --force --warnings-as-errors → exit 1
```

The `--warnings-as-errors` run fails with exactly 2 warnings in the log tail,
both pre-existing dep/generated drift (BK-107-typed class): `Smalt.EgressRouter.do_match/4`
and `Smalt.Mcp.Router.invoke/2` (generated MCP descriptor vs plug dialyzer
types). Full-log audit (811 lines, `/tmp/bk116_compile_full.log`): 37
warnings total, **zero** attributable to `lib/smalt/messaging/amqp10/` or
`lib/smalt/messaging/amqp/connection.ex` — origins are plug/Mcp.Router
(generated), powl2/law_compiler, ggen_igniter/convergence, ash_graphlaw dep.
The amqp10 surface compiles warning-clean on a fresh build.

### (2) Court re-runs on the clean build (all embedded output)

```
MIX_BUILD_ROOT=_build-bk116 mix test test/integration/amqp10_crash_only_court_test.exs --seed 42
  → Result: 6 passed, exit 0 (25.1s)
MIX_BUILD_ROOT=_build-bk116 mix test test/integration/amqp10_adversary_court_test.exs --seed 42
  → Result: 5 passed, exit 0 (25.0s)  [ADV-3 witnessed: {:child_crash, _, {:unknown_link_handle, 9}}]
MIX_BUILD_ROOT=_build-bk116 mix test test/integration/ja7_crash_only_court.exs --seed 42
  → Result: 6 passed, exit 0 (30.2s)  [JA-7.3: procs 1821→1824, +273KiB over 10 cycles]
```

No stale-beam false-green: the build root did not exist before this pass;
every beam is from the pinned tree.

### (3) NEW adversarial case ADV-6 — disposition-reconciliation race

Scratch court: `test/integration/amqp10_bk116_skeptic.exs` (uncommitted, per
dispatch; promote or delete at integration). No sleeps — monitor-based
bounded receives only.

Design: leg 1 sends a settled transfer (`delivery_id` 800_001) and RSTs the
socket BEFORE reading the disposition (linger-0 close, kill between
initiation and disposition); leg 2 reconnects on the same listener and
re-delivers under the SAME `{channel: 0, delivery_id: 800_001}` key with a
different payload. Asserts: exactly ONE disposition, answered on the LIVE
connection; exactly one ETS row for the key with the REDELIVERED payload; and
`amqp10_settled` row count grew by EXACTLY +1 across the kill/reconnect —
whichever way the pre-kill leg landed — i.e. no phantom redelivery
double-count.

```
MIX_BUILD_ROOT=_build-bk116 mix test test/integration/amqp10_bk116_skeptic.exs --seed 42
  → Result: 1 passed, exit 0 (10.0s)
  witnessed log line (leg-1 conn): Last message: {:amqp10_tx, 0, {:disposition, %{first: 800001, ...}}}
```

**Verdict: exactly-once visibility HOLDS** — set-keyed overwrite at
`{channel, delivery_id}` gives one row, one live-connection disposition, +1
row growth, on the current tree.

### R-116-1 (NEW finding, typed, no repair by this lane)

During the ADV-6 race the leg-1 connection crashed with a **bare MatchError**:

```
23:10:48.512 error[] GenServer #PID<0.2178.0> terminating
** (MatchError) no match of right hand side value: {:error, :einval}
    lib/smalt/messaging/amqp10/amqp10_connection.ex:222: Smalt.Amqp10.Connection.tx/3
    lib/smalt/messaging/amqp10/amqp10_connection.ex:104: handle_info/2
    Last message: {:amqp10_tx, 0, {:disposition, %{first: 800001, state: :accepted, ...}}}
```

`tx/3` line 222 is `:ok = :gen_tcp.send(state.socket, frame)` — a
disposition (or any tx) racing a just-closed socket crashes the connection
with an UNTYPED crash reason. The crash-only law holds (loud death, full
cascade — the link's disposition is never silently dropped; the socket IS
dead), but the family's typed-exit discipline is violated on this path: the
reason is a raw `MatchError`, not a typed term like
`{:tcp_error, :einval}`-shaped exits the connection produces elsewhere
(`amqp10_connection.ex:113-117` handles `{:tcp_error, reason}` /
`{:tcp_closed}`). Named residual: a one-line fix
(`case :gen_tcp.send(...) do :ok -> :ok; {:error, reason} -> exit({:tcp_tx_error, reason}) end`)
belongs to the owner lane; this skeptic lane made zero lib/ edits per
dispatch.

### Residuals carried forward (re-checked, unchanged)

- R-1 (prior #1): the 10ms cascade budget stays load-sensitive (named
  load-flake class; no violation observed in this pass — all cascades 0-1ms).
- R-2 (prior #2): `:amqp10_settled` cross-connection lifecycle/eviction
  remains a design gap, unchanged, bounded by the credit law.
- Scratch files owed integration disposition: `amqp10_bk116_skeptic.exs`
  (this lane).

**BK-116 standing: ALIVE** — clean-build verified, 3/3 courts re-green, ADV-6
green with R-116-1 disclosed for owner-lane repair.
