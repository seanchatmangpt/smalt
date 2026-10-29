# BK-80: Monitor.Metrics raw_rows match-shape fix + blast-radius topology reconcile

**Standing: ALIVE** — verified on the exact subject described below. `Context: solo`

## Diff summary

### 1. `lib/smalt/monitor/metrics.ex` — row-shape match fixes (3 sites, one bug class)

All three read sites destructured rows against a `{r, m, b}` 3-tuple face, but the real
`:ets.insert` shape (same file, `record/4` / `merge/2`) is
`{{resource, metric, bucket}, count, sum, max}`:

- `raw_rows/0` — matched `{r, m, b}` (the key face) and raised
  FunctionClauseError on any non-empty table (BK-45 finding). Now matches
  `{{r, m, b}, c, s, mx}` directly.
- `series/5` — the row filter matched `{r, m, _b}` → silently matched nothing →
  the metrics envelope was always empty (latent, same class as raw_rows).
  Now `Enum.flat_map` over the 4-tuple rows with the window/prefix/metric
  guard inside the guard.
- `handle_info(:prune, ...)` — iterated `table_rows` matching `{_r, _m, _b} = key`
  and then deleted with the FULL ROW as the :ets.delete key (double defect:
  generator never matched, and delete needs the key element, not the row).
  Prune was therefore a silent no-op. Now matches `{{_r, _m, b}, ...} = row`
  with `b < cutoff` and deletes with `elem(row, 0)`.

The BK-33 warm-restart stale-table-delete in init/1 is untouched (preserved per
lane contract). No clause in lib/ removed.

### 2. `test/internal/plane_blast_radius_test.exs` — topology reconcile + raw_rows leg

- Topology leg: the frozen `assert integration_ids == [Smalt.AmqpBroker]` pin
  (broken session-externally at BK-45 run B by the SPOF-B/A-2/A-4 lane adding
  `{Smalt.Messaging.EventHubs.Server, :default}` and
  `{Smalt.Messaging.EhGeoDr, :default}` supervised children to
  `Smalt.Plane.IntegrationSupervisor` — legitimate, `integration_supervisor.ex`
  `eh_state_children/0`) is replaced by invariant assertions:
  `refute Smalt.Store in integration_ids` (AZB-17 full-boot ownership law),
  plus membership asserts for `Smalt.AmqpBroker`,
  `Smalt.Messaging.EventHubs.Server`, `Smalt.EhGeoDr` (EhGeoDr module name
  is `Smalt.Messaging.EhGeoDr`; both EH owners now supervised). A
  session-external lane concurrently normalized the child ids via a
  `{mod, :default}` → `mod` mapping in the same leg (disclosed here per the
  compile-freeze disclosure law; consistent with the invariant form).
- New court leg: "raw_rows: non-empty accumulator table returns
  {key => {count, sum, max}} without raising" — seeds a REAL
  `[:smalt, :egress, :refused]` telemetry sample, bounded-polls on the real
  table (`metrics_row_present?/1`), then calls the public `raw_rows/0` and
  asserts a non-empty map with a count >= 1 and sum >= 1.0 on the
  EgressRefused row. No sleeps, no mocks.

## Children changed vs the test's frozen list

| child id | status |
|---|---|
| `Smalt.AmqpBroker` | unchanged (present) |
| `Smalt.Messaging.EventHubs.Server` | NEW (SPOF-B/A-2/A-4 lane, `eh_state_children/0`) |
| `Smalt.Messaging.EhGeoDr` | NEW (same lane, `eh_state_children/0` |

## Court output

Elixir 1.20.4-otp-29 (asdf, resolved from .tool-versions). Cold fresh build
root `_build-bk80` (full dep compile, exit 0). One transient mix
`Mix.Sync.Lock` `File.open!` crash on the shared lock cache on the first test
attempt (concurrent-lane contention, not in BK-80 files); retry was clean.

```
MIX_BUILD_ROOT=_build-bk80 mix compile        # exit 0 (cold root, all deps)
MIX_BUILD_ROOT=_build-bk80 mix test test/internal/plane_blast_radius_test.exs
#   Finished in 1.2 seconds ... Result: 6 passed  — exit 0
```

All legs green including BK-45's heir-parity kill court (5 pre-existing legs
+ the new raw_rows leg = 6). The topology leg passes under the current
supervision tree.

## Notes

- Verify command as dispatched: `MIX_BUILD_ROOT=_build-bk80 mix test
  test/internal/plane_blast_radius_test.exs` — exit 0.
- No commits made, per lane contract.
