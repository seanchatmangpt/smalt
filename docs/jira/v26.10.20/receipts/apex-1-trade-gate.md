# Receipt — APEX-1: 1,024-actor pre-trade settlement gate

- Date: 2026-10-21
- Lane: APEX-1 (bench-runner)
- Repo (absolute): /Users/sac/smalt
- Files owned/written:
  - /Users/sac/smalt/popcorn_demo/lib/popcorn_demo/apex_trade.ex (new)
  - /Users/sac/smalt/popcorn_demo/test/apex_trade_test.exs (new)
  - /Users/sac/smalt/popcorn_demo/bench/apex_trade.jsonl (new, 5 rows)
  - /Users/sac/smalt/popcorn_demo/scripts/apex_trade_emit.exs (new, emitter)
  - /Users/sac/smalt/docs/jira/v26.10.20/receipts/apex-1-trade-gate.md (this)
- No git (per task).
- Build root: `popcorn_demo/_build-apex1` (lane lease; coordinator reclaims).

## Standing: ALIVE (host-side, measured; cook not run — coordinator's)

## Scenario composition (witnessed seams only)

1. **HSM-sign leg** — LiveKeyops sign path on the LIVE substrate: KD-15
   tokenless challenge (401 + `www-authenticate` -> STS bearer) -> EC
   create-or-reuse (`POST /keys/popcorn-key/create`, kty EC, crv P-256) ->
   `POST /keys/popcorn-key/sign` (api-version 7.4). Real `:gen_tcp` HTTP/1.1
   (no inets — same transport law as LiveKV). One signature, wire-level.
2. **CAS leg** — 1,024 actors race an atomic `_etag`-equivalent CAS on ONE
   margin record via Concurrency-style optimistic ETS CAS: atomic
   `:ets.insert_new` claim -> matched exists-check -> conditional update.
   Exactly 1 winner decrements margin and commits at version 1; 1,023 typed
   `{:cas_lost, :margin}` losers (412-equivalent). Pure in-memory,
   deterministic, fail-closed (`assert_gate/3` typed refusals, exercised).
3. **EH settlement leg** — the winner fires ONE AMQP 1.0 transfer over the
   real 5673 wire via the witnessed public seam
   `PopcornDemo.LiveEh.publish_events/1` (LiveEh sender pattern: SASL
   ANONYMOUS, sender attach `/eventhubs/popcorn-eh/partitions/0`, transfer ->
   broker `accepted` disposition). `{:ok, 1}` IS the broker settlement
   witness.

## Measured table (5 real runs, emit script output pinned above in session)

| run | wall_ms | sign_ms | cas_ms | settle_ms | winners | losers | committed | exceptions |
|-----|---------|---------|--------|-----------|---------|--------|-----------|------------|
| 1 | 23 | 8 | 10 | 5 | 1 | 1023 | true | 0 |
| 2 | 14 | 8 | 5 | 1 | 1 | 1023 | true | 0 |
| 3 | 18 | 8 | 9 | 1 | 1 | 1023 | true | 0 |
| 4 | 24 | 8 | 10 | 5 | 1 | 1023 | true | 0 |
| 5 | 16 | 8 | 7 | 1 | 1 | 1023 | true | 0 |

Canonical values: wall 14–24 ms (target ≤300 ms: MET, 12–21x headroom);
sign 8–9 ms; CAS 5–10 ms; settle 1–5 ms; **1 winner / 1,023 typed losers,
committed at final_version 1, every run**; exceptions 0 across all runs and
all legs; actor memory `:erlang.process_info(self(), :memory)` = 2,616 bytes
per actor (min=max=mean).

`just bench-machine` output:

```
{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}
```

Lane-pinned toolchain (the build+tests ran on this, PATH-pinned):
elixir 1.20.3-otp-28 / OTP 28.3 (`~/.asdf/installs/elixir/1.20.3-ocr-28`,
asdf `1.20.3-otp-28`; the `just bench-machine` elixir field reads the ambient
1.19.5 — the lane pinned 1.20.3 per task HOST toolchain law).

