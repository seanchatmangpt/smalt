set shell := ["bash", "-euo", "pipefail", "-c"]

PID_FILE := "/tmp/smalt.pid"
PORTS := "9443 9444 5672 5673"

# default recipe (operator spec, v26.10.16): doctor first, then the native
# lifecycle test. Previously an alias of `court` — disclosed default change.
# Just dependency syntax across imports: recipes in justfile.d/*.just are
# merged into one namespace, so `default: doctor test-native` resolves the
# imported `test-native` (justfile.d/22-native.just) the same as any root
# recipe. Recipe-listing order is unchanged (`just --list` sorts by section).
default: doctor test-native

# ============================================================================
# Diagnostic
# ============================================================================

# Runtime preflight: deps, ports, cert material, toolchain (doctor.py).
# Exit 0 healthy / 1 finding. ~2s.
doctor:
    @python3 scripts/doctor.py

# Substrate status: running beams + listening ports + latest receipt lines.
# Exit 0 always (report-only; never fails on a stopped substrate). ~1s.
status:
    @bash -c '\
      echo "[STATUS] beam processes:"; \
      pgrep -fl "beam.smp" | grep -i smalt || echo "  (none)"; \
      echo "[STATUS] listening ports ({{PORTS}}):"; \
      for p in {{PORTS}}; do \
        if lsof -nP -iTCP:$p -sTCP:LISTEN 2>/dev/null | tail -n +2 | sed "s/^/  /"; then :; fi; \
        lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1 || echo "  $p: free"; \
      done'
    @python3 -c 'import glob, json, os; files = sorted(glob.glob("tmp/*receipt*.json"), key=os.path.getmtime, reverse=True)[:5]; print("[STATUS] latest receipts:"); print("  (no receipts in tmp/)") if not files else [print("  %s  %s" % (f, ((" ".join("%s=%s" % (k, d[k]) for k in ("schema", "date", "profile") if k in d)) or "keys=" + ",".join(list(d)[:3]))[:140])) for f in files for d in [json.load(open(f))]]' 2>/dev/null || echo "  (no receipts in tmp/)"

# Tail the newest substrate log under tmp/ (follow; Ctrl-C to stop). ~0s.
logs:
    @bash -c 'newest=$(ls -t tmp/*.log 2>/dev/null | head -1); \
      if [ -z "$newest" ]; then echo "[LOGS] no tmp/*.log found"; exit 1; fi; \
      echo "[LOGS] tailing $newest"; tail -f "$newest"'

# List recent court/bench/stress receipts, newest first (top 15). ~0s.
receipts:
    @bash -c 'ls -lt tmp/*receipt*.json 2>/dev/null | head -15 || echo "(no receipts in tmp/)"'

# ============================================================================
# Substrate Lifecycle
# ============================================================================

# Start the sovereign Azure drop-in substrate on BEAM (pid in /tmp/smalt.pid).
# Ctrl-C to stop. Exit 0 while running.
# BK-ENG0: source the dev env (per-host SB shared key, TLS cert/key paths,
# SSL_CERT_FILE) so the TLS twin serves the dev CA-signed leaf — a bare
# `mix run --no-halt` boot serves a SELF-SIGNED cert the official Azure SDKs
# reject (DEPTH_ZERO_SELF_SIGNED_CERT, witnessed by this lane) and the SB SAS
# key would be nil. If the dev certs are missing, mint them first.
up:
    @echo "[SMALT] Starting sovereign Azure drop-in substrate on BEAM..."
    @bash -c 'if [ ! -f .smalt/tls/dev-cert.pem ]; then bash scripts/gen_dev_cert.sh || exit 1; fi; \
      eval "$(bash scripts/dev_env.sh)"; \
      export SMALT_TLS_CERTFILE="$PWD/.smalt/tls/dev-cert.pem" SMALT_TLS_KEYFILE="$PWD/.smalt/tls/dev-key.pem" SSL_CERT_FILE="$PWD/.smalt/tls/ca-cert.pem"; \
      trap "kill $$ 2>/dev/null; [ -f {{PID_FILE}} ] && kill $(cat {{PID_FILE}}) 2>/dev/null || true" EXIT; echo $$ > {{PID_FILE}}; \
      exec mix run --no-halt'

