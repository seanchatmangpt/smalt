# BK-35 HEAD-Court Sweep — v26.10.21

- **Date**: 2026-10-21 19:58–21:30 PDT
**Standing**: **SUSPECT** — the terminal-gate clause ("last recorded court run PASS on CURRENT HEAD") is **NOT satisfied**. No gate went fully green on a stable subject; the shared tree was under continuous sibling-lane mutation throughout the window.
- **Context: full**

## Subject

The tree was a moving target. Four HEADs were observed during the window:

| SHA | When | Note |
|---|---|---|
| `1abdee3` | sweep start (19:58) | pinned at task start |
| `1ea9959` | 21:09–21:17 | **subject of the one completed full `mix test` run (attempt 4)** |
| `7768308` | 21:30 | HEAD at receipt writing (coordinator tick checkpoints kept advancing it) |

Build root: `MIX_BUILD_ROOT=_build-bk35` (fresh). Toolchain: asdf elixir 1.20.4-otp-29 / OTP 29 (repo-pinned `.tool-versions`).

## Environment finding (actionable, pre-existing harness gap)

`gates/common.py` spawns plain `mix`, which on this machine resolves to **Homebrew Elixir 1.19.5 / OTP-28** — not the repo-pinned asdf 1.20.4-otp-29. Every substrate boot died `rc=1` in ~2s ("substrate exited rc=1 before binding"), producing an all-6-FAIL invariant-gates table that looked like defects but was pure toolchain mismatch. With `export PATH="$HOME/.asdf/shims:$PATH"` the gates ran for real. **Any lane running `just invariant-gates` must prefix asdf shims on PATH, or the gate verdict is void.**

## Per-gate table

| Gate | Verdict | Exit | Evidence tail | Load avg at result |
|---|---|---|---|---|
| `mix test` (attempt 4, HEAD 1ea9959) | **FAIL 504/529, 25 failures** | 2 | `Finished in 404.6s … Failed: 25 tests` | 86.02 / 94.18 / 90.65 |
| `just invariant-gates` (runs 1–3, plain `mix`) | **VOID** — toolchain mismatch, all-6 rc=1 in ~2s | 1 | `substrate exited rc=1 before binding` ×6 (see environment finding) | 135.09/122.62/122.01 · 159.82/132.97/125.96 · 57.96/89.02/110.63 |
| `just invariant-gates` (real run, asdf PATH) | **FAIL 5/6** | 1 | `ledger-chain PASS`; other 5 FAIL | 48.21 / 88.96 / 103.64 |
| `just sleep-gate` | **FAIL** | 1 | 5 violations (ja12 ×4, ja13:436) — all 5 verified present in `git show HEAD:` content → real, deterministic | 132.08 / 122.37 / 121.92 |
| `just docs-dod-check` | **PASS** | 0 | `OK … README.md` | 132.08 / 122.37 / 121.92 |
| `just receipt-index` | **PASS** | 0 | `wrote …/v26.10.21/RECEIPTS.md` | 133.28 / 122.78 / 122.07 |

## mix test — the 25 failures (attempt 4, HEAD `1ea9959`)

By module:
- `InternalTier.CensusTest` ×6 — deterministic census greps; real on the current tree (committed files listed in the failure payloads).
- `Smalt.Test.Internal.W3cbVcExportCourtTest` ×5
- `Smalt.Test.Internal.Ath1BatchFrameReceiverCourtTest` ×9
- `InternalTier.PlaneBlastRadiusTest` (heir parity) ×1
- `InternalTier.VmZeroGrowthTest` (conn-sup churn) ×1
- `InternalTier.Kd115CreditFirstDeliveryTest` ×1
- `Smalt.Test.Internal.DeferredListenersCourtTest` (default boot) ×1
- `Amqp10.Debug` debug ×1
- `Smalt.Internal.EtsAutoCourtTest` (64-task court) ×1

LOAD-FLAKE typing: NOT completed. Two solo re-runs of the 9 failing files were attempted; both died pre-run on **sibling-lane compile/boot freezes** (powl2 `law_compiler.ex` mid-edit; `Smalt.Store.Heir` referenced by `Smalt.Plane.DataSupervisor` but absent — JA-R2 lane in-flight). The 19 non-census failures therefore remain **unclassified (pending solo re-run)** — they may be real or load-flakes; the 6 census failures are deterministic and real.

## Real HEAD defect witnessed and since fixed upstream

`test/internal/bk14_kd143_sqlfilter_persistence_test.exs` (committed at sweep-start HEAD `1abdee3`) failed to compile — called bare `eventually/1` while only requiring `poll_helper.exs` without importing `SmaltTest.Internal.Poll`. This compile-aborted full runs 1–3. A later tick checkpoint (HEAD moved past `1ea9959`) fixed the file; it now compiles. Typed: real defect, closed by owner lane mid-window.

## Sibling-lane compile-freeze ledger (typed compile-freeze class, not HEAD defects)

- `lib/smalt/sync/frame.ex` (untracked, `bxor` undefined) — later fixed by owner
- `lib/smalt/egress/SyncRoutes.ex` (placeholder `—` syntax error, later `halt_if_sent/0` undefined) — later fixed/committed by owner
- `lib/smalt/store.ex` (uncommitted syntax error at 102:34) — owner reverted/landed (poll-loop confirmed CLEAN at 20:58)
- `lib/smalt/powl2/law_compiler.ex` (mid-edit compile error) — later stable
- `Smalt.Store.Heir` missing at boot (JA-R2 in-flight) — unblocks when the JA-R2 lane lands

## Falsifier / replay

```
export PATH="$HOME/.asdf/shims:$PATH"
MIX_BUILD_ROOT=_build-bk35 mix test                      # attempt-4 subject: 1ea9959
MIX_BUILD_ROOT=_build-bk35 just invariant-gates
just sleep-gate ; just docs-dod-check ; just receipt-index
```

Full logs: `/tmp/bk35_mix_test4.log` (completed run), `/tmp/bk35_inv5.log`, `/tmp/bk35_sleep.log`, `/tmp/bk35_docs.log`, `/tmp/ri` `/tmp/bk35_ri.log`.

## Owner dispatch (not fixed by this lane, per task contract)

1. `gates/common.py` toolchain: gate substrate boots must use the repo-pinned toolchain (asdf shim PATH) or refuse loudly — a void all-FAIL verdict is worse than no verdict.
2. sleep-gate 5 violations (ja12/ja13) — real, pre-existing; owner: no-sleep-doctrine lane.
3. Solo re-run of the 19 non-census mix-test failures once sibling lanes stop freezing the tree; type each LOAD-FLAKE vs real.
4. The 6 CensusTest failures list committed test/internal files — needs the census allowlist owner.
