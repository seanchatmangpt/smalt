# BK-ST4W — store4 (Erlang partition store) coexistence census + disposition

**Standing:** **ALIVE**
Context: solo
Date: 2026-10-22
Lane: BK-ST4W, `MIX_BUILD_ROOT=_build-bkst4w` (lease — coordinator deletes at integration)
Files owned/edited: `test/internal/store4_no_boot_test.exs` (new), `docs/jira/v26.10.22/STORE-DECOMPOSITION.md` (Standing section, disposition subsection), this receipt. No `lib/` or `src/` edits.

## Disposition

**store4 is DEAD/UNWIRED in production — retained as reference capital with its own court.** Not live-but-shadowed: no production face routes through it.

## Census (embedded, real grep output this session)

Call sites of `smalt_store*` — **zero in `lib/`, `test/` (ex-courts), `scripts/`, `mix.exs`**:

```
$ grep -rln "smalt_store" lib/ test/ scripts/
lib/smalt/store_tables.ex            # :smalt_store_read metadata atom (lines
                                     # 199/650) — a read-metadata tag, not the
                                     # Erlang store
lib/smalt/ash_extension/generated_persist.ex  # same atom, line 25
test/integration/ttv5_store_partitioning_court.exs  # line 162: comment naming
                                     # src/smalt_store_partition.erl as the
                                     # court-subject distinction (no call)
test/courts/court_store_partition_SUITE.erl
test/courts/court_vc_twins_lakehouse_SUITE.erl
test/courts/court_arm_router_SUITE.erl
test/courts/court_kafka_wormhole_proposer_SUITE.erl
test/internal/store4_no_boot_test.exs  # this lane's new pin (self-reference)
```

Non-court hits are namesakes/comments only — **zero call sites in `lib/`**.

Call sites inside `src/` (the Erlang family's own consumers):

| consumer | use |
|---|---|
| `smalt_eventhubs_kafka.erl` | `smalt_store:put_cas/get` (kafka/CE record journaling) |
| `smalt_proposer_gate.erl` | `smalt_store:start()` + put_cas/get (proposal seq) |
| `smalt_wormhole.erl` | `smalt_store:start()` + `smalt_store_heir:get_heir_pid()` |
| `smalt_arm_router.erl` / `smalt_arm_adapters.erl` | `ets:lookup(smalt_store:table_for(...))` |
| `smalt_digital_twins.erl` / `smalt_journal_sink_compat.erl` | put_cas/get via store facade |

Drivers of those consumers: **only `test/courts/court_kafka_wormhole_proposer_SUITE.erl`, `court_arm_router_SUITE.erl`, `court_vc_twins_lakehouse_SUITE.erl`** (grep over `lib/`, `scripts/`, `justfile*`: zero matches). `Smalt.Application` (`lib/smalt/application.ex`) starts no store4 child; `smalt_store_sup` is referenced outside `src/` only by the courts (their explicit dual-boot name-collision guard).

## Verification (real output, this session)

1. **Typed no-boot assertion, new test** — `MIX_BUILD_ROOT=_build-bkst4w scripts/fast_test.sh test/internal/store4_no_boot_test.exs`:

```
Result: 1 passed
[06:56:10] wall: 31s (build root: _build-ft-1ff28073)
```

(After the REAL self-booted production app: `whereis(:smalt_store_sup) == :undefined`; zero `:smalt_store_p0..15` tables live; `Smalt.Store` registered; `:smalt_appconfig` live — ensemble up, twin absent.)

2. **store4's own court re-run green on the current tree** (scratch `/tmp/store4court-bkst4w`, per the store4 receipt's verbatim commands):

```
== STORE-4 partition court ==
STEP 1 boot 16 partitions + heir: ok
...
STEP 9 zero-loss heir check (K4 survived): ok
STEP 10 post-recovery mutation + P5 integrity: ok
COURT RESULT: 4/4 PASS
EXIT=0
```

## Notes

- First test attempt hit a compile-freeze (another lane's in-flight
  `lib/smalt/powl2/compiler.ex` break); resolved by owner mid-window, retry
  green — no edit by this lane to that file.
- store3 vs store4: store3 = wire-regression court over the **Elixir**
  ensemble (production path); store4 = independent Erlang 16-partition
  decomposition (same crash/isolation laws, separate implementation, disjoint
  table namespaces; dual-boot collision guarded by the court SUITEs).
- Migration plan: none owed — store4 shadows nothing. Any future re-wiring
  of the `src/` consumers onto production surfaces is a new work order.

## Landing provenance (post-commit disclosure)

A coordinator checkpoint race split this lane's landing across three
commits: the test pin landed via checkpoint b17a90a3, the final receipt +
STORE-DECOMPOSITION.md disposition via checkpoint 477d88c5 (both verbatim,
confirmed byte-exact vs working tree). This lane's own commit eea36078 was
prepared with explicit paths but, by then, its three paths were already
committed — so it carries ONLY the coordinator's swept-in
`receipts/bkxpriv-exempt-verify.md` (landed verbatim under this lane's
message; content untouched, attribution mismatch only). No resets, no
rewrites; disclosed fix-forward per doctrine. Zero invented claims; all
verification receipts above were executed this session.