# Stop the substrate. Idempotent; exit 0 either way. ~0s.
# BK-ENG0: the pid file names the `mix run` wrapper, not the beam — killing
# only it orphaned the beam child, which KEPT the ports while the recipe
# reported "Substrate stopped" (witnessed by this lane). `just down` now also
# kills the live port holders on the substrate's own ports, and verifies they
# are actually free (bounded poll) before reporting success.
down:
    @bash -c 'if [ -f {{PID_FILE}} ]; then kill $(cat {{PID_FILE}}) 2>/dev/null || true; rm -f {{PID_FILE}}; fi; \
      for p in 9443 9444 8443 5672 5673; do \
        for b in $(lsof -nP -tiTCP:$p -sTCP:LISTEN 2>/dev/null); do kill -TERM "$b" 2>/dev/null || true; done; \
      done; \
      for i in $(seq 1 20); do \
        lsof -nP -iTCP:9443 -sTCP:LISTEN >/dev/null 2>&1 || break; \
        sleep 0.5; \
      done; \
      if lsof -nP -iTCP:9443 -sTCP:LISTEN >/dev/null 2>&1; then echo "[SMALT] DOWN FAILED: port 9443 still held"; exit 1; fi; \
      echo "[SMALT] Substrate stopped."'

# Kill stray smalt beams, remove _build-lane* build roots, erl_crash.dump, tmp
# logs. Never touches _build/ or deps/. Exit 0 always. ~1s.
clean:
    @bash -c 'pids=$(pgrep -fl beam.smp 2>/dev/null | grep -i smalt | awk "{print \$1}"); \
      if [ -n "$pids" ]; then echo "$pids" | xargs kill 2>/dev/null; echo "[CLEAN] killed stray smalt beams: $(echo $pids | tr "\n" " ")"; else echo "[CLEAN] no stray smalt beams"; fi; \
      rm -rf _build-lane*; \
      rm -f erl_crash.dump; \
      rm -f tmp/*.log; \
      echo "[CLEAN] removed _build-lane*, erl_crash.dump, tmp/*.log"'

# ============================================================================
# Code Generation
# ============================================================================

# Generate smalt code projections (mix smalt.gen). Exit 0 on success.
gen:
    @mix smalt.gen

# ============================================================================
# Verification Ladder (courts)
# ============================================================================

# T1: offline unit suite (mix test). Exit 0 pass / nonzero on failure. ~1-3m.
test-offline:
    @echo "[COURT] T1: offline unit suite..."
    @mix test

# T2: RETIRED (v26.10.19 reset 64f6099 — test/wire deleted). Successor: the
# verification/ TS/PY suites (justfile.d/32-verification.just) — this recipe
# is a LOUD no-op (exit 1) until its successor lands; never a silent pass.
test-wire:
    @echo "[RETIRED] test-wire: test/wire deleted at 64f6099; successor = verification/ suites (justfile.d/32-verification.just). Exit 1 until it lands."; exit 1

# T3: RETIRED (v26.10.19 reset — test/sdk-smoke/run.mjs deleted). Successor:
# verification/ts SDK probes (V261019-08). LOUD no-op (exit 1) until then.
test-sdk-smoke:
    @echo "[RETIRED] test-sdk-smoke: test/sdk-smoke deleted at 64f6099; successor = verification/ts (V261019-08). Exit 1 until it lands."; exit 1

# T4: terraform fixture plan smoke (scripts/tf_smoke.sh). Exit 0 pass /
# 1 preflight or substrate failure / 2 terraform step failure / 77
# SKIPPED-NETWORK (registry.terraform.io unreachable — rerun when online).

# tf-plan-smoke — terraform fixture plan smoke (77 = skipped-network).
tf-plan-smoke:
    @echo "[COURT] T4: terraform fixture plan smoke..."
    @bash scripts/tf_smoke.sh

# RETIRED (v26.10.19 reset): test/sdk-smoke/eh-run.mjs deleted. Successor:
# verification/ts Event Hubs probes (V261019-08). LOUD no-op (exit 1).
eh-smoke:
    @echo "[RETIRED] eh-smoke: test/sdk-smoke deleted at 64f6099; successor = verification/ts EH probes (V261019-08). Exit 1 until it lands."; exit 1

# Service Bus census: successor LANDED (V261019-08) — verification/ts
# census.test.cjs (11 probes, live AMQP) + sb-extra.probe.cjs. Exit 0/1.
@census:
    #!/usr/bin/env bash
    set -euo pipefail
    node --test verification/ts/census.test.cjs
    node verification/ts/sb-extra.probe.cjs || echo "[census] sb-extra: honest typed fail (see receipt 08-servicebus-census.md)"

# LOUD no-op placeholders for the fresh verification/ lanes (V261019-08/09).
# Repoint these to the verification/ts and verification/py entry points as
# soon as those land; until then they exit 1 loudly — never a silent pass.
sdk-ts-court:
    @echo "[RETIRED] sdk-ts-court: awaiting verification/ts entry point (V261019-08); this placeholder exits 1."; exit 1

