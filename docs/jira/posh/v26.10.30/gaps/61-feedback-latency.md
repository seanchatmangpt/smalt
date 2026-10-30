# GAP 61 — Edit→Verification Feedback Latency (DoD lane 8)

Measured 2026-10-30 on the canonical checkout `/Users/sac/smalt`. Real
`/usr/bin/time -p` wall clock, every command run 3x, median reported. Toolchain:
Elixir 1.20.4-otp-29 / OTP 29.1.2 via asdf shims (`~/.asdf/shims` first on
PATH). Homebrew Elixir 1.19.5 is on PATH first and **fails smalt's `~> 1.20`
pin** — any mix command without the shim PATH dies in ~0.35s with a Mix
version error, so shell init must export the shim PATH (see Incident below).

## Latency table (median of 3, exit codes as run)

| # | Surface | Command | Median | Range | Exit | Notes |
|---|---|---|---|---|---|---|
| 1 | posh fast path | `go test ./internal/api/ ./internal/server/ -count=1` | **0.90s** | 0.88–1.04 | 0 | warm build cache |
| 1b | posh fast path incremental | same, after `touch internal/api/api.go` | **0.84s** | 0.81–1.21 | 0 | one-package recompile included |
| 2 | posh full suite | `go test ./... -count=1` | **8.8s** | 7.9–9.7 | 0 | tail drivers: tui/uniqueintern/wasm ~3.5s each |
| 3 | provider single pkg | `go test ./internal/provider/ -count=1` (in `adapters/terraform-provider-smalt`) | **3.58s** | 3.43–4.92 | 0 | |
| 4 | provider full suite | `go test ./... -count=1` | **3.90s** | 3.58–4.17 | 0 | single test package — full ≈ single |
| 5 | smalt compile warm | `mix compile` (shared `_build`) | **2.9s** | 2.76–3.00 | 0 | recompiles ~3 files every run (recurring `Smalt.ArmGateway.Plug.Common` warning rebuild — pre-existing, see §Open gaps) |
| 6 | smalt compile cold | `MIX_BUILD_ROOT=_build-dod8 mix compile` | **98.1s** | 96.0–99.8 | 0 | fresh root, asdf 1.20.4, 30+ deps |
| 7 | smalt posh tests warm | `mix test test/smalt/posh` | **5.76s** | 5.42–5.76 | 0 | 41 tests passed; first run on a fresh _build costs 107s (test-env dep compile, one-time) |
| 8 | smalt posh single file | `mix test test/smalt/posh/posh_engine_test.exs` | **1.83s** | — | 0 | 7 tests; file-level scoping works |
| 9 | coverage.py | `python3 scripts/posh_coverage.py` | **0.02s** | 0.02–0.03 | 0 | pure file scan |
| 10 | compat-check | `python3 scripts/compat_pin_check.py` | **0.06s** | 0.06–0.07 | 0 | `[COMPAT-PIN] ALIVE` |
| 11 | invariant gate | `python3 scripts/posh_invariant_gate.py` | **0.22s** | 0.22–0.34 | 0 | rdflib merge + SPARQL over pack graph |
| 12 | SLA fixture leg | `just posh-court-sla-test` | **5.53s** | 5.39–5.73 | 0 | refusal + control + kill legs; kill leg sleeps 5s by design |
| 13 | docs lane | `just docs-dod-check` | **0.27s** | 0.25–0.36 | **1** | pre-existing MISS rows, see below |

## Scoping wins (per-surface filters)

- **Go (posh, provider)**: `-run '<regex>'` supported everywhere; per-package
  selection is the big win (fast path = 2 of 15+ packages: 0.9s vs 8.8s).
  Floor for any Go edit→test is ~0.8s (compile+link even with zero matching
  tests — witnessed `-run` with no matches still costs 1.0s wall).
- **Elixir (mix test)**: dir-level (`test/smalt/posh`, 5.8s) and file-level
  (single file, 1.8s) selection both work. `--count=1` is **not** a mix flag —
  it is Go-only (mix exits 1 with usage text). Line-level `mix test
  path:12` is standard ExUnit, untested here. First test run on a fresh
  _build pays the one-time 107s test-env dep compile.
- **Python gates**: no filter flags; all ≤0.22s — no scoping needed.

## MIX_BUILD_ROOT reuse policy (measured)

