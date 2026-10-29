# w6ap — Azure Monitor metric alert rules

**Standing:** PARTIAL_ALIVE (module tier ALIVE; wire tier deferred behind the w6R router-split freeze)

Context: pair

## Landed
- `lib/smalt/monitor/metric_alerts.ex` (NEW, exclusive): alert-rule CRUD (PUT/GET/LIST/DELETE,
  case-insensitive sub/rg lookup), ARM wire shape
  (`Microsoft.Insights/metricAlerts`, location global, properties echo),
  typed 400s (:bad_operator | :bad_severity | :bad_window | :bad_threshold |
  :bad_metric_name | :bad_frequency | :bad_body); `evaluate/1,2` with
  injectable metric source defaulting to the REAL accumulator
  (`Smalt.Monitor.Metrics.series/5` read-only), breach → real
  `[:smalt, :monitor, :alert_fired]` telemetry firing, dedup law
  (one firing per rule per window bucket — new window re-fires, breach-stop
  does not), disabled rules skipped, heir'd ETS `:smalt_metric_alerts`
  (`{:heir, Process.whereis(:init), []}` 3-tuple).
- Router HOLD respected: zero router edits; 4-clause route draft staged at
  `tmp/w6ap/router_patch_draft.txt` for post-split application.

## Witness (real output, exit 0)
Replay: `ERL_LIBS=_build-coord/dev/lib elixir -pa tmp/w6ap_ebin tmp/w6ap_witness.exs`
    PUT_OK
    BAD_400S_OK
    GET_404_OK
    TELEMETRY_FIRED_OK observed=500
    DEDUP_SAME_WINDOW_OK
    NEW_WINDOW_REFIRE_OK
    RESOLVE_NO_FIRE_OK
    DEFAULT_SOURCE_SAFE_OK
    DELETE_404_OK
    W6AP WITNESS: ALL LEGS DONE

## Defects caught and fixed in-lane (real compiler/witness evidence)
1. `validate/1` passed the whole criteria map to `is_binary/1` — every PUT would
   400 `bad_metric_name`. Caught by witness leg 2, fixed, re-witnessed.
2. `:ets.update_element/3` positional write against a map-object record →
   "position out of range". Replaced with read-modify-write insert.
3. Illegal anonymous-fun guard (`when pred.(value)`) — compiler-caught.

## Verification notes
- Standalone strict compile: 0 errors (`elixirc` against `_build-coord/dev/lib`
  deps; metrics.ex compiled alongside — 0 errors). Full-tree
  `--warnings-as-errors` still BLOCKED by the w6R egress_router split
  (`deployments.ex` mid-flight earlier, `egress_router.ex` compile error at
  close-out) — foreign lanes' files, bounded-polled, not mine.
- Witness two corruption incidents in tmp scratch Writes (the wave's known
  Write-degradation class); chunked-heredoc rewrite, all 4 chunks
  syntax-checked before append.

## Integration falsifier
Re-run the witness replay on the post-split green tree; expected tail
`W6AP WITNESS: ALL LEGS DONE`. Flip PARTIAL_ALIVE → ALIVE when the full tree
strict-compiles with this module in it.
