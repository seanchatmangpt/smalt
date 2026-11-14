# smalt-20 baseline receipt

Standing: UNVERIFIED

## Status

No measurement was executed in this lane (builds/runs are coordinator-owned). No RSS figure is
reported, because a figure without command and exit code falsifies this receipt.

## Recipes found (not RSS probes)

- `just bench-machine` (15-bench.just): prints machine spec only.
- `just bench-report` (15-bench.just): aggregates bench JSONL into BENCH_RESULTS.md.
- `just test-stress` (28-stress.just): `mix test --include stress`.

No existing recipe measures peak/idle RSS; coordinator must sample the BEAM OS pid
(`ps -o rss= -p <pid>`) idle and during the stress run, with GCP+AWS surfaces enabled.

## Measurement slots (coordinator fills; two runs, idle RSS must agree within 2x)

| field | run 1 | run 2 |
|---|---|---|
| command | UNVERIFIED | UNVERIFIED |
| exit code | UNVERIFIED | UNVERIFIED |
| SHA | UNVERIFIED | UNVERIFIED |
| idle RSS (KB) | UNVERIFIED | UNVERIFIED |
| peak RSS (KB) | UNVERIFIED | UNVERIFIED |

## Disclosure (out of scope, not smalt results)

arcus pre-existing failures: gcp_emulator/sdlc HCL_UNSUPPORTED; nil deref at
/Users/sac/arcus/internal/gcp_emulator/sdlc/sdlc_test.go:153.

Depends-on smalt-18 (image to measure): see receipts/smalt-18-image.md.
