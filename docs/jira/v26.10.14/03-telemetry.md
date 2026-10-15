# V261014-03 — Telemetry: counter summing, dead GenServer call, key-shape contract, failure-law alignment

- **Release:** v26.10.14
- **Work order:** V261014-03
- **Files owned:** `lib/smalt/telemetry.ex`, `test/telemetry_test.exs`, `test/admission_projection_test.exs`
- **Related witnessed failure:** `test/admission_projection_test.exs:285-290` — `FunctionClauseError` when `telemetry_total/2` matches `{{name, _meta}, _n}` against a 3-tuple bandit key.

## Background

`Smalt.Telemetry` attaches a handler to `[:bandit, :request, :stop]` plus smalt-native events, normalizes bandit spans, and funnels counts into `Smalt.Telemetry.RollingCounters` (ETS-backed, minute-scoped rolling window). Four defects found in release review.

## Findings (verified, with line numbers)

### F1 — `dump/0` overwrites instead of sums across minute windows
- `lib/smalt/telemetry.ex:241`. `full_key = {now_minute(), key, :self}` (:201) is minute-scoped; `recent?/2` (:265) admits current + previous minute.
- `dump/0` folds with `into: %{}, do: {k, n}` — when the same logical key exists in two minute windows the later silently **overwrites** the earlier: order-dependent undercounts (the substrate for `telemetry_total/2`).

### F2 — dead no-op `handle_call({:bump, _key, _minute})`
- `lib/smalt/telemetry.ex:233-236`. Replies `:ok` but writes nothing — any caller silently loses the count. Inline `bump/1` (:194-204) is the real write path.

### F3 — key-shape contract violation (bandit 3-tuples vs documented 2-tuples)
- `dump/0` @doc (:206-210) claims keys are `{event_name, metadata}` tuples; `handle_event/4` (:82-91) emits `{:bandit_request_stop, route, status}` 3-tuples (:84) and `{:bandit_request_stop, :error}` 2-tuples (:87). `route`/`status` may be `nil` (missing-`conn` error-path spans, :107-113) — **by design**, pinned by `test/telemetry_test.exs:104-114`.
- `test/admission_projection_test.exs:285-290` filters with `{{name, _meta}, _n}` — the 3-tuple raises `FunctionClauseError` (the witnessed failure).
- **Decision (minimal diff):** make the test filter **total**, fix `dump/0` summing, remove the dead call, make the @doc describe the real contract. Do NOT reshape bandit keys (churn; contradicts the pinned nil-route test).

### F4 — inconsistent failure laws (documentation-only)
- `OcelEmitter` never raises (`ocel_emitter.ex:26-28`); `RollingCounters.bump/1` fails closed raising on missing table (:195-203); `Smalt.Telemetry.handle_event/4` unguarded (:82-91). Each locally defensible; state the law in the moduledoc, change no behavior.

## Changes

### C1 — `dump/0` sums across windows (F1)
Replace the comprehension in `handle_call(:dump, ...)` (:240-243):

```elixir
counters =
  for {{m, k, _}, n} <- :ets.tab2list(table), recent?(m, now),
      reduce: %{} do
    acc -> Map.update(acc, k, n, &(&1 + n))
  end
```

### C2 — remove the dead call (F2)
Delete `handle_call({:bump, _key, _minute}, ...)` (:233-236). Verify with `grep -rn '{:bump,' lib test` that no caller exists; if one does, delegate to `bump/1` instead of deleting.

### C3 — honest @doc + failure-law note (F3, F4)
Rewrite the `dump/0` @doc: keys are `{event_name, metadata}` for smalt-native events, `{:bandit_request_stop, route, status}` for bandit stops (2-tuple `{:bandit_request_stop, :error}` for the 4xx/5xx bucket); `route`/`status` may be `nil`; counts summed across the two-minute window. Add a moduledoc note on the failure law (emitters never raise; `bump/1` fails closed; `handle_event/4` unguarded by design).

### C4 — total filter in `admission_projection_test.exs:283-290` (F3)

```elixir
defp telemetry_total(dump, event) do
  dump
  |> Enum.filter(fn
    {[:smalt, ^event], _n} -> true
    _ -> false
  end)
  |> Enum.map(fn {_k, n} -> n end)
  |> Enum.sum()
end
```

The catch-all `_ -> false` alone fixes the crash (bandit 3-tuples fall through harmlessly).

### C5 — sum + contract test in `telemetry_test.exs`

```elixir
test "dump/0 sums the same key across minute windows" do
  table = :smalt_rolling_counters
  now = System.system_time(:millisecond) |> div(60_000)
  :ets.insert(table, {{now - 1, {:bandit_request_stop, "/x", 200}, :self}, 3})
  :ets.insert(table, {{now, {:bandit_request_stop, "/x", 200}, :self}, 4})

  assert Telemetry.dump()[{:bandit_request_stop, "/x", 200}] in [7]
end
```

(Seeded counts persist app-lifetime — use a distinctive key; if bleed-through is a concern, assert on a baseline delta consistent with the file's existing convention.)

## Acceptance criteria

1. `mix test test/telemetry_test.exs test/admission_projection_test.exs` — green.
2. Same key in two minute windows sums (3 + 4 = 7).
3. No `FunctionClauseError` on bandit 3-tuple keys regardless of shuffle order.
4. No caller of the `{:bump, key, minute}` GenServer message remains (grep clean).

## Falsifier

Revert C1 — the C5 sum test must fail (returns 4 or 3, not 7). If it still passes, the test is not probing the cross-window path.

## Non-goals

- Reshaping bandit keys; changing any failure behavior in OcelEmitter/bump/handle_event (F4 is documentation-only).
