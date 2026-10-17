# Receipt — config_keys (W1a ConfigKey projection replay fence)

- **Subject:** `/Users/sac/smalt` @ main, HEAD `650a8ff`
- **Standing:** PASS
- **Date:** 2026-10-17

## Subject files

- `lib/smalt/config.ex` (generated, DO-NOT-EDIT)
- `test/config_replay_identity_test.exs` (fence)
- `ggen-marketplace/packs/smalt-substrate-pack` (source ontology rows)

## Verification (2026-10-17, I2 lane, unedited output)

```
$ mix test test/config_replay_identity_test.exs ; echo "exit=$?"
Running ExUnit with seed: 722878, max_cases: 32
Excluding tags: [:amqp_wire]

....
Finished in 6.1 seconds (0.00s async, 6.1s sync)
4 tests, 0 failures
exit=0
```

## Non-vacuity

The fence is a real subprocess re-render: `mix run --no-start` re-projects
`lib/smalt/config.ex` from the pack and byte-compares against the on-disk
artifact, plus a pack-lock digest assertion. A hand-edit to `config.ex`
flips the byte-compare arm; a stale pack-lock flips the digest arm. Both
arms can exit 1 — the test is non-vacuous by construction (the mutation
arm is the SHIM-COURT flip, witnessed in the W1 receipts).
