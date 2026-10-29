# KD-131 / KD-132 / KD-133 — AMQP substrate triage (lane KD-AMQP)

**Standing:** **ALIVE** (all three rows re-witnessed closed on the current tree; register flipped CLOSED-SIMULATED → CLOSED-WITH-RECEIPT).

Context: solo

Date: 2026-10-22. Repo /Users/sac/smalt. Lane KD-AMQP, build root `_build-kdamqp`, private block b89 (ports 39890-39895).

## Finding on arrival

All three rows were already CLOSED-SIMULATED with shims landed (`scripts/substrate.sh` KD-131 key derivation; `lib/smalt/messaging/amqp/connection.ex` KD-132 handle_cbs/find_reply_link normalization, KD-133 spec-ordered flow handling) and an ALIVE witness at `docs/jira/v26.10.20/receipts/fix4-amqp-witness.md`. But commit d0858144 (2026-10-21 22:39) touched `connection.ex` AFTER the witness mtime — the register's mtime gate was stale, so a re-witness on the current tree was owed before any closure claim.

## Re-witness on the current tree (real wire + real in-process faces, no mocks, no sleeps)

### Leg 1 — live-wire probe on block b89 (rhea + broker, :enforce mode)

Command: `SMALT_FIX4_BLOCK=b89 node verification/ts/fix4.probe.cjs` (probe self-boots block b89 fresh via substrate-ctl):

```
block b89 AMQP 39890 ARM 39892 keybytes 64
PASS kd131.shared-key-at-or-above-32-byte-floor
PASS kd131.cbs-put-token-200-floor-valid-key
PASS kd132b.malformed-body-typed-400
PASS kd132b.connection-survives-after-malformed-body
PASS kd133.spec-ordered-flow-grants-credit-2-deliver POLL-STEP
PASS kd133.topup-flow-delivers-third
TOTAL pass=6 fail=0
EXIT=0
```

- KD-131: booted shared key 64 bytes (>= 32-byte SasVerifier floor); a real CBS put-token minted from it answers 200 on the live broker under :enforce.
- KD-132(b): a malformed map32 application-properties body gets a typed 400 (UNSUPPORTED_CBS_REQUEST) and the same connection then answers a valid put-token 200 — connection survives.
- KD-133: a spec-ordered rhea flow grants credit on the live broker (2 deliveries, then a top-up flow delivers a third) — the "spec-ordered flows grant zero credit" starvation is not observable on current code.

### Leg 2 — in-process triage court (committed court test)

Command: `mix test test/integration/amqp_kd131_133_triage_test.exs` (MIX_BUILD_ROOT=_build-kdamqp):

```
Finished in 0.4 seconds (0.00s async, 0.4s sync)

Result: 7 passed
```

Real PrimitiveCodec byte round-trips, real SasVerifier HMAC, real TCP socket + real Connection GenServer + real QueueStore; asserts KD-132a map32 at both size semantics, KD-132b malformed-map no-crash + survival, KD-133 spec-ordered flow credit, KD-131 SasVerifier honors a floor-valid configured key.

## Disk-drift repair (disclosed, no diff vs HEAD)

`verification/ts/fix4.probe.cjs` on disk failed to parse on node 26 ("await is only valid in async functions", line 186): a trailing `// SLEEP-CLASS: POLL-STEP` comment swallowed the closing `});` of the sendable-timeout Promise executor. The lane repaired the working-tree copy by moving the marker after the `});` — the repaired content is byte-identical to HEAD (d2825dc6 already contains the fixed line; the disk copy had drifted). `git status` on the file is clean; nothing committed for it. Marker-comment-swallowing-closer is a real hazard class of the SLEEP-CLASS annotation convention; named here for the registrar.

## Verdicts

- KD-131 **CLOSED-WITH-RECEIPT** (re-witnessed; close-condition arm 1 satisfied: floor-valid configured key, real CBS put-token 200 on a live broker).
- KD-132 **CLOSED-WITH-RECEIPT** (re-witnessed; map32 decodes at both size semantics per the triage court, malformed body → typed 400, connection survives).
- KD-133 **CLOSED-WITH-RECEIPT** (re-witnessed; spec-ordered flow grants credit on the live broker, wire witness postdating the newest shim mtime).

No pinion needed; no row left OPEN or UNSUPPORTED. No wire-compat pinion touched (SASL ANONYMOUS, descriptor 0x44, attach arity, .NET-GUID lock tokens, EH fixed partitions all untouched).

## Replay

```bash
export PATH="$HOME/.asdf/shims:$PATH" MIX_BUILD_ROOT=_build-kdamqp
SMALT_FIX4_BLOCK=b89 node verification/ts/fix4.probe.cjs        # expect TOTAL pass=6 fail=0, exit 0
mix test test/integration/amqp_kd131_133_triage_test.exs        # expect 7 passed, 0 failures
```

Block b89 left DOWN? — the probe downs its block at start but does not sweep at end; run `scripts/substrate-ctl down --block b89 --mode sweep` to reclaim.

## Disclosure: concurrent register edits swept into commit 9b7c388a

The commit (path-scoped to the register) also landed concurrent in-flight edits to rows KD-147, KD-148, KD-149, KD-150, KD-151, KD-152 — another lane was mid-edit on KNOWN_DIVERGENCES.md when I committed; `git commit -- <path>` commits the file's whole working-tree state. Those rows' edits are committed intact and unmodified; owners should confirm their content in 9b7c388a and treat this receipt as the attribution pointer.
