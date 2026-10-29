# BK-AMQPC — drift census: connection.ex / sb_rules.ex / powl2 files

- **Standing**: PARTIAL_ALIVE (verdicts per file below)
- **Context**: solo
- **Lane**: BK-AMQPC (read-only census except this receipt)
- **Date**: 2026-10-22

## Task-snapshot correction

The dispatch snapshot listed `lib/smalt/messaging/amqp/connection.ex`,
`lib/smalt/powl2/sb_rules.ex`, and `test/internal/powl2_primitives_test.exs` as dirty.
Re-read on disk: all three were swept into checkpoint `8b771322` (tick checkpoint,
07:41 PDT) as in-flight snapshots; only `lib/smalt/powl2/compiler.ex` is dirty now.

## (1) lib/smalt/messaging/amqp/connection.ex — verdict: UNOWNED-DRIFT (BROKEN, typed)

Swept edit (now at HEAD, `8b771322`):

```diff
+    if System.get_env("B4R_TRACE") do
+      IO.puts("[B4R-TRACE] in frame=...")
+    end
+
     if frame.type == :sasl do
       handle_sasl(perf, state)
     else
       handle_amqp(..., state)
     end
+  end
+
     if frame.type == :sasl do
       handle_sasl(perf, state)
     else
       handle_amqp(..., state)
     end
  end
```
(The final dispatch block is the ORIGINAL, left in place by the broken insert.)

An unowned `B4R_TRACE` debug-instrumentation insert that left the
`do_handle_event/2` dispatch DUPLICATED: the original `if frame.type == :sasl ... end`
block plus its closing `end` remain below the inserted copy, producing an extra
`end` at `connection.ex:3379:1`.

**Compile gate**: `mix compile` (shared `_build`) →
`== Compilation error in file lib/smalt/messaging/amqp/connection.ex ==
** (SyntaxError) invalid syntax found on lib/smalt/messaging/amqp/connection.ex:3379:1:
      error: unexpected reserved word: end`.
The file does NOT compile. This freezes every lane's shared compile —
compile-freeze SLA applies. Typed for the coordinator as UNOWNED-DRIFT,
BROKEN: the fix is to delete the duplicated dispatch block (keep the
B4R_TRACE insert + single dispatch), owner unknown, no lane receipt names it.

## (2) lib/smalt/powl2/sb_rules.ex — verdict: OWNED-BY-BK-CENS3 (landed, receipt on disk)

Swept edit changes the stale-table wait: an :init-heir-held stale table is no
longer waited on (`owner == Process.whereis(:init)` → skip monitor wait), the
delete is guarded (`:ets.info(name) != :undefined`), and re-creation uses
`:ets.new(name, opts)` returning `:ok` instead of `ensure_table`.

Traces to the LANDED receipt
`docs/jira/v26.10.22/receipts/bkcens3-final-hop.md` (BK-CENS3 F8 shared-ETS
falsifiers; heir-held table survives crash death under :init ownership; the
restarted GenServer's `:ets.new` raised `:already_exists` ×6 under batch load).
The checkpoint commit message names sb_rules.ex as an in-flight snapshot; the
owner lane (BK-CENS3) landed its receipt, so this is landed work awaiting its
code being recognized as landed (checkpoint-swept residue of a landed lane).

## (3) test/internal/powl2_primitives_test.exs — verdict: OWNED-BY-BK-CENS3 (landed)

Swept +66 lines: three BK-CENS3 F8 falsifier tests (crash-killed manager
stale-delete + restart owns table; 6-cycle kill/restart fan-out never raises
`:already_exists`; 16-writer load across a kill/restart cycle). Comments cite
`bkcens3-final-hop.md` directly. Same disposition as (2).

## (4) lib/smalt/powl2/compiler.ex (still dirty) — verdict: IN-FLIGHT-OWNER: BK-1SAFE

Dirty edit is doc-comment-only: the `compile/2` moduledoc boundary note typed
"as of BK-1SAFE — NOT a machine-checked refusal, deliberately", documenting the
set-semantics (MapSet markings) reachability engine, the token-agnostic AST
executor, and why a multiset token-game gate is deliberately absent (it would
refuse the canonical HIGH-2 redo-loop nets the court pins). BK-1SAFE is a named
in-flight lane (checkpoint messages 076f0aee / 2c3a10b5 / 8b771322 all list it);
no `*1safe*` receipt file exists yet in `docs/jira/v26.10.22/receipts/`. The
edit is the owner's documentation leg, swept+committed at HEAD by the checkpoint
while the lane is still in flight. No action for the coordinator.

## Compile sanity (the two lib files)

- `lib/smalt/messaging/amqp/connection.ex`: **FAIL** — SyntaxError 3379:1
  (duplicated dispatch block, see (1)).
- `lib/smalt/powl2/sb_rules.ex`: SYNTAX-OK (`Code.string_to_quoted`, elixir 1.20.4-otp-29).
- `lib/smalt/powl2/compiler.ex`: SYNTAX-OK (same harness). Full-file compile of
  these two could not complete via `mix compile` because the connection.ex
  SyntaxError aborts the parallel compiler before them; syntax gate is the
  receipted evidence here.

Note (pre-existing, not this lane's): a fresh `MIX_BUILD_ROOT=/tmp/...` compile
fails earlier at dep `yamerl` (missing include file in rebar3 bare compile) —
environment issue, unrelated.

## Commands

```
git status --porcelain && git diff --stat
git show 8b771322 -- lib/smalt/messaging/amqp/connection.ex lib/smalt/powl2/sb_rules.ex test/internal/powl2_primitives_test.exs
mix compile --warnings-as-errors   # exit: connection.ex SyntaxError 3379:1
elixir -e 'Code.string_to_quoted/1' on sb_rules.ex + compiler.ex  # both SYNTAX-OK
```
