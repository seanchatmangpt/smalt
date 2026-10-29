# BK-W2C — W2-class harness census (tmp/ dependency sweep)

**Standing:** ALIVE (relocations replayed exit 0 from tracked state)
Context: solo

Lane BK-W2C, 2026-10-22. Law: court/bench CAPITAL (harnesses, shims, fixtures a
replay needs) must be tracked; tmp/ is scratch output only. Prior W2 instances:
EXP1-B (gitignored idb-shim imported by sync-e2e-court) and PB4-T (PB-4 harness
in tmp/bench, relocated to scripts/bench/pb4_merkle_dual.exs at 36142e14).

## Method

`git grep` over committed harness surfaces (workspace/scripts/*.mjs,
scripts/bench/*, scripts/shim_court/*, test/, verification/) for tmp/ and
/tmp/ reads; `git check-ignore` / `git ls-files --error-unmatch` on each
candidate; minter-tracing for cert-like candidates.

## Census table

| # | Harness | Dependency | Gitignored/untracked? | W2? | Disposition |
|---|---|---|---|---|---|
| 1 | `test/internal/eplaw_ephemeral_boot_court_test.exs:59` + in-flight bench edits (a1_change_feed.exs:412, b42_dataplane_saturation.exs:38, b9_eh_beam.exs:203) | `scripts/lib/test_boot_ports.exs` | untracked at lane start (`git ls-files --error-unmatch` failed before coordinator tick; now tracked) | **YES — replay-breaking**: committed court hard-requires it; fresh-clone replay exits on missing file | RELOCATED — tracked via coordinator tick checkpoint **61ecfc39**; replay-verified below |
| 2 | `verification/ts/*.probe.cjs` (bk65, fix4, kd127, kd73-74, sb-emulator) | `/tmp/smalt-substrate-state/{keys,markers}/*` | /tmp (always untracked) | no — runtime substrate state minted by `scripts/substrate.sh` at boot, not capital; substrate-down probes fail loud (exit 2/3 contract) | NONE — typed runtime-state, not relocation target |
| 3 | `scripts/bench/pb1_fond_sweep.sh:41`, `scripts/bench/c7_cross_soak.mjs:41` | `tmp/dev-certs/dev-cert-<port>.pem` | gitignored (tmp/) | no — minted at runtime by `lib/smalt/tls.ex` (port-keyed dev certs); pb1 has a bounded poll + loud BLOCKED exit 2 (pb1_fond_sweep.sh:42-43) | NONE — runtime-minted, loud-fail |
| 4 | `scripts/bench/c11_tf_loop.sh:205`, `verification/py/run.sh:16`, `scripts/shim_court/kv_challenge_court.sh:34`, `lib` TLS legs generally | `.smalt/tls/*.pem` | gitignored | no — minted by `scripts/gen_dev_cert.sh` (bootstrap/doctor stage); c11 snapshots + verifies before use | NONE — bootstrap capital, doctor-gated |
| 5 | `scripts/bench/t45_boot_phases.sh:54` | `tmp/bench/t45_boot_eval.exs` | gitignored (tmp/) | no — written by heredoc inside the same script each run (self-contained regeneration), then read back | NONE — observation only |
| 6 | b10/b2/b6/c5/c2/c4/c7/c8/t35/t36/ctq2/scvd/pb*/ja9/gl9/impl17/c10/t42 outputs | `tmp/bench/*.jsonl`, `/tmp/*.log` | gitignored | no — scratch OUTPUT, lawful under the W2 law itself | NONE |

## Replay outputs

Row 1, from tracked state:

```
$ git ls-files --error-unmatch scripts/lib/test_boot_ports.exs
scripts/lib/test_boot_ports.exs   (exit 0)
$ MIX_BUILD_ROOT=_build-laneW2C mix run --no-start -e 'Code.require_file("scripts/lib/test_boot_ports.exs", File.cwd!()); SmaltTestBoot.pin!(); IO.puts("PIN-OK arm=#{SmaltTestBoot.port(:arm_port)} amqp=#{SmaltTestBoot.port(:amqp_port)}")'
PIN-OK arm=53163 amqp=53166
$ MIX_BUILD_ROOT=_build-laneW2C mix test test/internal/eplaw_ephemeral_boot_court_test.exs
Result: 3 passed   (exit 0)
```

## Notes

- At lane start the file was untracked (`?? scripts/lib/test_boot_ports.exs`
  in git status); the coordinator tick checkpoint 61ecfc39 ("in-flight
  snapshots ... BK-W2C bench harness relocations") landed it mid-lane. This
  receipt is the census + replay record; the relocation diff itself rides
  61ecfc39.
- One full-app-boot probe hit `:eaddrinuse` racing the live substrate window
  (probe-then-close port race, unrelated to the relocation); the --no-start
  pin probe and the eplaw court are the replay receipts.
- Zero silent rows: every tmp/-referencing committed harness is dispositioned
  in the table. No new GAP/KD tokens minted.
