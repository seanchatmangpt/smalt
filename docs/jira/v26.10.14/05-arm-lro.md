# V261014-05 — ARM LRO Sweeper (at-rest terminality) + `:lro_retention` retention

- **Release:** v26.10.14 · **Lane:** arm-gateway · **Status:** DECISION GATE OPEN
- **Owner files:** `lib/smalt/arm_gateway/lro.ex`, `lib/smalt/arm_gateway/lro_sweeper.ex` (new), `lib/smalt/application.ex`, `test/lro_test.exs`, `docs/compliance/C1_ARM_REST.md`, `docs/RELEASE_NOTES_v26.10.14.md`, `CHANGELOG.md`

## 1. Summary

Two adjacent typed gaps on the ARM LRO surface are OPEN with a completed, fenced design already written in the compliance register:

- `GAP(lro-lazy-terminality)` — an operation record reaches terminal only when some `get_op/1` poll touches it. An op never polled after `startedAtMs + delayMs` stays InProgress at rest. The livelock face is RESOLVED (lens-9); the at-rest face is not: no timer process, no sweeper exists today (the only sweeper in the tree is `Smalt.Amqp.Sweeper`).
- `GAP(lro-retention-unbounded)` — op records accumulate forever in `:smalt_operations`, measured 780 B/op monotone (tmp/errc/arm-gateway-lens7/cycle-2.md). Fences `lro_test (10)+(11)` pin accumulate-forever deliberately.

Full sweeper work-order shape (trigger, scan, shared flip function, eviction interaction, fences, falsifier) is specified at `docs/compliance/C1_ARM_REST.md:88-121`, marked **NOT implemented**.

## 2. DECISION GATE (coordinator: check exactly one)

- [ ] **(a) LAND the sweeper + retention now** — RECOMMENDED. Spec is complete and bounded (C1:88-121); `evaluate/2` and `fail_closed/2` already converge every malformed shape to a persisted terminal, so the sweeper is a thin periodic driver over existing pure logic. Cost: one GenServer + one child-spec line + fence rewrites (10)+(11).
- [ ] **(b) typed-OPEN with release disclosure** — fallback. Keep both GAPs OPEN; land only the register repair (§8) and add disclosure paragraphs (§9). No code, no test changes.

Recommended: **(a)**. If (b), jump to §8 (item 5 only) and §9.

## 3. Design — `Smalt.ArmGateway.LRO.Sweeper`

New file `lib/smalt/arm_gateway/lro_sweeper.ex`, pattern-matched on `Smalt.Amqp.Sweeper` (`lib/smalt/messaging/amqp/sweeper.ex`).

1. **Trigger**: periodic `Process.send_after` loop, interval `Application.get_env(:smalt, :lro_sweep_interval_ms, 30_000)`. Started as a child of `Smalt.Supervisor` in `lib/smalt/application.ex` (the gateway has no supervisor of its own; same pattern as `Smalt.AmqpBroker`) — never under a request process.
2. **Shared flip function**: promote the private `evaluate/2` (`lro.ex:124-142`) and `fail_closed/2` (:167-183) to public (or thin public wrappers), documented "sweeper and lazy path MUST call the same function so they cannot diverge." `get_op/1` clause bodies unchanged.
3. **Scan pass**: `Store.list(:smalt_operations)` → for each InProgress record with valid integer scheduling fields and `startedAtMs + delayMs <= now`, persist the terminal via the shared function (identical record shape the lazy path writes). Malformed records route to the same `fail_closed/2` Failed terminal (`OperationRecordIncomplete`) — lazy and swept records converge to the identical persisted terminal.
4. **Idempotence / concurrency**: `Store.put/3` is a single atomic insert of the whole record; a sweep racing a wire poll writes byte-identical terminal bodies. No lock needed; the concurrency fence (6d) pins it.
5. **The sweep never deletes** — eviction is retention's job, evaluated after the flip pass, oldest-terminal-first.

Fail-closed: a scan failure raises and crashes the GenServer; supervisor restart is the honest signal (matches `Smalt.Amqp.Sweeper`).

## 4. Design — `:lro_retention` eviction

Config: `Application.get_env(:smalt, :lro_retention_ms, :infinity)` — default `:infinity` preserves accumulate-forever (no silent policy change); non-negative integer enables eviction. Fail closed like `:lro_delay_ms` (:36-39).