sdk-py-court:
    @echo "[RETIRED] sdk-py-court: awaiting verification/py entry point (V261019-09); this placeholder exits 1."; exit 1

# Mutation court: prove the 422/400 validator gate is non-vacuous
# (scripts/mutation_court.py). Exit 0 non-vacuous / 1 vacuous / 2 BLOCKED.
# Court note: exit 2 (shared compile broken after 3 retries) is a HARD FAIL
# inside `just court` — do not soften.
mutation-court:
    @python3 scripts/mutation_court.py

# Six fail-closed invariant gates (cosmos ETag CAS, blob WORM, ledger chain,
# queue capacity, lock clamp, appconfig ETag CAS), each booting its own
# substrate on private ports. Non-vacuity: a gate exits 0 only if the positive
# capture passes AND every negative fixture is refused (gates/common.py:9-13).
# Receipts: tmp/invariant-gates/<gate>-receipt.json (6, written fresh).
@invariant-gates:
    python3 scripts/invariant_gates.py

# Regenerate docs/ERROR_CODES.md from the generator's ANNOTATIONS table
gen-error-codes:
    python3 scripts/gen_error_codes.py

# Naming/leak sweep (scripts/naming_sweep.sh): greps tracked files for
# 'athena|/Users/sac|courtroom|\bcai\b|morluto' against a line-precise
# allowlist. Exit 0 clean (0 violations) / 1 leak found (violations printed).
@naming-sweep:
    bash scripts/naming_sweep.sh

# ============================================================================
# Benchmarks & Stress
# ============================================================================

# Full benchmark: boots substrate, measures PRD CTQs (scripts/bench.py),
# writes tmp/bench-receipt.json. Exit 0 complete / nonzero on failure. ~2-5m.
bench:
    @python3 scripts/bench.py

# Regression gate over tmp/bench-receipt.json (scripts/bench_check.py).
# Exit 0 all CTQs pass / 1 missing/stale/failing receipt. ~1s.
bench-check:
    @echo "[COURT] Performance regression gate..."
    @python3 scripts/bench_check.py

# Sustained 25-minute mixed-traffic soak (scripts/stress/soak.py), 50 rps.
# Fails on any 5xx, RSS growth >20% after min 5, or any error. ~25m.
soak:
    @python3 scripts/stress/soak.py

# Spike-stress harness (scripts/stress/spike.py): 500-concurrent spike,
# recovery cycles, TLS herd. Exit 0 pass / nonzero fail. ~5-10m.
spike:
    @python3 scripts/stress/spike.py

# TLS churn benchmark against the 9444 TLS twin (scripts/stress/tls_churn.py).
# Fail-closed; exit nonzero if any scenario cannot complete. ~2-5m.
tls-churn:
    @python3 scripts/stress/tls_churn.py

# ============================================================================
# Aggregate Gates
# ============================================================================

# Full admission court: doctor + test-offline (mix test over test/internal) +
# tf smoke + bench gate + mutation court + census + invariant gates +
# naming sweep + verification governance gates.
# Exit 0 only when every member passes. Census is currently a RETIRED stage
# (subject deleted at 64f6099; successor verification/ts census, V261019-08):
# it exits 1 loudly and keeps the court RED until its successor lands — the
# court is never green over a retired stage. Verification-gates comes from
# justfile.d/32-verification.just (imported below). Bench note: run
# `just bench` before `just court` on a perf-relevant change — a stale-receipt
# bench-check failure is remediated by `just bench`, never by touching the gate.
court: doctor test-offline tf-plan-smoke bench-check \
        mutation-court census invariant-gates naming-sweep verification-gates
    @echo "[COURT] Full gate passed."

# Compatibility alias for `court` (legacy name). Same courts, same exits.
gate: court
    @echo "[COURT] Full gate passed."

# ============================================================================
# First Run
# ============================================================================

# Zero-to-green first-run bootstrap: prereqs, deps, compile, env check,
# certs, doctor, boot smoke, proof test. Idempotent; safe to rerun.
# Exit 0 green / 1 stage failed / 2 missing prereqs.
bootstrap:
    @bash scripts/bootstrap.sh


