# Receipt — R16 (AMQP target composite: 7-field arity for azure _pyamqp)

- **Subject:** `lib/smalt/messaging/amqp/frame_codec.ex` @ working tree (v26.10.16 repair wave W2)
- **Standing:** PASS at the frame_codec tier; cross-tier conflict with the 14-field attach pin recorded under R43
- **Date:** 2026-10-15, witnessed by the W2 docs lane

## Subject files

- `lib/smalt/messaging/amqp/frame_codec.ex` — `:target` role now emits the
  7-element composite (address, durable, expiry, timeout, dynamic,
  dynamic_node_properties, capabilities — azure `_pyamqp` Target namedtuple
  shape); `:source` keeps the 8-element extended form (distribution-mode6,
  filter7). Also decodes/encodes `apache.org:selector-filter:string`
  (KD-68 / GAP-A2-01).

## Verification (2026-10-15, W2 docs lane, unedited output — freeze-clear re-run)

```
$ mix test test/amqp/frame_codec_test.exs --include amqp_wire > /tmp/r16b.out 2>&1; echo "fc-exit=$?"; tail -2 /tmp/r16b.out
fc-exit=0
40 tests, 0 failures
```

## Cross-tier note (recorded, not fixed by this lane)

`test/amqp/pyamqp_parity_test.exs` still pins ALL attaches at 14 wire
fields; with the 7-field target landed it fails:
`attach wire arity not exactly 14: [7, 10, 10, 5, 5]`. See
`receipts/r43-amqp-044-pin.md`. CLI pytest was NOT run (needs substrate +
two venvs — not cheap; recorded as not exercised).