## Tests (Chicago — real collaborators, final-state asserts, no mocks)

```
MIX_BUILD_ROOT=_build-apex1 mix test test/apex_trade_test.exs
...
Finished in 0.1 seconds (0.00s async, 0.1s sync)
Result: 9 passed
```

- CAS invariant: 1,024-actor gate -> exactly 1 winner, 1,023 typed
  `{:cas_lost, :margin}` losers, committed margin-1 @ v1, repeatable across 3
  fresh races; loser partition exact (winners+losers == n); typed shapes.
- Fail-closed law exercised: `assert_gate/3` refuses a 0-winner distribution
  (`{:error, {:winner_count, 0}}`) and a corrupted final row
  (`{:error, {:bad_final_row, ...}}`).
- Live legs (loud skip-if-down, real substrate): sign leg returns one real
  ES256 signature, repeatable fresh payloads; settle leg fires one AMQP
  transfer settled by the broker; full `run/0` under the 300 ms budget.

## Fail-closed witnesses (real, in-session)

- **Pre-seed CAS bug**: the harness initially pre-inserted the margin row, so
  EVERY actor's atomic claim lost -> `{:error, {:not_deterministic,
  {:winner_count, 0}}}` refusal instead of a coerced pass. Fix: no pre-seed
  (the atomic `insert_new` claim IS the CAS). The typed refusal fired exactly
  as designed before the fix.
- **RS256 premise rot**: the task pinned RS256; the live substrate now
  answers EC create with 200 (`LiveKeyops.run/0` -> `OK(ES256:verified)` —
  the LiveKeyops disjunctive law CLOSED), and RS256 on the EC key answers
  typed `400 InvalidAlgorithm` (measured). The sign leg witnesses ES256, the
  currently-live witnessed path, and the rotation is recorded here.
- **Fresh-substrate KeyNotFound**: after the substrate bounced, the sign leg
  failed typed `404 KeyNotFound` — fixed by adding the create-or-reuse step.
- **Substrate-down typed skip witnessed live**: mid-run substrate loss
  produced `{:skip, "sign=SKIP(substrate-down(8443:econnrefused)); run 9>&-
  just substrate-up"}` — loud, never a faked pass.

## Machine / concurrency receipts (honest notes)

- `MIX_BUILD_ROOT=_build-apex1`; compile gated behind two sibling lanes'
  in-flight files (`apex_ratelimit.ex`, `apex_fanout.ex` — compile-freeze
  SLA, waited via bounded poll ~5 min each, both self-resolved; no edits to
  their files from this lane). 0 compile warnings from apex_trade.ex.
- Mid-run the shared substrate bounced (another lane's cycle); lane used
  `scripts/substrate.sh status` + waited on the flock (lock HELD by an
  in-flight boot, then UP, lock FREE). No port evictions; no pkill.
- Emitter: `/Users/sac/smalt/popcorn_demo/scripts/apex_trade_emit.exs`
  (warmup + 5 measured runs, appends to bench/apex_trade.jsonl).

## UNSUPPORTED context (scvd-ledger law)

Azure-tier dollar/throughput figures — 50k RU/s, HSM pool sizing, Event Hubs
Premium PU economics — are **UNSUPPORTED** context: this receipt measures the
local substrate only (loopback KV sign, in-memory ETS CAS, AMQP on 5673). No
Azure pricing, RU budgets, or HSM-pool claims are made or implied. The gap
between the measured host numbers and any Azure-tier projection is not
extrapolated here.

## Replay

```bash
cd /Users/sac/smalt/popcorn_demo
export PATH="$HOME/.asdf/installs/elixir/1.20.3-otp-28/bin:$PATH"
bash /Users/sac/smalt/scripts/substrate.sh status   # must be UP, lock FREE
MIX_BUILD_ROOT=_build-apex1 mix test test/apex_trade_test.exs
MIX_BUILD_ROOT=_build-apex1 mix run scripts/apex_trade_emit.exs
```
