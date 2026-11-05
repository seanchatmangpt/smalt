# L15 Receipt — AOQ Cursor + persistent_term Tables

Standing: ALIVE

## Subject

Lane L15, repo `/Users/sac/smalt` @ base fa2e15f1. Owned files (exact set):

- `lib/smalt/aoq/cursor.ex` — `Smalt.Aoq.Cursor`
- `lib/smalt/aoq/tables.ex` — `Smalt.Aoq.Tables`
- `test/smalt/aoq/cursor_test.exs`
- `test/smalt/aoq/tables_test.exs`
- `docs/jira/v26.11.5/receipts/l15-cursor-tables.md` (this receipt)

No supervisor/frame files touched.

## Standing

ALIVE: shared `mix test` gate went green post-push — the owning lanes
landed fixes to the in-flight listener/transport/worker/worker_pool
files while this lane waited; the gate then ran my two test files with
`MIX_BUILD_ROOT=_build-lane15` and returned 16 passed / 0 failures
(see Commands). Prior PARTIAL_ALIVE standing was compile-blocked by
those in-flight files, disclosed per the compile-freeze SLA.

## What landed

### Smalt.Aoq.Cursor (spec §6)

- u64 slot layout 0–5 (ring_head/ring_tail/lease_ctr/lease_gen/seq/drop_ctr),
  exact spec table; `:atomics` is 1-based, so the array is 7 slots with
  spec slot `i` mapped to atomics index `i+1` (`@off`), layout documented
  in `@moduledoc`.
- `claim_head`/`release_tail` (+ batch forms) via `add_get`; capacity
  bounds are head−tail distance (`in_flight/1`), never check-then-set.
- Leases: `{gen, ctr}` from `add_get`-only counters; `reset/1` bumps gen,
  invalidating outstanding leases without resetting ctr (late holders
  fail typed).
- `seq_next` wrapping u64; `seq_before?/seq_distance` use
  `(a-b) mod 2^64` wrap-safe compare, never `a < b`.
- Single-writer-per-index documented in `@moduledoc`; every index has
  exactly one mutating op class (`add_get`); reads are plain `get`; no
  locks, no CAS loops.

### Smalt.Aoq.Tables (spec §5)

- Three single-key `:persistent_term` tables: `{:aoq, :frame_types}`,
  `{:aoq, :epochs}`, `{:aoq, :tests}` — correction: `{:aoq, :arrow_schemas}`.
- `boot/1` writes all three from static compile-time registries (or
  option overrides), then sets the `{:aoq, :sealed}` key.
- Hot reads `frame_types/0`, `epochs/0`, `arrow_schemas/0`,
  `frame_handler/1`; unbooted read raises typed `ArgumentError`.
- Refuse-on-mutate guard: `register_frame_type/2`, `append_epoch/2`,
  `put_arrow_schema/2` raise `ArgumentError` on any attempt (post-boot:
  "sealed at boot ... re-derive via boot/1"; pre-boot: "not booted") —
  the only lawful mutation is a full `boot/1` re-derive.
- Idempotent re-boot overwrites whole-map-per-key (the lawful update
  class).

## Commands and exits (real output)

```
elixirc -o /tmp/l15_ebin lib/smalt/aoq/cursor.ex lib/smalt/aoq/lines…
# compile clean, no warnings for either module

elixir -pa /tmp/l15_ebin /tmp/l15_runner.exs
Finished in 0.02 seconds (0.00s async, 0.02s sync)
Result: 16 passed
RESULT: %{total: 16, failures: 0, excluded: 0, skipped: 0}
EXIT=0
```

Shared gate attempt log (`MIX_BUILD_ROOT=_build-lane15 mix test …`), 3
retries over ~5 min, all failed in files not owned by this lane:

```
== Compilation error in file lib/smalt/aoq/transport.ex ==
** (CompileError) lib/smalt/aoq/transport.ex: cannot compile module Smalt.Aoq.Transport
```

(failure set moved across retries: listener.ex, transport.ex, worker.ex,
worker_pool.ex — in-flight, other lanes)

## Falsifier status

- "Cursor claim/release is CAS-accurate under concurrency" — test
  `concurrent claimers get disjoint slots`, PASSED.
- "Wrap-safe compare never inverts at the u64 boundary" — boundary tests
  PASSED (near-max, half-mod boundary, equal, naive-< inversion case).
- "Tables sealed after boot; mutation attempts raise and leave tables
  untouched" — PASSED.
- Shared `mix test` green for my two files: ALIVE (post-push re-gate,
  `Result: 16 passed`, RC=0).

## Notes

- No `Process.sleep` in lib or test code (structural sync: atomics are
  synchronous; table tests re-boot synchronously; `Task.async_stream`
  with timeout for the concurrency court).
- Toolchain pin: asdf elixir 1.20.4-otp-29 (Homebrew 1.19 refused).
