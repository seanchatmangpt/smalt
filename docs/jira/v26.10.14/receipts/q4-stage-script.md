# Q-4 Receipt: stage_atomic_commits.sh

Lane: Q-4 (finish support). Subject: `scripts/stage_atomic_commits.sh` on
`/Users/sac/smalt` @ main (HEAD 518b31a). Executed by F-7 — this lane did NOT commit.

## What was built

`scripts/stage_atomic_commits.sh` — per-family atomic commit staging:

- 5 families (bench, shims, errc, planning, receipts), staged then committed in order,
  each via `git add <paths> && git diff --cached --stat && git commit -F /tmp/stage-msgs/<family>`.
- Msgfiles pre-written to `/tmp/stage-msgs/{bench,shims,errc,planning,receipts}`.
- Explicit classification of every `git status --porcelain` entry (modified + untracked;
  no `git add .` / silent sweep anywhere).
- `--dry-run` prints the plan and exits 0 without staging or committing.
- REFUSES (exit 1, loud list to stderr) if any dirty file matches no family.

## Q-4 classification extensions (disclosed deviations from the lane spec)

The spec's literal family pathspecs left 27 dirty files unmatched (first dry-run
refused, list witnessed). Disclosed mappings added so F-7 can actually execute:

- bench += `scripts/stress/` (soak/spike/chaos feed bench corpus),
  `scripts/wave_telemetry.sh`, `justfile.d/15-bench.just`, `justfile.d/19-wave-telemetry.just`
- shims += `lib/smalt/application.ex`, `lib/smalt/data_plane/blob_service.ex`,
  `lib/smalt/messaging/amqp/cbs_router.ex` (same shim wave surface),
  `justfile.d/18-shim-court.just`, `test/smalt/` (hw_test),
  `proxy/` (new substrate-proxy source, v26.10.15 lane 23 — landed with shims)
- errc += `Justfile`, `justfile.d/04/06/10/20`, `scripts/naming_sweep.sh`,
  `scripts/sdk_coverage.py`, `scripts/kd_flip.py`, this script itself,
  `test/sdk-full/package-lock.json`, `workspace/` (spec's "workspace property files")
- receipts += `docs/jira/v26.10.14/{KNOWN_DIVERGENCES,SDK_MATRIX}.md`, `ws/`,
  `.ggen_igniter/receipts/`, plus spec'd "remaining test/ stragglers"
  (cbs_router_test, blob_hardening, c3_cosmos, sdk-python, sdk-smoke arm/eh-run,
  kv_challenge_witness)

## Verification (real output)

`scripts/stage_atomic_commits.sh --dry-run` → exit 0, partition witnessed:

| family   | files |
|----------|-------|
| bench    | 8 pathspecs |
| shims    | 17 |
| errc     | 36 |
| planning | 1 (`docs/jira/v26.10.15/`) |
| receipts | 70 |

Refusal gate separately witnessed: first run (spec-literal pathspecs) refused with
27 unmatched files listed to stderr, exit 1.

Full dry-run transcript is in the Q-4 lane report; re-run anytime with
`scripts/stage_atomic_commits.sh --dry-run`.

## Standing

ALIVE (dry-run witnessed on the exact 133-entry dirty tree). Execution standing
pending F-7's real commits + `git log` receipt. Falsifier: a family commit whose
`git diff --cached --stat` shows files outside its pathspec, or any dirty file
surviving the final `git status --porcelain` after execution.
