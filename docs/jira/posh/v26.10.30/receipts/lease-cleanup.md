# Lane Lease Cleanup Receipt — F10

Date: 2026-10-30 · Lane: F10 · Repos: /Users/sac/smalt, /Users/sac/cai/courtroom-platform-az

## Live-reference check (law: lsof + ps eww first)

- Live beam pid 47052 (`mix run --no-halt`, cwd `/Users/sac/smalt`): no
  `MIX_BUILD_ROOT` in `ps eww` env, no open files under any `_build-lane*`
  via `lsof +D`. Uses the canonical `_build` (untouched).
- `lsof +D` over every candidate scratch dir before deletion: zero open handles.

## Wave lane build-root leases (_build-lane2..19, laneK, poshl4, coord, acrfix, gap1, final, f9)

None exist in /Users/sac/smalt — the wave build roots were already reclaimed
in a prior pass. Present `_build-f4`, `_build-f5` are NOT in this wave's lease
list and were left in place. Canonical `_build` and all pre-existing smalt
`_build-*` dirs (baseline, eplaw, expl11r3, fin1, gc1, gi1, kind, l02-l18,
s2/s4, slam*, t01/t02, tick*, w02/w04) untouched.

Freed: 0 bytes (nothing to delete).

## erl_crash.dump

- /Users/sac/smalt/erl_crash.dump: absent — nothing to delete.
- /Users/sac/cai/courtroom-platform-az/erl_crash.dump: absent (find over repo,
  node_modules excluded). `.gitignore` line `erl_crash.dump` appended anyway as
  directed; now `git check-ignore` confirms both `erl_crash.dump` and
  `privkey.pem` are ignored. `.gitignore` left modified (uncommitted) for the
  coordinator's commit.

## /tmp scratch deleted (3.5 MB + 243 MB)

| path | size |
|---|---|
| /tmp/f3-consumer | 243M |
| /tmp/lane2_scratch | 3.0M |
| /tmp/lane8out | 32K |
| /tmp/lane5-check, /tmp/lane5-check3 | 80K |
| /tmp/lane2_compile.log, lane2_compile2.log, lane2_proj_test.log, lane2_test.log, lane3_roundtrip.exs | ~52K |
| /tmp/lane5_env_setup.exs, lane5_falsifier.exs, lane5_import.exs, lane6_probe_attrs.exs, lane6_roundtrip.exs | ~24K |
| /tmp/lane8_falsifier.exs, lane8_falsifier2.exs, lane8_token, lane8rt | ~36K |
| /tmp/lane9_acr.exs, lane9_ra.exs, lane9_ra2.exs, lane9_roundtrip.exs, lane9_st.exs, lane9_sweep.exs, lane9_sweep2.exs, lane9-token | ~36K |
| /tmp/lane11_compile.log, lane18-substrate.log, lane18.pid | <16K |
| /tmp/lane_k_falsifier.exs, lane_k_grpc_client.exs, lane_k_handshake.{err,out} | <16K |

Post-delete verification: `ls -d /tmp/lane* /tmp/f3-consumer` → no matches.
`rmdir` returned clean; no `rm -rf` of any live-referenced path.

## Flagged for operator (untouched)

- `/Users/sac/cai/courtroom-platform-az/privkey.pem` — repo root, UNTRACKED
  (`git ls-files` empty), ignored by .gitignore, mtime Oct 30 02:24:56 2026
  (today). Freshly generated private key sitting in the repo root; do not
  commit it. Was not deleted per task constraint.

Standing: ALIVE — every deletion re-verified on disk post-removal.
