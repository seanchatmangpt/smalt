# 31-have.just — HAVE supervisory engine recipes (component 9, v26.10.18)
#
# One `just` surface over scripts/have/: the 5m pool guard (L1), the 30m meta
# watchdog (L2), the metric catalog emitter, the four recovery procedures, and
# a status snapshot. Honest values: a recipe that cannot observe its subject
# exits typed (UNSUPPORTED/typed SKIP), never a faked pass. have-install-
# crontab PRINTS the two crontab lines — it never writes the crontab.

root := justfile_directory()
HAVE_DIR := root / "tmp" / "have"

# L1 pool saturation guard: one cycle (typed alert + dispatch request on
# deficit, heartbeat touch). Exit 0 always — the JSON IS the verdict.
@have-guard:
    cd {{root}} && python3 scripts/have/pool_saturation_guard.py

# L2 meta watchdog (30m). Default dry-run (prints actions, executes nothing);
# HAVE_ENFORCE=1 runs the real watchdog (RP-01 automation may sweep dead beams
# / reclaim verified-dead ports). Exit 0 quiet / 1 alerts fired / 2 config.
@have-watchdog:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    if [ "${HAVE_ENFORCE:-0}" = "1" ]; then
        echo "[HAVE-WATCHDOG] ENFORCE: live run (RP-01 automation armed)"
        exec python3 scripts/have/meta_watchdog.py
    fi
    echo "[HAVE-WATCHDOG] dry-run (HAVE_ENFORCE=1 to arm RP-01 automation)"
    exec python3 scripts/have/meta_watchdog.py --dry-run

# Metric catalog emitter: one typed JSONL row per have_* metric (ABSENT is
# typed, never a faked zero). Exit 0 rows emitted / 2 usage.
@have-telemetry:
    cd {{root}} && python3 scripts/have/telemetry.py --emit-all

# RP-01 — automated restart: enforced watchdog pass; its step-1 fires only on
# a stale heartbeat (>600s) and never touches live lanes (cwd-prefix rule).
@have-rp01:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    echo "[HAVE-RP01] enforced meta-watchdog pass (RP-01 fires only on heartbeat deadlock)"
    exec python3 scripts/have/meta_watchdog.py

# RP-02 — deterministic storage recovery probe (read-only, never repairs):
# header inspect + strict fail-closed clean-open verify + ledger pointer.
@have-rp02:
    cd {{root}} && python3 scripts/have/storage_probe.py --inspect-headers --verify-clean-open --ledger-pointer

# RP-03 — OCEL referential-integrity recovery audit: validate the newest
# *.ocel.json burn projection (dangling relationship objectIds). Typed SKIP
# (exit 0, loud) when no OCEL projection exists — the audit surface is empty,
# which is a reason, not a pass.
@have-rp03:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    log="$(ls -t docs/jira/*/burn/**/*.ocel.json docs/jira/*/burn/*.ocel.json tmp/ocel/*.ocel.json 2>/dev/null | head -1 || true)"
    if [ -z "${log:-}" ]; then
        echo "[HAVE-RP03] [SKIP] no *.ocel.json projection found (docs/jira/*/burn, tmp/ocel) — audit surface empty"
        exit 0
    fi
    echo "[HAVE-RP03] validating newest OCEL projection: ${log}"
    exec python3 scripts/validate_ocel2.py "${log}"

# RP-04 — formal conformance: replay the newest OCEL 2.0 log against the
# canonical settlement Petri net. Exit 0 conformant / 1 imbalance
# (REGRESSION quarantines to tmp/have/QUARANTINE) / 2 usage/IO.
@have-rp04:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    log="$(ls -t docs/jira/*/burn/**/*.ocel.json docs/jira/*/burn/*.ocel.json tmp/ocel/*.ocel.json 2>/dev/null | head -1 || true)"
    log2="${log:-}"
    if [ -z "${log2}" ]; then
        echo "[HAVE-RP04] [SKIP] no *.ocel.json projection found — net has nothing to replay; loud skip, not a pass"
        exit 0
    fi
    echo "[HAVE-RP04] replaying newest OCEL projection: ${log2}"
    exec python3 scripts/have/petri_conformance.py "${log2}"

# Status snapshot: full telemetry emit + heartbeat + alert/dispatch summary
# from tmp/have ledgers. Report-only, exit 0.
@have-status:
    #!/usr/bin/env bash
    set -uo pipefail
    cd "{{root}}"
    echo "== HAVE status @ $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
    echo "-- telemetry snapshot --"
    python3 scripts/have/telemetry.py --emit-all || echo "[HAVE-STATUS] telemetry emitter failed (typed rows above)"
    echo "-- heartbeat --"
    if [ -f tmp/have/have_l1.heartbeat ]; then
        cat tmp/have/have_l1.heartbeat
        python3 scripts/have/state_ledger.py heartbeat || true
    else
        echo "[HAVE-STATUS] no L1 heartbeat yet (tmp/have/have_l1.heartbeat absent) — L1 never ran"
    fi
    echo "-- alert summary --"
    python3 - <<'PY'
    import json, os
    for name in ("state_ledger.jsonl", "dispatch_requests.jsonl"):
        p = os.path.join("tmp", "have", name)
        if not os.path.exists(p):
            print(f"{name}: ABSENT (guard never ran)")
            continue
        sev, kinds = {}, {}
        total = 0
        for line in open(p):
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            total += 1
            k = row.get("kind", row.get("type", "?"))
            kinds[k] = kinds.get(k, 0) + 1
            s = row.get("severity")
            if s:
                sev[s] = sev.get(s, 0) + 1
        print(f"{name}: {total} rows; kinds={kinds}" + (f"; severities={sev}" if sev else ""))
    PY

# Print (never install) the two cron lines for the HAVE loops, adapted from
# docs/reference/have-runbook.md templates with this checkout's absolute path.
@have-install-crontab:
    #!/usr/bin/env bash
    set -euo pipefail
    ROOT="{{root}}"
    cat <<EOF
    # HAVE loops — add with 'crontab -e'. Print-only recipe; nothing was installed.
    */5 * * * * cd $ROOT && python3 scripts/have/pool_saturation_guard.py >> $ROOT/tmp/have/cron.log 2>&1
    */30 * * * * cd $ROOT && python3 scripts/have/meta_watchdog.py >> $ROOT/tmp/have/cron.log 2>&1
    EOF
    echo "[HAVE-INSTALL-CRONTAB] printed 2 lines; install manually with 'crontab -e' (never auto-install)"
