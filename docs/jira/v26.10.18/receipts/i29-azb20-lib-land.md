# i29-azb20-lib-land — azb-20 lib lane adoption

- Standing: **ALIVE**
- Context: pair(bench azb-20 census lane → adopt lane `_build-ft-az20h`, 2026-10-19)
- Subject: dirty lib set `lib/smalt/arm_gateway/router.ex`, `lib/smalt/data_plane/blob_storage.ex`,
  `lib/smalt/data_plane/cosmos.ex`, `lib/smalt/data_plane/key_vault_actions.ex`
  (+304 at adoption; +344 after `docs/ERROR_CODES.md` regen, lib diff itself unchanged).

## Census (adoption precondition)

- t0 00:41:13 PDT: `git diff --stat lib/ | tail -1` → `4 files changed, 304 insertions(+)`
- t0+4m 00:45:19: `4 files changed, 304 insertions(+)` — STABLE
- t0+8m 00:49:26: `4 files changed, 304 insertions(+)` — STABLE
- No azb-20 lib receipt appeared during the window (new receipts: i29-full-soak-f,
  i29-colima-stop-runbook — unrelated). ADOPT taken per SLA.

## Verification ladder

```
$ MIX_BUILD_ROOT=_build-ft-az20h mix test test/data_plane/ test/arm/ test/wire/
Finished in 14.3 seconds (0.8s async, 13.4s sync)
515 tests, 0 failures (2 excluded)

$ python3 scripts/gen_error_codes.py --check   # run 1
docs/ERROR_CODES.md is stale. Run: python3 scripts/gen_error_codes.py
(exit=1 — egress_router.ex line-number rows drifted)

$ python3 scripts/gen_error_codes.py
wrote /Users/sac/smalt/docs/ERROR_CODES.md (109 rows)

$ python3 scripts/gen_error_codes.py --check   # re-run
docs/ERROR_CODES.md up to date
CHECK-OK

$ MIX_BUILD_ROOT=_build-ft-az20h mix test test/data_plane/ test/arm/ test/wire/   # green x2
Finished in 12.7 seconds (0.8s async, 11.9s sync)
515 tests, 0 failures (2 excluded)
```

## Notes

- No red tests; no lib edits made by this lane (fix-forward not needed).
- Dual-naming disclosure (compile-freeze SLA): this lane does not touch
  `lib/smalt/egress_router.ex`, but the ERROR_CODES regen picked up that file's
  current line numbers — if the G1 lane lands further egress_router edits, rerun
  `python3 scripts/gen_error_codes.py --check` and regen if it drifts.
- Lane build root `_build-ft-az20h` left for coordinator `just lane-clean`.
