# smalt-05 gcp cloud-tasks and functions test pins

Standing: UNVERIFIED

## Problem

`/Users/sac/smalt/lib/smalt/gcp/cloud_tasks.ex` and `/Users/sac/smalt/lib/smalt/gcp/functions.ex`
exist, but `/Users/sac/smalt/test/gcp/` holds
no file for either (present: firestore, identity_plane, pubsub_*, run_logging_*,
secrets_kms_*, storage). `/Users/sac/smalt/docs/gcp-parity/GCP_WIRE_PARITY.md` rows are UNVERIFIED
(KD-GCP-05, `/Users/sac/smalt/docs/gcp-parity/KD-GCP-CANDIDATES.md`). Session observed `mix test
/Users/sac/smalt/test/gcp
/Users/sac/smalt/test/aws` 76 passed, which therefore covers neither surface.

## Acceptance

`mix test /Users/sac/smalt/test/gcp/cloud_tasks_test.exs
/Users/sac/smalt/test/gcp/functions_test.exs` exits 0 with
at least one test per public route in each module, real HTTP collaborators, no mocks.

## Falsifier

Mutate a route handler in `cloud_tasks.ex` (return 500); the new test must fail.

## Owned files

/Users/sac/smalt/test/gcp/cloud_tasks_test.exs, /Users/sac/smalt/test/gcp/functions_test.exs

## Depends-on

none

## Size

M

## References (path : LOC)

- /Users/sac/smalt/lib/smalt/gcp/cloud_tasks.ex : 96 lines
- /Users/sac/smalt/lib/smalt/gcp/functions.ex : 119 lines
- /Users/sac/smalt/docs/gcp-parity/GCP_WIRE_PARITY.md : 30 lines
- /Users/sac/smalt/docs/gcp-parity/KD-GCP-CANDIDATES.md : 13 lines
- /Users/sac/smalt/test/gcp/ : 9 files, 860 lines total
- /Users/sac/smalt/test/gcp/cloud_tasks_test.exs : NEW (0 lines, to be created; est. LOC: 80; ~1
  test per route at ~12 lines, modelled on 113-line storage_test.exs)
- /Users/sac/smalt/test/gcp/functions_test.exs : NEW (0 lines, to be created; est. LOC: 90; ~1 test
  per route at ~12 lines, modelled on 113-line storage_test.exs)

## Result

Standing: UNVERIFIED (nothing executed)

Files: /Users/sac/smalt/test/gcp/cloud_tasks_test.exs (~60 LOC), /Users/sac/smalt/test/gcp/functions_test.exs (~55 LOC).
Note: both modules are wire-free engines with no HTTP router, so tests call every public function against the real Store and real in-VM handler modules (no mocks).
Acceptance: cd /Users/sac/smalt && mix test test/gcp/cloud_tasks_test.exs test/gcp/functions_test.exs
