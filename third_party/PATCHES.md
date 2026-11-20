# third_party patches

## cachex 4.1.1 (hex 574c5cd2...)

`lib/cachex/actions/stream.ex`: `@test entry(... modified: now() ...)` embedded a compile-time
wall-clock in the beam literals, so `Elixir.Cachex.Actions.Stream.beam` differed on every build.
Patched to use `SOURCE_DATE_EPOCH * 1000` when set (wall clock otherwise). Needed by the
FNOX-SJ-DETB-3 two-build gate (`scripts/repro-diff.sh`). Drop once upstream does the same.

## See Also

`scripts/repro-diff.sh` · fnox `docs/sjira/v26.11.18/receipts/FNOX-SJ-DETB-3.md`