# DoD lane modules (definition-of-done; each owned by one lane)
import 'justfile.d/01-substrate-lock.just'
import 'justfile.d/02-workspace.just'
import 'justfile.d/03-cli-wiring.just'
import 'justfile.d/04-sdk-recipes.just'
import 'justfile.d/05-doctor-ext.just'
import 'justfile.d/06-lane-cleanup.just'
import 'justfile.d/07-court-x2.just'
import 'justfile.d/08-publish-dry.just'
import 'justfile.d/09-verify-all.just'
import 'justfile.d/10-gap-register-sync.just'
import 'justfile.d/11-relay-env.just'
import 'justfile.d/12-docs-dod.just'
import 'justfile.d/13-receipt-index.just'
# 14-sdk-matrix — SDK coverage matrix (DoD-14)
import 'justfile.d/14-sdk-matrix.just'
import 'justfile.d/15-bench.just'
# 18-shim-court — reusable shim-court harness (lane S-6)
import 'justfile.d/18-shim-court.just'
# 19-wave-telemetry — wave-level wall-clock telemetry (lane S-8)
import 'justfile.d/19-wave-telemetry.just'
# 20-sobelow — static security analysis (ERRC lane 8 Raise; non-blocking)
import 'justfile.d/20-sobelow.just'
# 21-enclave — e1 enclave-loop bench lane (tf provision -> data plane -> console -> residue)
import 'justfile.d/21-enclave.just'
import 'justfile.d/22-native.just'
import 'justfile.d/23-compliance.just'
import 'justfile.d/24-quiesce.just'
import 'justfile.d/25-leak-court.just'
import 'justfile.d/26-rewitness.just'
import 'justfile.d/27-scratch-soak.just'
import 'justfile.d/28-stress.just'
import 'justfile.d/28-test-budget.just'
import 'justfile.d/29-sleep.just'
import 'justfile.d/30-burn.just'
# 31-have — HAVE supervisory engine L1 operator recipes (HAVE-10)
import 'justfile.d/31-have.just'
# 32-verification — verification governance gates (V261019, non-duplication +
# portable-target; verification/ + test/internal surfaces)
import 'justfile.d/32-verification.just'
import 'justfile.d/33-sleep-gate-ext.just'
import 'justfile.d/34-nightly.just'
# 35-envelope — Phase 2 envelope gates (automation + container)
import 'justfile.d/35-envelope.just'
# 40-popcorn — popcorn_demo Chicago testbed (in-browser WASM BEAM + live legs)
import 'justfile.d/40-popcorn.just'
# 41-popcorn-errc — popcorn_demo ERRC operator tooling (status / lane-clean / receipts)
import 'justfile.d/41-popcorn-errc.just'
# 42-popcorn-bench — popcorn_demo bench lanes (legs / cook / fence-check)
import 'justfile.d/42-popcorn-bench.just'
# 43-scvd — SCVD tier runner (SCVD-T9)
import 'justfile.d/43-scvd.just'
# 44-obsfence — AR-OBS-03 tprof memory-ceiling fence (gate + court)
import 'justfile.d/44-obsfence.just'
# 45-impl24 — IMPL-24 reductions ceiling fence (gate + court)
import 'justfile.d/45-impl24.just'
# 46-bench — BENCH-8 pure-Erlang bench court escript runner
import 'justfile.d/46-bench.just'
# 47-bench-framework — BENCH-14 prospective zero-framework bench gate
import 'justfile.d/47-bench-framework.just'
# 44-witness — BK-8/BK-44 witness-all fail-closed receipt re-witness gate
import 'justfile.d/44-witness.just'
# 48-private-trip — COURT-PRIVATE-TRIP private-token gate (NFR-SEC-004)
import 'justfile.d/48-private-trip.just'
# 49-heir-guard — BK-57 heir-table init-guard gate (BK-33 warm-restart class)
import 'justfile.d/49-heir-guard.just'
import 'justfile.d/50-pattern-court.just'
# 51-bkvc — BK-VCOURTS consolidated validation-board courts (v26.10.22)
import 'justfile.d/51-bkvc.just'
import 'justfile.d/52-kind.just'
# 53-trivy — NIST W3 / RA-5 trivy image-scan receipts (v26.10.22, BK-NISTW3)
import 'justfile.d/53-trivy.just'

# 54-checkpoint — SHIM-COURT checkpoint gate (BK-SHIMGATE, v26.10.22)
import 'justfile.d/54-checkpoint.just'

# 55-sovereign-image — neutral-tag sovereign image build (R10, v26.10.25)
import 'justfile.d/55-sovereign-image.just'

# 56-courtroom — T03 consumer court: courtroom-platform-az on smalt (v26.10.29)
import 'justfile.d/56-courtroom.just'
import 'justfile.d/57-tf-provider.just'
# 58-posh — POSH orchestration: generate/build/install/court (v26.10.30 L5)
import 'justfile.d/58-posh.just'
# 59-posh-ops — POSH membrane process ops: posh-up/posh-down (v26.10.30 P1)
import 'justfile.d/59-posh-ops.just'
# 60-dod — DoD single-source reader: just dod / dod-section (v26.10.30 lane 1)
import 'justfile.d/60-dod.just'
