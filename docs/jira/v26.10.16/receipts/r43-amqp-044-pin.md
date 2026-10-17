# Receipt — R43 (0x44 sasl-outcome descriptor pin — parity tier)

- **Subject:** `test/amqp/pyamqp_parity_test.exs` / AMQP attach-shape pinions @ working tree (v26.10.16 repair wave W2)
- **Standing:** PARTIAL_ALIVE — one parity assertion conflicts with R16's landed 7-field target
- **Date:** 2026-10-15/16, witnessed by the W2 docs lane

## Subject files

- `test/amqp/pyamqp_parity_test.exs` — AMQP wire-parity court (opening-bytes
  / attach-shape pinions, incl. the 14-field attach and 0x44 sasl-outcome
  descriptor pins from the real-SDK censuses).

## Verification (2026-10-15, W2 docs lane, unedited output)

```
$ mix test test/amqp/pyamqp_parity_test.exs --include amqp_wire > /tmp/parity.out 2>&1; echo "exit=$?"; grep -B1 -A 12 "^  1) " /tmp/parity.out | head -16; tail -2 /tmp/parity.out
exit=2

  1) test pyamqp opening bytes (header + pipelined open/begin/cbs attaches) reach the attach exchange (Smalt.Amqp.PyamqpParityTest)
     attach wire arity not exactly 14: [7, 10, 10, 5, 5]
     code: assert Enum.all?(arities, fn n -> n == 14 end), "attach wire arity not exactly 14: #{inspect(arities)}"
3 tests, 1 failure
```

## Open seam (cross-lane, recorded not fixed)

The parity pin asserts every attach composite is 14 fields; R16's landed
7-field `:target` composite (azure `_pyamqp` Target namedtuple shape) makes
that assertion impossible. The pinion needs scoping (14-field applies to the
source/CBS attach family, not the target composite) — owned by the R16/R43
repair lanes + coordinator seam agreement in RESOLUTIONS.md. The claimed
"40 tests, 0 failures" belongs to `test/amqp/frame_codec_test.exs` (which
does pass 40/0 — see `receipts/r16-frame-codec-target-arity.md`), not to
this suite.
