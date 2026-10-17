# r200d — KD-68 selector-filter implementation (lane283 repair)

Standing: **ALIVE** (witness exit 0, 4/0 falsifier PASS; tests 39/0 wire tier on lane tree)

Subject: `/Users/sac/smalt` @ main, uncommitted working tree, lane build root `_build-lane283`

- KD row: KD-68 (EH selector-filter ignored) — falsifier r200c FIRED (3 fail).
  **Register NOT flipped** (per lane order; `scripts/kd_flip.py --apply` left to the
  coordinator now that the witness receipt postdates the shim).
- Falsifier harness: `/tmp/smalt-lane274/witness-run.mjs` (real `@azure/event-hubs`
  6.0.4 over real AMQP wire, self-booted substrate 39295/39296/39297).

## Root cause

`eh_parse_event_position/2` in `lib/smalt/messaging/amqp/connection.ex` matched only
the EXCLUSIVE operator (`>`): regex `~r/amqp\.annotation\.(x-opt-[a-z-]+)\s*>\s*'…'/`.
The 6.x SDK `startingPosition {sequenceNumber: 2, isInclusive: true}` emits the
INCLUSIVE form `amqp.annotation.x-opt-sequence-number >= '2'`, so the parse returned
nil → no cursor → `deliver_eventhubs` delivered from cursor 0 unconditionally. The
KD-68 attach/apply machinery already existed; the operator was the gap.

## Change

`lib/smalt/messaging/amqp/connection.ex`:

1. Regex widened to `\Aamqp\.annotation\.(x-opt-[a-z-]+)\s*(>=?)\s*'([^']*)'\z` —
   **anchored full-match**, so a compound clause like `… >= '2' AND body LIKE '%x%'`
   is refused, not prefix-partially-matched (a partial match would have re-created
   the same silent-pass-through vacuity the falsifier caught).
2. Inclusive positions normalize to the exclusive floor (n-1 / ms-1) so delivery
   keeps `seq > after_seq` semantics; `eh_pos/3` guards nil parse results
   (ArithmeticError guard; the old `eh_event_position(nil,_)` clause removed).
3. `eh_apply_selector_filter/3` returns `{:ok, link} | {:error, selector}`: a
   present-but-unparseable selector → attach echo + typed detach
   `amqp:not-implemented / SELECTOR_UNSUPPORTED: <clause>` — never silent
   pass-through. `@latest` is honored only in the exclusive form (SDK shape).

`test/amqp/selector_epoch_test.exs` (+2 tests, `:amqp_wire`):

- inclusive `>=` selector starts AT n (first delivered seq == 2 for `>= '2'`,
  [2,3] delivered) — the r200c falsifier shape in-process.
- unsupported selector → typed detach `amqp:not-implemented` /
  `SELECTOR_UNSUPPORTED`, attach echo first, and zero transfers after a subsequent
  flow.

## Witness (exit 0)

```
$ node /tmp/smalt-lane274/witness-run.mjs
[falsifier] SDK selector expected on the wire: "amqp.annotation.x-opt-sequence-number >= '2'"
[falsifier] sent 4 events to partition "0" (expected seq 1..4); selector position n=2
[falsifier] delivered 3 events; sequenceNumbers=[2,3,4]; bodies=["kd68-e2","kd68-e3","kd68-e4"]
[PASS] kd68-first-delivered-seq-gte-n  (first=2, n=2)
[PASS] kd68-no-events-before-n  (seqs=[2,3,4])
[PASS] kd68-inclusive-boundary  (first seq expected exactly 2 (isInclusive), got 2)
[falsifier] control (fresh conn, earliest): seqs=[1,2,3,4]
[PASS] kd68-control-earliest-receives  (got 4)
=== FALSIFIER SUMMARY: 4 pass / 0 fail ===
[witness-run] probe=0
```

Witness exit code: 0.

## Test receipts (embedded output)

```
$ MIX_BUILD_ROOT=_build-lane283 mix test --include amqp_wire \
    test/amqp/selector_epoch_test.exs test/amqp/event_hubs_test.exs
.......................................
Finished in 3.5 seconds (0.00s async, 3.5s sync)
39 tests, 0 failures

$ MIX_BUILD_ROOT=_build-lane283 mix compile --warnings-as-errors
Compiling 1 file (.ex)
Generated smalt app
```

Broad `test/amqp` offline sweep: 322 tests, 1 failure —
`queue_store_test.exs:332 (R142)` ArgumentError `:smalt_sb_locks` ETS table missing in
setup, **pre-existing async isolation flake** (passes 52/0 when the file runs alone;
unrelated surface — the selector change touches only the EH attach/deliver path).

## Epoch contract

`test/amqp/selector_epoch_test.exs` epoch tests passed on the quiet tree (lane281
381/0) and pass here — enforced; no epoch edits made (only-touch-what-fails).

## Compile-freeze disclosure

A concurrent lane landed `deliver_eventhubs_aggregate/3` into connection.ex (my owned
file) mid-task; its `%{link2 | eh_link_cursor: seq}` update syntax KeyError-crashed the
connection GenServer (kd76 test, `key :eh_agg_cursors not found`). Minimal unblock fix
applied under the SLA at that site: `Map.put/3` instead of update syntax for
`eh_link_cursor`/`eh_agg_cursors` (link maps do not pre-carry those keys), with a
`lane283 compile-freeze unblock (disclosed)` comment. No other lane files touched.

## Replay

```
MIX_BUILD_ROOT=_build-lane283 mix test --include amqp_wire test/amqp/selector_epoch_test.exs test/amqp/event_hubs_test.exs
node /tmp/smalt-lane274/witness-run.mjs
```
