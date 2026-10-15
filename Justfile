set shell := ["bash", "-euo", "pipefail", "-c"]

PID_FILE := "/tmp/smalt.pid"
PORTS := "9443 9444 5672 5673"

# default recipe: run the full admission court (alias of `court`)
default: court

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
up:
    @echo "[SMALT] Starting sovereign Azure drop-in substrate on BEAM..."
    @bash -c 'trap "kill $$ 2>/dev/null; [ -f {{PID_FILE}} ] && kill $(cat {{PID_FILE}}) 2>/dev/null || true" EXIT; echo $$ > {{PID_FILE}}; mix run --no-halt'

# Stop the substrate via the pid file. Idempotent; exit 0 either way. ~0s.
down:
    @bash -c 'if [ -f {{PID_FILE}} ]; then kill $(cat {{PID_FILE}}) 2>/dev/null || true; rm -f {{PID_FILE}}; echo "[SMALT] Substrate stopped."; else echo "[SMALT] No pid file at {{PID_FILE}}."; fi'

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

# T2: wire-tier suite (mix test test/wire). Exit 0 pass / nonzero on failure.
test-wire:
    @echo "[COURT] T2: wire-tier suite..."
    @mix test test/wire

# T3: SDK smoke tier (test/sdk-smoke/run.mjs). Exit 0 pass / 1 probe failure /
# 2 substrate never up / 3 harness failure.
test-sdk-smoke:
    @echo "[COURT] T3: SDK smoke tier..."
    @node test/sdk-smoke/run.mjs

# T4: terraform fixture plan smoke (scripts/tf_smoke.sh).
# Exit 0 pass / 1 preflight or substrate failure / 2 terraform step failure /
# 77 SKIPPED-NETWORK (registry.terraform.io unreachable — the court WILL fail
# on an offline network; rerun when online).
tf-plan-smoke:
    @echo "[COURT] T4: terraform fixture plan smoke..."
    @bash scripts/tf_smoke.sh

# SDK smoke: Event Hubs lane (test/sdk-smoke/eh-run.mjs). Boots its own
# substrate. Exit 0 pass / 1 probe failure / 2 substrate never up / 3 harness.
eh-smoke:
    @node test/sdk-smoke/eh-run.mjs

# Service Bus census replay (scripts/sb_census_replay.sh, 8 probes, real SDK).
# Exit 0 all pass / 1 census failure / 2 substrate never up / 3 harness.
census:
    @bash scripts/sb_census_replay.sh

# Mutation court: prove the 422/400 validator gate is non-vacuous
# (scripts/mutation_court.py). Exit 0 non-vacuous / 1 vacuous / 2 BLOCKED.
mutation-court:
    @python3 scripts/mutation_court.py

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

# Full admission court: doctor + all test tiers + tf smoke + bench gate.
# Exit 0 only when every court passes.
court: doctor test-offline test-wire test-sdk-smoke tf-plan-smoke bench-check
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
