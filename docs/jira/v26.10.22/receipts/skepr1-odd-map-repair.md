# Receipt: SKEP-R1 — BK-SKEP F1 repair (odd map element count typed refusal)

**Standing**: ALIVE
**Context**: solo
**Lane**: SKEP-R1, repo /Users/sac/smalt, MIX_BUILD_ROOT=_build-skepr1
**Subject**: `lib/smalt/messaging/amqp10/frame_decoder.ex` (`map_exact/3`),
court `test/internal/wire_exp4_court_test.exs`

## Defect (from bkskep-amqp10-skeptic.md F1)

`pairs/1` has only `[]` and `[k, v | t]` clauses; an odd element count in a
0xC1/0xD1 map constructor (spec-invalid, slice exact) raised an untyped
`FunctionClauseError` through public `decode_frame/1` — falsifying the
wire-exp4 "decode never raises on remote input" claim. `pump_frames/2`
(amqp10_connection.ex:162) has no rescue, so a hostile peer kills the
connection process untyped.

## Repair

One clause-class in `map_exact/3` (frame_decoder.ex:415-424): even-length
guard on the taken list; odd lists now answer `{:error, :bad_element}`
(module convention) instead of falling into `pairs/1`:

```elixir
defp map_exact(count, elems, outer_rest) do
  case take_exact(count, elems, outer_rest) do
    # spec-invalid odd element count must be a typed refusal, never a raise
    # (BK-SKEP F1: pairs/1 has no odd-list clause).
    {:ok, list, rest} when rem(length(list), 2) == 0 -> {:ok, Map.new(pairs(list)), rest}
    {:ok, _, _} -> {:error, :bad_element}
    {:error, _} = err -> err
  end
end
```

## Court legs added (wire_exp4_court_test.exs)

`BK-SKEP F1: spec-invalid odd element count in maps answers typed error,
never raises` — three legs, all previously `{:RAISED, :error, :function_clause}`
per the skeptic probes:

- `0xC1, 2, 1, 0x40` (count=1, single nil) → `{:error, :bad_element}`
- `0xD1, 5::32, 1::32, 0x40` (count=1, single nil) → `{:error, :bad_element}`
- `0xC1, 4, 3, 0x40, 0x40, 0x40` (count=3) → `{:error, :bad_element}`

Non-vacuity (falsifier): revert the even-length guard and these legs flip
from typed `{:error, :bad_element}` to untyped `FunctionClauseError` — the
witnessed pre-repair behavior (skeptic receipt, probe5.exs output). The legs
are the flip.

## Verification (real output)

```
$ MIX_BUILD_ROOT=_build-skepr1 mix test test/internal/wire_exp4_court_test.exs
Running ExUnit with seed: 744968, max_cases: 32
.........
Finished in 0.03 seconds (0.03s async, 0.00s sync)
Result: 9 passed

$ MIX_BUILD_ROOT=_build-skepr1 mix test test/integration/amqp10_crash_only_court_test.exs
Finished in 25.1 seconds (0.00s async, 25.1s sync)
Result: 8 passed
```

Both courts green at HEAD+repair. Moduledoc claim "decode never raises on
remote input" restored for the map-constructor class; connection-level
crash-only behavior unchanged (8/8 regression).

## Not done (out of scope)

F2 (out-of-range declared sizes mislabeled `:truncated_frame`) is cosmetic
and spread across ~10 fallback clauses — not a one-clause change; left as-is
per lane scope.
