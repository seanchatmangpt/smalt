# w6af — Event Grid advanced filters (w6af-eg-advanced-filters)

**Standing:** PARTIAL_ALIVE (standalone all-green; full-tree compile + census at integration)

Date: 2026-10-20
Lane: w6af (wave-6 fan-out, coordinator dispatch)

## Landed

- `lib/smalt/messaging/eg_advanced_filters.ex` (NEW): ARM advancedFilters evaluation —
  15 operators (string equals/not-equals/in/not-in/begins-with/ends-with/contains;
  number in/not-in/<,<=,>,>=; boolEquals) over the ARM path syntax
  (`data.key1.key2`, `data.arr[0]`), envelope attributes (subject/eventType/eventTime/
  id/topic/dataVersion), typed ArgumentError refusals (unknown operator / missing key /
  values-not-list) mirroring real EG's subscription-create validation, no atom minting
  from filter-controlled input (explicit atom-key spellings).
- `lib/smalt/messaging/event_grid.ex` (additive, no w5J clause restructure):
  `subscribe/4` opts `:advanced_filters` (validated at subscribe, typed-refused),
  filters stored on the subscription (recovery path preserves them), enqueue-time
  filter gate — non-matching events are never queued for a filtered subscription
  (synchronous decision inside the publish GenServer call; other subscribers
  unaffected; dedup key stays topic-global).

## Witness (real output, exit 0)

Replay: `elixir -pa /tmp/w6af_ebin -pa _build-lane-w6af/dev/lib/jason/ebin tmp/w6af_witness.exs`

- UNIT: 34/34 PASS — every operator hit+miss, nested `data.k1.k2`, array `data.arr[0]`,
  missing-key no-match, multi-filter AND hit/reject.
- REFUSALS: 4/4 PASS — unknown operator / missing operator / missing key /
  values-not-list all typed ArgumentError.
- ENGINE: 6/6 PASS — subscribe with filters + unfiltered control:
  - matching event → both delivered (envelope + aeg-* sys props intact, delivery-count 1)
  - severity miss → filtered subscriber pending stays 0 while control receives
  - stringIn region miss → also filtered out
  - both legs pass → delivered, delivery-count 1
  - unfiltered control received all 4 events
  - malformed filters → subscribe raises ArgumentError ("unknown operator")

## Defects found + fixed during the lane (real, witness-caught)

1. `path_lookup/2` received the dotted path STRING instead of the segment list —
   every `data.*` filter silently never matched. Found by unit case [0] going red
   (Chicago: the witness caught it, not review). Fixed with a `split_path/1` segment
   parser (dot segments + `[n]` indices).
2. `boolEquals` compared the normalized STRING against a boolean — always false for
   boolean data fields. Fixed with `to_bool/1` bridging "true"/"false" spellings.
3. `event_grid.ex` referenced `EgAdvancedFilters` unaliased — UndefinedFunctionError
   at subscribe. Fixed (alias added).
4. Two generation-corruption artifacts in this lane's own drafts (duplicate
   GenServer.call, malformed witness cases) — caught by compile/grep sweep before
   landing; final files verified on disk.

## Typed deferral (integration window)

Full-tree `mix compile --warnings-as-errors` remains BLOCKED by foreign in-flight
files across the whole lane (cosmos.ex dup-clause, egress/Observability.ex mid-write
— the w6R router-split lane is actively landing delegator modules; owners repairing
within the SLA). My lane files compile clean standalone:

- `elixirc --warnings-as-errors eg_advanced_filters.ex` → exit 0, zero warnings
- `event_grid.ex` compiles clean with only expected undefined-module warnings for
  out-of-lane deps (Jason/Store/BlobStorage off-path) — zero errors

Internal tier + census run at the quiesced integration window
(the same window that replays w6l/w6o/w6s/w6i-2 wire witnesses).

No git operations. No Process.sleep (the engine gate is synchronous inside the
publish call; receives are 2s-bounded, no polling loops).
