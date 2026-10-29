# JA-14 — Release Handling (hot-upgrade vs cold-restart)

Repo: `/Users/sac/smalt` · Branch: `main` · Milestone v26.10.21 · Date: 2026-10-21 · Context: solo
Toolchain: Elixir 1.20.4-otp-29 / OTP 29.1.2. READ-ONLY agent; parent persisted.

**Standing:** **PARTIAL ALIVE — hot-upgrade remains UNSUPPORTED-HOT-UPGRADE (re-verified 2026-10-21, BK-28); the one open cold-restart gap (journal→Store replay at boot) is now WIRED by TTV-4 — see Re-witness below.**

## 1. Census: release artifacts — NONE (for hot-upgrade)

| Artifact | Present? | Evidence |
|---|---|---|
| `rel/` dir | Partial | `rel/env.sh.e` only — 4 port-export lines, no `vm.args.e`, no `sys.config`, no hooks |
| `.appup` | **ZERO** | `find . -name "*.appup"` (excl. `_build*`) → no hits |
| `.relup` | **ZERO** | same → no hits |
| `mix.exs` releases stanza | Present | `mix.exs:28-37` — boot release, not an upgradable one |
| `sys.config` | Bench overlay only | `tmp/bench/t47/sys.config` (via `RELEASE_SYS_CONFIG`, per t47 receipt) |
| release_handler usage | **ZERO** | none in `lib/` |

## 2. Census: `code_change/3` — ZERO

34 files `use GenServer` / gen_statem under `lib/` (store.ex, journal_sink.ex, dets_mirror.ex, all messaging/, powl2/*, sealed_log.ex). **Not one defines `code_change/3`** (`grep -rl code_change lib/` empty). Consistent with no `.appup` to attach to: the codebase is written crash-only, not upgrade-in-place.

## 3. Honest typing: **UNSUPPORTED-HOT-UPGRADE**

The release path is `MIX_ENV=prod mix release smalt` (witnessed by `t47-release-boot-gate.md`: boots, all 6 listeners, real ARM/Cosmos ops) — a **stop→rebuild→start** release, not an OTP hot upgrade. Hot-upgrade would require: `.appup` for `:smalt`, `code_change/3` in all 34 stateful processes, `.relup` (`systools:make_relup/4`), shipped `sys.config` + `release_handler` install — none exist; `rel/` carries only port env vars.

## 4. Cold-restart recovery — PARTIALLY WIRED, one leg NOT wired

- **Journal write path — wired.** `Smalt.Storage.JournalSink` starts under Application when config-gated (default OFF, `application.ex:47-53`); OCHEL emitter appends (`telemetry/ocel_emitter.ex:221`). Seal protocol fsync→rename→meta.json(sha256)→`.seal` sentinel — courted in `sj1-journal-sink-writer.md` (5 legs PASS).
- **Journal read/replay path — NOT wired into boot.** `Smalt.Storage.JournalReader` referenced only by tests (`journal_reader_court_test.exs`, `sj4_journal_wire_court.exs`). No module calls `discover_sealed_segments/1` at startup. **No boot-time journal replay into `Smalt.Store`.**
- **Store restart semantics are lossy by the code's own admission** — `store.ex:220`: "named ETS tables die with it; a restart loses data." Persistence is the **opt-in** `Smalt.Store.DetsMirror` with AZB-14 repair vocabulary — that, not the journal, is the only cold-restart state recovery today.

## Honest table

| Dimension | Status | Witness / gap |
|---|---|---|
| OTP hot-upgrade | **UNSUPPORTED-HOT-UPGRADE** | zero `.appup`/`.relup`; zero `code_change/3` ×34; `rel/` = env.sh.e only |
| Cold-restart: release boot | VERIFIED | `t47-release-boot-gate.md` (cold-start 500ms ceiling FAILED at 1906ms best — disclosed) |
| Cold-restart: journal seal/reopen | VERIFIED | SJ-1 court (seal atomicity, rotation, monotonic SeqID), SJ-2 court (fail-closed reader, sha256 manifest) |
| Cold-restart: journal→store replay at boot | **NOT WIRED (gap)** | `JournalReader` zero non-test callers; `store.ex:220` states restart loses data |
| Cold-restart: state persistence | OPT-IN ONLY | `DetsMirror` (poll-based, default off) + AZB-14 repair telemetry |

Witnesses: `lib/smalt/storage/journal_sink.ex`, `journal_reader.ex`, `lib/smalt/store/dets_mirror.ex`, `lib/smalt/application.ex:47-53`, `lib/smalt/store.ex:220`, `rel/env.sh.e`; receipts `sj1-journal-sink-writer.md`, `sj2-journal-reader.md`, `t47-release-boot-gate.md`.

## Re-witness (BK-28, 2026-10-21)

Re-derived from the CURRENT tree. The original audit's single open leg — "journal replay NOT
wired into boot" — has LANDED as TTV-4 boot replay; hot-upgrade typing unchanged.

```
$ find . -name '*.appup' -not -path '*_build*' | wc -l
       0
$ find . -name '*.relup' -not -path '*_build*' -not -path './lib/smalt/pipeline*' | wc -l
       0
$ grep -rn 'code_change' lib/ --include='*.ex' | wc -l
       0
```

- **Hot-upgrade typing — re-verified UNSUPPORTED-HOT-UPGRADE**: 0 `.appup`, 0 `.relup`,
  0 `code_change/3` in `lib/**/*.ex` (the only repo-wide `code_change` hits live in the
  committed `lib/smalt/pipeline/erl_crash.dump` binary). `rel/` still `env.sh.e`-only.
- **Cold-restart journal→Store replay — NOW WIRED (TTV-4)**: `lib/smalt/store.ex:62-74` runs
  `boot_replay/1` inside `init` (replay-then-listen; a typed reader refusal is a boot refusal
  `{:stop, {:journal_replay_failed, reason}}`, never a silent skip); `replay_sealed/1`
  (store.ex:91) applies every SEALED segment in segment-then-SeqID order via
  `JournalReader.discover_sealed_segments/1`. `JournalReader` now has a non-test caller.
  (Boot court: `test/integration/ttv4_journal_boot_replay_court.exs`, in-flight TTV lane.)
- Standing updated from "journal replay NOT wired" → **journal replay wired, boot-fail-closed**.
