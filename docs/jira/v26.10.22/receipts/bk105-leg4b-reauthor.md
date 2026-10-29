# BK-105 — leg4b re-author against the partitioned tree

**Standing: ALIVE** · Context: solo · Date: 2026-10-21 · Lane: BK-105 (test-authoring WO from BK-69r) · Build root: `_build-bk105` · Toolchain: asdf elixir 1.20.4-otp-29 / erlang 29.1.2 (repo `.tool-versions`)

## What was re-authored

`test/integration/store_partition_wire_regression_test.exs` — leg4b only, plus the stale
BK-69-era moduledoc disclosure paragraph (test-file prose only; no lib edits).

The old leg4b asserted pre-TTV-5 single-owner give-away semantics: it killed
`Process.whereis(Store)` (now the ENSEMBLE supervisor — Heir + 16 Partitions + Boot, not a
single owner) and asserted committed content was lost (`:error`) and rewritten with a
`"pinion"` corruption marker. Under the canonical partitioned tree that mechanism does not
exist as written (BK-69r receipt, probe witness); its content-intact guarantee is subsumed by
leg4a (partition-crash) + leg5 (journal-restart), both green.

The re-authored leg4b runs one real kill chain against the partitioned tree:

1. **(a) Heir hold** — real `Process.exit(owner, :kill)` of the Partition GenServer owning
   `t_a`'s stripe (`Smalt.Store.Partition.whereis_owner/2`); the table stays defined
   (`:ets.info != :undefined`) and direct reads keep serving the committed key through the
   Heir hold.
2. **(b) sibling service mid-kill** — a sibling table on a DIFFERENT stripe serves reads,
   `Store.put`, AND a serialized `Store.insert_new` (its own partition GenServer untouched)
   during the window.
3. **(c) reclaim zero-loss** — the supervisor respawns ONLY the crashed partition; the
   respawned owner re-adopts the Heir-held table (witnessed in the log:
   `Smalt.Store.Heir: holding table … (owner partition died)` → `Partition N: adopted 1
   table(s)`); the committed key is intact post-reclaim, writes resume, a serialized op
   routes through the reclaimed stripe. Zero key loss.
4. **(d) distinct full-ensemble guarantee, kept as its own witness** — with the journal sink
   up, sealed keys on both stripes (`JournalSink.seal/1`, frames >= 2) survive a REAL kill of
   the full ensemble supervisor via Boot replay (`wait_store_up` + bounded poll to
   `:all_recovered`). Leg5's mechanism, re-asserted on this file's key set.

Two tables are picked on distinct stripes via `Store.partition_of/1`; bounded polls only
(`SmaltTest.Internal.Poll.eventually/2`), no fixed sleeps. Keys are `store3-`-prefixed so the
existing `cleanup_keys/0` on_exit covers them.

## Commands / exits

```
MIX_BUILD_ROOT=_build-bk105 asdf exec mix compile                                        # exit 0 (warnings only)
MIX_BUILD_ROOT=_build-bk105 asdf exec mix test test/integration/store_partition_wire_regression_test.exs:760
                                                                                        # exit 0 — 1 passed, 5 excluded (leg4b solo)
MIX_BUILD_ROOT=_build-bk105 asdf exec mix test test/integration/store_partition_wire_regression_test.exs
                                                                                        # RUN 1: exit 0 — 6 passed
MIX_BUILD_ROOT=_build-bk105 asdf exec mix test test/integration/store_partition_wire_regression_test.exs
                                                                                        # RUN 2: exit 0 — 6 passed
```

Run outputs:

- leg4b solo: `22:42:20.545 info[] Smalt.Store: journal replay restored 2 frame(s) …` →
  `Result: 1 passed, 5 excluded`, EXIT=0
- full-file run 1: `Result: 6 passed`, EXIT_RUN1=0
- full-file run 2: `Result: 6 passed`, EXIT_RUN2=0

Witness log line from the partition-kill leg (run 1 full file):

```
22:42:09.029 warning[] Smalt.Store.Heir: holding table :smalt_appconfig (owner partition died)
22:42:09.030 info[] Smalt.Store.Partition 9: adopted 1 table(s)
```

## Contract compliance

- No lib edits (git status: test file + this receipt only).
- 2 consecutive full-file green runs on the lane build root `_build-bk105`.
- Not committed (per contract).
