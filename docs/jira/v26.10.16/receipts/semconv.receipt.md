# Receipt — semconv (W2b semconv registry projection + YAML fence)

- **Subject:** `/Users/sac/smalt` @ main, HEAD `650a8ff`
- **Standing:** PASS
- **Date:** 2026-10-17

## Subject files

- `lib/smalt/telemetry/semconv/registry.ex` (projected from smalt-semconv-pack)
- `lib/smalt/telemetry/semconv/model/smalt.yaml` (semconv model)
- `test/semconv_replay_identity_test.exs` (replay fence)
- `test/semconv_test.exs` (YAML fence)

## Verification (2026-10-17, I2 lane, unedited output)

```
$ mix test test/semconv_replay_identity_test.exs test/semconv_test.exs ; echo "exit=$?"
Running ExUnit with seed: 475900, max_cases: 32
Excluding tags: [:amqp_wire]

....................
Finished in 6.8 seconds (0.00s async, 6.8s sync)
20 tests, 0 failures
exit=0
```

## Non-vacuity

The replay fence re-renders `registry.ex` from the
`ggen-marketplace/packs/smalt-semconv-pack` checkout (byte-compare +
pack-lock digest arms, as with the other fences). The YAML fence asserts
the hand-synced `model/smalt.yaml` covers the same attribute set the pack
projects — a registry/YAML divergence flips it. Both fences can exit 1;
the two files are proven consistent only while both arms hold.
