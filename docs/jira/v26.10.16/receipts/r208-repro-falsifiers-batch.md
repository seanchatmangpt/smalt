# Receipt — R208 (repro falsifier tests batch)

- **Subject:** `/Users/sac/smalt` @ main, working tree (lane 294, W11 docs lane)
- **Standing:** PASS (7 tests, 0 failures)
- **Date:** 2026-10-16
- **Audit coverage:** closes unaccounted-diff items 6–7 of the 2026-10-16
  pre-commit audit.

## What landed

Two reproduction-falsifier test files, both under `test/data_plane/`:

- **r177d_repro_test.exs** (`Smalt.DataPlane.R177dReproTest`) — repros the
  R177d blob **metadata-seeding** repair: metadata set on a PUT must
  survive a subsequent immutability PUT, a metadata PUT under legal hold
  must 409, legal_hold must survive an immutability PUT, and a concurrent
  hold-vs-immutability storm must show no lost updates. 4 tests covering
  metadata-preservation and WORM-interaction seeding into the blob policy
  table (`:smalt_blob_policy`).
- **r5_repair_repro_test.exs** (`Smalt.DataPlane.R5RepairReproTest`) —
  repros the **R5 blob hold/atom-safety** repair: `put_blob` create under
  legal hold returns `:worm_locked` (was: silently created), create is
  allowed again after hold release, and `parse_block_list_xml` maps all
  three block kinds without `to_existing_atom` (atom-creation safety).
  3 tests.

## Verification (2026-10-16, lane 294, unedited output)

```
$ MIX_BUILD_ROOT=_build-lane294 mix test test/data_plane/r177d_repro_test.exs test/data_plane/r5_repair_repro_test.exs
06:09:55.401 [info] [amqp] eh listener bound on port 63849
Running ExUnit with seed: 458211, max_cases: 32
Excluding tags: [:amqp_wire]

.......
Finished in 0.05 seconds (0.00s async, 0.05s sync)
7 tests, 0 failures
```

Both files read directly before receipting to confirm the repairs each
repros (grep of `defmodule`/`test "` heads, quoted above in What landed).
Standing PASS: green run against the current tree with the lane build
root.
