#!/usr/bin/env bash
# measurement_liveness_court.sh — Tier-3 measurement-liveness court (KD-210).
# KD-COVERS: KD-210 (provenance vacuous-gate class: a metric that does not
# move under perturbation was never measured — it is a pinned constant).
#
# Protocol: BASELINE -> BEFORE -> SHIM -> AFTER -> RESTORE via lib.sh, run
# against a subject bench script (parameterized: $1 = path to a bench command
# script that prints ONE numeric metric; default = a self-contained inline
# erl one-liner bench, no full-suite dependency).
#
# LIVE proof (independent of the shim phases): run the subject twice —
# normal, then perturbed (SMALT_LIVENESS_DELAY=1). The metric MUST move by
# a ratio >= LIVENESS_RATIO (default 1.5); otherwise the court exits 1 with
# NOT-LIVE: the metric was never measured.
#
# Non-vacuity (shim phases): BEFORE = live check passes on the pristine
# subject. SHIM = replace the subject body with `echo 42` (pinned constant,
# marked SHIM-COURT). AFTER = the live check must now FAIL (a constant does
# not move under perturbation -> NOT-LIVE). A court that passes the stub is
# vacuous and exits 1 here. RESTORE = sha256 byte-exact, fail-closed.
#
# Exit 0 LIVE+non-vacuous / 1 fail / 3 loud skip.
set -euo pipefail
cd "$(dirname "$0")" && source ./lib.sh

RATIO_THRESHOLD="${LIVENESS_RATIO:-1.5}"
export RATIO_THRESHOLD

# --- subject bench script ----------------------------------------------------

make_subject() {
    # Default demonstration subject: tiny inline erl bench, honors
    # SMALT_LIVENESS_DELAY by scheduling a real-world interval (sleep 500ms)
    # before measuring an arithmetic loop; prints wall ms on stdout.
    cat > "$1" <<'EOS'
#!/usr/bin/env bash
exec erl -noshell -eval '
  T0 = erlang:monotonic_time(millisecond),
  case os:getenv("SMALT_LIVENESS_DELAY") of
      false -> ok;
      _ -> timer:sleep(500)
  end,
  _ = [I * I || I <- lists:seq(1, 200000)],
  T1 = erlang:monotonic_time(millisecond),
  io:format("~p~n", [max(1, T1 - T0)]),
  halt(0).' -s init stop
EOS
    chmod +x "$1"
}

# --- liveness probe -----------------------------------------------------------

metric_of() {
    # Bounded: a hung/crashed subject must fail loud, not block the court.
    if command -v timeout >/dev/null 2>&1; then
        timeout 30 bash "$1" </dev/null
    else
        bash "$1" </dev/null
    fi
}

metric_of_perturbed() {
    # env (not a VAR= prefix on the function call — bash does not export
    # those into the function's children): the perturbation MUST reach the
    # subject process or the court silently reads an unperturbed run.
    if command -v timeout >/dev/null 2>&1; then
        env SMALT_LIVENESS_DELAY=1 timeout 30 bash "$1" </dev/null
    else
        env SMALT_LIVENESS_DELAY=1 bash "$1" </dev/null
    fi
}

liveness_check() {
    # exit 0 = LIVE (metric moved >= threshold), 1 = NOT-LIVE.
    local subject="$1" normal perturbed ratio
    if ! normal="$(metric_of "$subject")"; then
        echo "[FAIL:LIVENESS] subject run failed (normal)" >&2; return 1
    fi
    if ! perturbed="$(metric_of_perturbed "$subject")"; then
        echo "[FAIL:LIVENESS] subject run failed (perturbed)" >&2; return 1
    fi
    ratio="$(awk -v n="$normal" -v p="$perturbed" 'BEGIN { if (n + 0 <= 0) print "inf"; else printf "%.3f", (p + 0) / (n + 0) }')"
    printf '[liveness] normal=%s perturbed=%s ratio=%s threshold=%s\n' \
        "$normal" "$perturbed" "$ratio" "$RATIO_THRESHOLD"
    awk -v r="$ratio" -v t="$RATIO_THRESHOLD" 'BEGIN { exit (r == "inf" || r + 0 >= t + 0) ? 0 : 1 }' \
        || { echo "NOT-LIVE: metric did not move beyond ratio threshold — never measured" >&2; return 1; }
    echo "LIVE: metric moved under perturbation (ratio >= $RATIO_THRESHOLD)"
    return 0
}

# --- shim ---------------------------------------------------------------------

apply_shim() {
    # Replace the subject bench with a pinned constant (KD-210 stub class).
    printf '#!/usr/bin/env bash\n# SHIM-COURT: metric stubbed to constant 42\necho 42\n' > "$SHIM_FILE"
}

# --- court --------------------------------------------------------------------

shim_court_self_check || exit 1

# Witnesses run under `bash -uc` (a fresh shell) — export the probe functions.
export -f liveness_check metric_of metric_of_perturbed

SUBJECT="${1:-}"
OWNED_TMP=0
if [ -z "$SUBJECT" ]; then
    SUBJECT="$(mktemp "${TMPDIR:-/tmp}/liveness_subject.XXXXXX")"
    OWNED_TMP=1
    make_subject "$SUBJECT"
elif [ ! -f "$SUBJECT" ]; then
    shim_court_fail BASELINE "subject bench script not found: $SUBJECT"
fi

if ! command -v erl >/dev/null 2>&1; then
    [ "$OWNED_TMP" = 1 ] && rm -f "$SUBJECT"
    shim_court_skip "erl not on PATH — liveness court needs a BEAM runtime"
fi

# Independent LIVE proof on the pristine subject (before the shim phases).
if ! liveness_check "$SUBJECT"; then
    rm -f "$SUBJECT"
    shim_court_fail BEFORE "pristine subject is NOT-LIVE (metric did not move) — nothing to prove"
fi
echo "[liveness] pristine subject is LIVE"

# Shim phases: BEFORE = live passes (old signature), AFTER = live MUST FAIL
# on the `echo 42` stub (new outcome: the court catches the constant).
BEFORE_WITNESS="liveness_check '$SUBJECT'"
AFTER_WITNESS="! liveness_check '$SUBJECT'"

rc=0
with_shim "$SUBJECT" "$BEFORE_WITNESS" "$AFTER_WITNESS" || rc=$?

[ "$OWNED_TMP" = 1 ] && rm -f "$SUBJECT"
exit "$rc"
