# i29 — Generated-Artifact Replay Fences (post-0009df3 tree)

- **Date**: 2026-10-19T05:29:57Z
Context: solo
- **Standing**: PARTIAL_ALIVE — byte-identical replay fences PASS; pack-lock drift fence FAILS (pre-existing, external to this repo).
- **Subject**: smalt @ 0009df3 (post-commit working tree, no edits made by this lane).

## Scope

Generated-artifact replay fences only. Per instructions: `mix smalt.gen` and
`Canonical.write` were NOT run (both write); no `_build` dir was removed.
Two lane build roots were created for this run (`_build-ft-rep`,
`_build-ft-rep2` — the latter cold-root timeout witness).

## 1. Byte-identical replay tests

The requested filenames (`test/registry_replay_test.exs`,
`test/mcp_descriptor_test.exs`) do not exist. `ls test/ | grep -iE "replay|registry|mcp"` gives the real names:
`test/smalt_registry_replay_identity_test.exs`,
`test/config_replay_identity_test.exs`,
`test/store_tables_replay_identity_test.exs`,
`test/cascade_replay_identity_test.exs`,
`test/semconv_replay_identity_test.exs`.

Actual command:

```
MIX_BUILD_ROOT=_build-ft-rep mix test test/smalt_registry_replay_identity_test.exs \
  test/config_replay_identity_test.exs --include replay_identity
```

(Both files are tagged `@moduletag :stress` + `@tag :replay_identity`, hence
`--include replay_identity`.)

### Result: 6 tests, 2 failures — both `:lock_drift` (pre-existing)

```
  1) test pack lock digest matches the live pack checkout (Smalt.RegistryReplayIdentityTest)
     test/smalt_registry_replay_identity_test.exs:61
     :lock_drift — ggen_igniter.pack.lock pins 43c15edb79a900411365a8ef0d595a07841944279eb07ab3ecb7dfe627caba93 but the live pack at
     ../ggen-marketplace/packs/smalt-substrate-pack computes a454f2f01f17a2c19ec48e1d52e8e011d035d54246785f7547a501e3557e5c6f (GgenIgniter.PackLock.digest/1). Re-pin with:
       mix ggen_igniter.pack.lock --path ../ggen-marketplace/packs/smalt-substrate-pack --pack smalt-substrate-pack
     stacktrace: test/smalt_registry_replay_identity_test.exs:68

  2) test pack lock digest matches the live pack checkout (Smalt.ConfigReplayIdentityTest)
     test/config_replay_identity_test.exs:75
     :lock_drift — same digests as (1): pinned 43c15edb…, live a454f2f0….

6 tests, 2 failures
```

The two byte-identical replay assertions themselves PASSED (registry.ex and
config.ex re-render byte-identical to on-disk artifacts). Failures are the
**lock-vs-live-pack** fence: the pinned digest of the pack checkout is stale,
not the artifacts. The pack lives outside this repo (`../ggen-marketplace`),
so this drift is pre-existing and outside this lane's write authority. Fix is
`mix ggen_igniter.pack.lock …` (re-pin) — NOT run (writes
`ggen_igniter.pack.lock`).

Note: these tests need a warm MIX_ENV=dev build root for their nested
`mix run` subprocess — cold dev root times out at the 240s test timeout
(witnessed: 2 timeout failures on fresh `_build-ft-rep2`). Fix observed:
`MIX_BUILD_ROOT=_build-ft-rep MIX_ENV=dev mix compile` (exit 0), then rerun.

## 2. MCP descriptor byte-identity (test/mcp_test.exs)

No `test/mcp_descriptor_test.exs` exists; the descriptor byte-identity fences
live in `test/mcp_test.exs` at line 1216 ("lens6 generated descriptor
skeleton is byte-identical to the template skeleton") and line 1387
(descriptor cross-check). Actual command and output:

```
$ MIX_BUILD_ROOT=_build-ft-rep mix test test/mcp_test.exs:1216 test/mcp_test.exs:1387
2 tests, 0 failures (50 excluded)
```

MCP descriptor replay fences PASS.

## 3. ERROR_CODES check (`just gen-error-codes` form)

Recipe at `justfile:151` is `python3 scripts/gen_error_codes.py` (no args);
the script itself supports `--check` (exit 1 on drift). Run:

```
$ python3 scripts/gen_error_codes.py --check
docs/ERROR_CODES.md up to date
check_exit=0
```

Up to date, exit 0. (An exploratory `--help` invocation ran the generator
unflagged and rewrote docs/ERROR_CODES.md — `git diff` on the file is empty,
byte-identical, zero drift, no-op.)

## Summary

| Fence | Verdict |
|---|---|
| registry.ex byte-identical replay | PASS |
| config.ex byte-identical replay | PASS |
| mcp_descriptor.ex byte-identity (mcp_test.exs:1216, :1387) | PASS (2 tests, 0 failures) |
| ERROR_CODES.md `--check` | PASS (exit 0, "up to date") |
| pack-lock vs live-pack digest (registry+config files) | FAIL — `:lock_drift`, pre-existing, external pack (`../ggen-marketplace`); re-pin not run (writes) |

Errors are reported honestly per lane law: 2 failures, both `:lock_drift`,
both pre-existing (pin `43c15edb…` vs live `a454f2f0…`), fix named but not
executed per no-write constraint.
