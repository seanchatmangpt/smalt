# i21c — fast court stages pre-run #4 (80/20)

Context: solo. Read-only pre-run; no edits, no git operations.

Machine (from `just bench-machine`):
`{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`

## Stages run

### 1. `just doctor` — PASS (exit 0)

```
=== SMALT DOCTOR DIAGNOSTIC COURT (v2) ===
[PASS] binaries (1.0ms): ok
[PASS] port-arm (0.1ms): ok
[PASS] port-data (0.0ms): ok
[PASS] port-amqp (0.0ms): ok
[PASS] gitignore-coverage (0.1ms): ok
[PASS] dev-key-perms (0.3ms): ok
[PASS] dev-certs (0.1ms): present (.smalt/tls/dev-cert.pem)
[ADVISORY] keychain-trust (15.6ms): dev CA not trusted by macOS System keychain
[PASS] tmp-dirs (0.1ms): ok
[PASS] mix-deps-freshness (526.8ms): INFO 89 locked deps
[PASS] recent-receipts (4.3ms): INFO 1/1 receipt(s) stale >24h: bench-receipt.json (28.5h old)
[PASS] spc-bands (63.5ms): PASS verdict=PASS tier=0 seeded=False
[SUBSTRATE] booted=False ports all free, 1 receipt (28.51h stale)
[PASS] Smalt doctor diagnostic court passed.
```

One advisory (keychain-untrusted), non-gating by design.

### 2. `just tf-plan-smoke` — FAIL (exit 1, NOT the expected exit 77 SKIPPED-NETWORK)

Pre-existing failure: mix dependency resolution aborts before the network stage.

```
[FAULT] substrate process exited before binding 9443; log tail:
Unchecked dependencies for environment test:
* ex4pm (Hex package)
  the dependency ex4pm 26.10.8 (mix.exs: {:ex4pm, "~> 26.10.8"})
  does not match deps/ash_ex4pm/mix.exs: {:ex4pm, "== 26.10.1"}
** (Mix) Can't continue due to errors on dependencies
```

Court preflights that did PASS before the fault:
terraform binary PASS (31ms), fixture dir PASS (30ms), ports 9443/9444 free PASS (57ms),
shim-probe (Security.framework, pinned leaf) PASS (8671ms).
FAIL row: `substrate bound 9443 <=30s  FAIL  1377ms` — the substrate died in `mix deps.get`
on the ex4pm `~> 26.10.8` (root mix.exs:120) vs `== 26.10.1` (deps/ash_ex4pm/mix.exs:52)
conflict. Both files carry in-source comments confirming this is the known ex4pm hex-only
transition (recent commit 248e119 "ex4pm hex-only"); the path-dep pin was not bumped to
match. Not expected-exit-77: we never reached the registry-reachability check.

### 3. `just ws-lint` — PASS (exit 0)

```
✖ 29 problems (0 errors, 29 warnings)
```

All 29 are `@typescript-eslint/no-unused-vars` warnings (workspace scripts/tests). Zero errors.

### 4. `just ws-build` — PASS (exit 0)

Next.js 16 production build completed; route manifest emitted
(static/SSG/dynamic + ISR routes incl. `/bench/news/isr-*` and Proxy middleware).

## Summary

| Stage | Expected | Observed | Verdict |
|---|---|---|---|
| doctor | PASS | PASS (exit 0, 1 advisory) | MATCH |
| tf-plan-smoke | exit 77 SKIPPED-NETWORK | exit 1 — mix deps conflict (ex4pm 26.10.8 vs 26.10.1) | MISMATCH, pre-existing |
| ws-lint | pass | pass (29 warnings, 0 errors) | MATCH |
| ws-build | pass | pass | MATCH |

Standing: PARTIAL_ALIVE — 3/4 stages green; tf-plan-smoke is blocked pre-network by the
ex4pm pin skew between root `mix.exs:120` and `deps/ash_ex4pm/mix.exs:52`. Fix is a
pin bump in the path dep (or an override), owned by the ex4pm transition lane; this
pre-run made no edits per its contract.
