# r-i13: ERROR_CODES extractor blind-spot closed (lane I13)

Standing: **ALIVE** — generator sourcing fixed, drift-fence green, doc test green on the lane build root.

Closes the v26.10.16 carried park "ERROR_CODES extractor blind-spot (2026-10-16, lane 10 wrap-docs)" and the sibling "ERROR_CODES drift" park: `scripts/gen_error_codes.py` now sources **PolicyViolation** (from `lib/smalt/policy.ex` inline deny envelope) and **InvalidEventGridEvent** (from `lib/smalt/egress_router.ex` EG1 gate) and renders both into the generated `docs/ERROR_CODES.md`.

## Command output

```
$ python3 scripts/gen_error_codes.py --check
docs/ERROR_CODES.md up to date
EXIT=0
```

```
$ MIX_BUILD_ROOT=_build-lane13 mix test test/error_codes_doc_test.exs
Running ExUnit with seed: 536483, max_cases: 32
Excluding tags: [:amqp_wire]
.......
Finished in 0.2 seconds (0.00s async, 0.2s sync)
7 tests, 0 failures
EXIT=0
```

## Generated-doc witness

```
docs/ERROR_CODES.md:40: | arm-gateway | 400 | PolicyViolation | lib/smalt/policy.ex:490 | ...
docs/ERROR_CODES(generator lines): lib/smalt/policy.ex:10, :205, :209, :426 ; lib/smalt/egress_router.ex:395 sourcing
docs/ERROR_CODES.md:46: | egress | 400 | InvalidEventGridEvent (EG1 schema gate) | lib/smalt/egress_router.ex:3119 | ...
```

## Ledger strike

`docs/jira/v26.10.16/WRAP_LEDGER.md` §Carried parks: the ERROR_CODES drift park and
the ERROR_CODES extractor blind-spot park are struck with a DONE marker citing
this receipt (append-only edit by this lane per lease).