- Eligibility (after the flip pass): terminal (`status` ≠ `"InProgress"`) AND `endTime` older than the window. **InProgress NEVER evicted.**
- Order: oldest-terminal-first (`endTime` ascending).
- Default `:infinity` ⇒ fence (10) stays green unchanged unless a test explicitly sets a short window.

## 5. Implementation steps (option (a))

1. `lro.ex`: make `evaluate/2` + `fail_closed/2` public. Optionally `terminal?/1`.
2. New `lro_sweeper.ex` per §3: `start_link/1`, `sweep_now/0`, `init` reading `:lro_sweep_interval_ms`, `handle_info(:tick, ...)` (flip pass, then eviction pass when enabled), `send_after` re-arm.
3. `application.ex`: append the sweeper to `children` (one additive line, `:one_for_one`).
4. `test/lro_test.exs` fence work:
   - (10) (:491-515) rewrite: 500 mints, NO polls, `Process.sleep(delay + sweep_interval + margin)`, raw `Store.get` asserts every record `Succeeded` at rest, `Store.list` count still 500 with default retention; with a short retention window set, also assert the eviction face — past-window terminal GONE at raw get, in-window remain, seeded InProgress never evicted.
   - (11) stays green as-is with default `:infinity`.
   - (12) wire-stickiness and (13) incomplete-record Failed flip MUST stay green unchanged.
   - New at-rest zero-poll fence: mint one op, never poll, raw `Store.get` after `delay + sweep + margin` reads terminal.
   - New empty-store / all-terminal no-op fence: `sweep_now/0` pins 0 writes (count + `endTime` stability).
   - New sweep-vs-poll concurrency fence: sweep racing a wire poll converges to ONE persisted terminal, byte-identical body.
   - Existing tests at :314 and :884 must stay green with the sweeper live.
5. Register repair: DELETE duplicate row `C1_ARM_REST.md:86` (stale pre-lens-9 twin of :84); flip both GAP rows CLOSED; rewrite the work-order block (:88-121) to "IMPLEMENTED v26.10.14 (V261014-05)".
6. Release notes + CHANGELOG: one line each (background sweeper, opt-in `:lro_retention_ms`).

## 6. Acceptance criteria (option (a))

Run `mix test test/lro_test.exs` 3× — all green:

- [ ] a. (10) rewritten: eviction face + InProgress survival at any age.
- [ ] b. At-rest terminality with ZERO polls.
- [ ] c. Empty-store / all-terminal sweep is a no-op (0 writes).
- [ ] d. Sweep racing a wire poll converges to ONE persisted terminal.
- [ ] e. (12) and (13) unchanged and green.
- [ ] f. Existing concurrent-poll fences (:314, :884) green.
- [ ] g. C1 has exactly ONE `GAP(lro-lazy-terminality)` row; both rows CLOSED; block re-marked IMPLEMENTED.
- [ ] h. Falsifier (register :119-121): a record past delay + sweep interval, never polled, reading InProgress at raw get after a sweep ⇒ NOT closed.
- [ ] i. `mix test test/compliance/c1_arm.exs` still 26/0.

## 7. Risks / notes

- Tests drive the sweeper via `sweep_now/0` or short per-test `Application.put_env`, never by sleeping 30 s.
- `endTime` is second-truncated ISO8601; retention math compares at second granularity (parsed `endTime`, no record-shape change).
- `application.ex` is shared (other lanes disclose listener wiring); the additive child line must be disclosed per the NOTE convention.

## 8. Scope if option (b)

1. No sweeper/retention/test changes.
2. Register repair only: delete duplicate row :86; re-mark the work-order block "spec-complete, pending release decision".
3. Both GAP rows → "OPEN — scheduled via V261014-05, spec-complete at C1:88-121".
4. Record the gate outcome in this file.
5. §9 disclosure paragraphs.

## 9. Release disclosure text (required ONLY under option (b))

> **Known gaps (arm-gateway LRO):** Operation records reach terminal state only when polled; an operation that is never polled after its completion delay elapses remains InProgress at rest until a poll or a future background sweeper lands (tracked as `GAP(lro-lazy-terminality)`, spec-complete). Operation records are retained indefinitely (~780 B/op, monotone for process lifetime; `GAP(lro-retention-unbounded)`). Neither affects wire behavior on polled operations; both are scheduled for the next release.