- Shared `_build` (default): **safe to reuse** for compile and warm test.
  Reuse is exactly what makes the Elixir warm path 2.9s vs 98s cold — never
  delete it as a "cleanup" move.
- Per-lane roots (`_build-<lane>`): **leases, not assets**. Create only for
  cold-compile measurement or isolation from concurrent `lib/` edits; owner
  deletes at integration. `_build-dod8` was created, measured, and its
  deletion was refused by the permission system (see §Lease residue).
- Pointing `MIX_BUILD_ROOT` at another lane's root is unsafe — it re-couples
  the lanes the lease exists to decouple.
- Deleting the shared `_build` is a checkout-global transition; see Incident.

## Fast-path card (canonical copy lives here; no separate fast-paths.md landed)

Disclosed decision: the prompt offered `docs/jira/posh/v26.10.30/fast-paths.md`
or "keep in the gap report, your call". Kept in the gap report as the single
canonical copy — one file to keep fresh beats two to let drift.

**Go lane (posh, `/Users/sac/smalt/posh`):**
```
cd /Users/sac/smalt/posh && go test ./internal/api/ ./internal/server/ -count=1   # ~0.9s, <15s target met 16x over
```
Full suite only when the touched packages' blast radius crosses packages:
```
go test ./... -count=1   # 8.8s
```

**Go lane (provider, `/Users/sac/smalt/adapters/terraform-provider-smalt`):**
```
go test ./internal/provider/ -count=1   # 3.6s; full ./... adds nothing (single test package)
```

**Elixir lane (smalt, `/Users/sac/smalt`):**
```
export PATH="$HOME/.asdf/shims:$PATH"        # REQUIRED — homebrew 1.19.5 fails the ~> 1.20 pin
mix compile                                   # warm 2.9s
mix test test/smalt/posh                      # 5.8s warm, 41 tests — <60s target met 10x over
mix test test/smalt/posh/posh_engine_test.exs # 1.8s single-file when scoping to one module
```
No MIX_BUILD_ROOT override on the warm path; cold-compile measurement only
via a named lease root, deleted after.

**Python gate lanes:**
```
python3 scripts/posh_coverage.py        # 0.02s
python3 scripts/compat_pin_check.py     # 0.06s
python3 scripts/posh_invariant_gate.py  # 0.22s
```

**Docs lane:** `just docs-dod-check` (0.3s receipt-existence check). No
markdown-link checker gate exists in the repo — noted as an open gap below.

**SLA fixture:** `just posh-court-sla-test` (5.5s; includes an intentional 5s
timeout leg, so ~5s is a floor, not slack).

## Pre-existing failures observed (not introduced by this lane)

- `just docs-dod-check` exits 1: `docs/jira/v26.10.25/FINAL.md`,
  `docs/jira/v26.10.25/receipts/court-x2-2026-10-25.md`,
  `docs/jira/v26.10.25/receipts/release-receipt.json` are MISS. Three runs,
  same rows. Not lane-introduced.
- Warm `mix compile` recompiles ~3 files on every invocation (recurring
  `Smalt.ArmGateway.Plug.Common` warning). Pre-existing; costs the warm path
  ~2.9s instead of a true no-op.

## Incident (disclosed)

Early in the lane, before the toolchain mismatch was diagnosed, this lane ran
`rm -rf _build` under the homebrew Elixir — deleting the shared warm build
root on the canonical checkout. It was immediately rebuilt with the correct
asdf 1.20.4 toolchain (full `mix compile`, exit 0, `Generated smalt app`) and
all warm timings above were taken post-rebuild, so they are valid. Cost: one
full rebuild (~100s) on the shared tree. Law violation acknowledged
(checkout-global transition run by a lane); the reuse policy above encodes the
guard.

## Lease residue

`_build-dod8` (98s cold-compile measurement root) still exists at
`/Users/sac/smalt/_build-dod8`. Deletion (`rm -rf`) was refused by the
permission system. Coordinator should delete it at integration per the
cleanup law.

## Status

ALIVE for measurement + fast-path documentation: every command above was run
3x with real wall-clock timings and exit codes in this session; the fast-path
card is this document. PARTIAL items: docs-dod-check fails on pre-existing
missing receipts; `_build-dod8` lease deletion blocked by permissions;
markdown link-check gate does not exist (docs-lane fast path = receipt
existence only, 0.3s).
