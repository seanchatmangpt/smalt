#!/usr/bin/env bash
# overlap_court.sh — AZB-19 port-free stage overlap scheduler.
#
# Ticket: docs/jira/v26.10.18/azsim-burn/TICKETS.md AZB-19.
# Stages declare resources (ports, build_root, dets_dir); the scheduler runs
# stages with disjoint resource sets in parallel (fixed phases):
#   p1 {t1-offline ∥ mutation-court ∥ tf-plan-smoke ∥ port-free statics}
#   p2 {t2-wire ∥ t3-sdk-smoke}   (ticket phase 2: wire ∥ container-class)
# Background stages run at lowered CPU priority (taskpolicy -c utility) so the
# load-class chain keeps performance cores.
# Laws: never T1 ∥ T3 (load class); per-stage MIX_BUILD_ROOT=tmp/azb19/roots/<stage>
# (outside the _build* lane-clean sweep — a concurrent lane-clean reclaimed
# in-sweep roots mid-run, witnessed 2026-10-18);
# two overlapped stages sharing a MIX_BUILD_ROOT ⇒ RESOURCE_CONFLICT refusal
# (anti-vacuity); any serial-vs-overlapped verdict difference is the falsifier.
#
# Modes:
#   serial         run every stage sequentially (baseline schedule)
#   overlap        run the phase-parallel schedule
#   check SCHED    validate a schedule (stages/phase pairs on stdin); exits 1
#                  with RESOURCE_CONFLICT / LOAD_CONFLICT on any clash
#   compare A B    verdict-identity check between two result jsonl (exit 1 on diff)
#   report FILES   print wall clocks + median
#
# Env: AZB19_TAG (default "azb19"), AZB19_RUNS_ROOT (default tmp/azb19).
set -uo pipefail
cd "$(dirname "$0")/.."

TAG="${AZB19_TAG:-azb19}"
RUNS_ROOT="${AZB19_RUNS_ROOT:-tmp/azb19}"
BASE_ROOT="${AZB19_BASE_ROOT:-tmp/azb19/roots/base}"
ROOT_PREFIX="${AZB19_ROOT_PREFIX:-tmp/azb19/roots/}"

# ---------------------------------------------------------------------------
# Stage table:  name|phase|resources|command
# resources: comma-separated tokens:
#   port:<n>      stage binds TCP port n (exclusive while running)
#   build:<name>  stage uses build root <ROOT_PREFIX><name>
#   dets:<dir>    stage uses DETS dir <dir> (exclusive while running)
#   load          load class; t1-offline ∥ t3-sdk-smoke is forbidden pairwise
# Port shifts (39373 mutation, 39380 tf) keep lane substrates off the shared
# substrate's canonical ports; the SAME shifts apply in serial and overlap
# modes, so the comparison is apples-to-apples.
# ---------------------------------------------------------------------------
STAGES=(
  "doctor|1||python3 scripts/doctor.py"
  "bench-check|1||python3 scripts/bench_check.py"
  "census|1||if [ -z \"\${SMALT_SDK_ROOT:-}\" ]; then echo '[census] SKIP: SMALT_SDK_ROOT not set'; exit 0; else exec bash scripts/sb_census_replay.sh; fi"
  "naming-sweep|1||bash scripts/naming_sweep.sh"
  # t2-wire / t3-sdk-smoke rows RETIRED (v26.10.19 reset 64f6099: test/wire,
  # test/sdk-smoke deleted). Successors: verification/ suites (V261019-08/09)
  # — re-add rows when those land; TODO(V261019-08).
  "invariant-gates|1|build:invg|taskpolicy -c utility env MIX_BUILD_ROOT=${ROOT_PREFIX}invg python3 scripts/invariant_gates.py"
  "t1-offline|1|build:t1,load|env MIX_BUILD_ROOT=${ROOT_PREFIX}t1 mix test"
  "mutation-court|1|build:mutation,port:auto-mutation|taskpolicy -c utility env MIX_BUILD_ROOT=${ROOT_PREFIX}mutation python3 scripts/mutation_court.py"
  "tf-plan-smoke|1|port:39380,port:39381,port:39382,port:39383,port:39384,port:39385|taskpolicy -c utility env SMALT_TF_PORT=39380 SMALT_TLS_PORT=39381 bash scripts/tf_smoke.sh"
)

# Load-class exclusion (launcher law): these pairs must never overlap.
EXCLUDED_PAIRS=("t1-offline:t3-sdk-smoke" "t3-sdk-smoke:t1-offline")

die() { echo "[OVERLAP-COURT] $*" >&2; exit 1; }

stage_name() { printf '%s' "$1" | cut -d'|' -f1; }
stage_phase() { printf '%s' "$1" | cut -d'|' -f2; }
stage_resources() { printf '%s' "$1" | cut -d'|' -f3; }
stage_cmd() { printf '%s' "$1" | cut -d'|' -f4; }

# ---------------------------------------------------------------------------
# Conflict validation. Input: stage rows that would run CONCURRENTLY.
# Prints one "CONFLICT <type> <a> <b> <token>" line per clash; exits 1 if any.
# ---------------------------------------------------------------------------
validate_concurrent() {
    local rows=("$@") i j bad=0
    (( ${#rows[@]} <= 1 )) && return 0
    for ((i = 0; i < ${#rows[@]}; i++)); do
        for ((j = i + 1; j < ${#rows[@]}; j++)); do
            local a="${rows[i]}" b="${rows[j]}"
            local an bn ta tb
            an="$(stage_name "$a")"; bn="$(stage_name "$b")"
            # load-class pair exclusion
            local pair
            for pair in "${EXCLUDED_PAIRS[@]}"; do
                if [[ "$an" == "${pair%%:*}" && "$bn" == "${pair##*:}" ]]; then
                    echo "CONFLICT LOAD_CONFLICT $an $bn load"
                    bad=1
                fi
            done
            # token clashes
            local ta tb tok
            local IFS=','
            read -ra ta <<<"$(stage_resources "$a")"
            read -ra tb <<<"$(stage_resources "$b")"
            unset IFS
            for tok in "${ta[@]}"; do
                [[ -z "$tok" ]] && continue
                if printf '%s\n' "${tb[@]}" | grep -qxF "$tok"; then
                    echo "CONFLICT RESOURCE_CONFLICT $an $bn $tok"
                    bad=1
                fi
            done
        done
    done
    return $bad
}

# ---------------------------------------------------------------------------
# Build roots: warmed base cloned per stage (APFS clonefile via cp -Rc when
# supported). Copies preserve mtimes, so mix considers the clone fresh.
# ---------------------------------------------------------------------------
ensure_build_root() {
    local stage="$1"
    local dir="${ROOT_PREFIX}${stage}"
    [[ -d "$dir" ]] && return 0
    if [[ ! -d "$BASE_ROOT" ]]; then
        echo "[OVERLAP-COURT] warming base build root (mix compile)..."
        MIX_BUILD_ROOT="$BASE_ROOT" mix compile >/dev/null 2>&1 || die "base build root warm failed"
    fi
    echo "[OVERLAP-COURT] cloning $BASE_ROOT -> $dir"
    cp -Rc "$BASE_ROOT" "$dir" 2>/dev/null || cp -R "$BASE_ROOT" "$dir"
}

# run_stage <stage-row> <rundir> — executes the stage command; returns exit.
run_stage() {
    local row="$1" rundir="$2"
    local name cmd log tok
    name="$(stage_name "$row")"
    cmd="$(stage_cmd "$row")"
    log="$rundir/${name}.log"
    # ensure every declared build:<name> root exists (cloned from base);
    # stages without a build: token get MIX_BUILD_ROOT=<prefix><stage> —
    # harmless for pure-python stages, correct for any un-declared mix stage.
    local declared=0
    local IFS=','
    read -ra toks <<<"$(stage_resources "$row")"
    unset IFS
    for tok in "${toks[@]}"; do
        [[ "$tok" == build:* ]] || continue
        declared=1
        ensure_build_root "${tok#build:}"
    done
    if (( ! declared )) && ! grep -q "MIX_BUILD_ROOT=" <<<"$cmd"; then
        cmd="export MIX_BUILD_ROOT=${ROOT_PREFIX}${name}; $cmd"
    fi
    local _t0 _t1
    _t0=$(date +%s)
    (
        eval "$cmd"
    ) >"$log" 2>&1
    local rc=$?
    _t1=$(date +%s)
    printf '%s %s %s\n' "$name" "$rc" $((_t1 - _t0)) >"$rundir/.wall.$name"
    return $rc
}

# ---------------------------------------------------------------------------
# Schedules
# ---------------------------------------------------------------------------
rows_in_phase() {
    local p="$1" r
    for r in "${STAGES[@]}"; do
        [[ "$(stage_phase "$r")" == "$p" ]] && printf '%s\n' "$r"
    done
}

serial_run() {
    local rundir="$1" t0 t1 total row name rc
    mkdir -p "$rundir"
    t0=$(python3 -c 'import time; print(time.time())')
    for row in "${STAGES[@]}"; do
        name="$(stage_name "$row")"
        echo "[OVERLAP-COURT] serial: $name"
        validate_concurrent "$row" >/dev/null || die "self-conflict on $name"
        run_stage "$row" "$rundir"; rc=$?
        echo "[OVERLAP-COURT] serial: $name stage_wall_s=$(cut -d' ' -f3 "$rundir/.wall.$name")"
        cat "$rundir/.wall.$name" >>"$rundir/verdicts.txt"
    done
    t1=$(python3 -c 'import time; print(time.time())')
    total=$(python3 -c "print(f'{$t1-$t0:.1f}')")
    emit_result "$rundir" serial "$total"
}

overlap_run() {
    local rundir="$1" t0 t1 total p row rc bad=0
    mkdir -p "$rundir"
    t0=$(python3 -c 'import time; print(time.time())')
    for p in 1 2 3; do
        local rows=()
        while IFS= read -r row; do rows+=("$row"); done < <(rows_in_phase "$p")
        validate_concurrent "${rows[@]}" || { validate_concurrent "${rows[@]}" >/dev/null; die "schedule refused (see CONFLICT lines above)"; }
        echo "[OVERLAP-COURT] phase $p: $(printf '%s ' "${rows[@]}" | cut -d'|' -f1)"
        local pids=()
        for row in "${rows[@]}"; do
            run_stage "$row" "$rundir" &
            pids+=("$!")
        done
        local i=0
        for row in "${rows[@]}"; do
            wait "${pids[$i]}"; rc=$?
            local name; name="$(stage_name "$row")"
            echo "[OVERLAP-COURT] phase $p: $name exit=$rc"
            cat "$rundir/.wall.$name" >>"$rundir/verdicts.txt"
            (( rc != 0 )) && bad=1
            (( i++ ))
        done
    done
    t1=$(python3 -c 'import time; print(time.time())')
    total=$(python3 -c "print(f'{$t1-$t0:.1f}')")
    emit_result "$rundir" overlap "$total"
    return $bad
}

emit_result() {
    local rundir="$1" mode="$2" total="$3"
    local head_sha
    head_sha="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
    {
        printf '{"schema":"smalt-overlap/v1","mode":"%s","tag":"%s","total_s":%s,"head":"%s"}\n' \
            "$mode" "$TAG" "$total" "$head_sha"
        local n rc wall
        while read -r n rc wall; do
            printf '{"stage":"%s","exit":%s,"wall_s":%s}\n' "$n" "$rc" "${wall:-null}"
        done <"$rundir/verdicts.txt"
    } >"$rundir/result.jsonl"
}

# ---------------------------------------------------------------------------
# Mode dispatch
# ---------------------------------------------------------------------------
MODE="${1:-}"
case "$MODE" in
    serial) shift; serial_run "$RUNS_ROOT/${TAG}-serial-$(date +%s)" ;;
    overlap) shift; overlap_run "$RUNS_ROOT/${TAG}-overlap-$(date +%s)" ;;
    check)
        # read stage rows (same 4-field format) from stdin as one concurrent set
        rows=()
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            rows+=("$line")
        done
        validate_concurrent "${rows[@]}"
        exit $?
        ;;
    compare)
        shift
        exec python3 - "$@" <<'PY'
import json, sys
def load(p):
    st = {}
    for line in open(p):
        r = json.loads(line)
        if "stage" in r:
            st[r["stage"]] = r["exit"]
    return st
A, B = load(sys.argv[1]), load(sys.argv[2])
print(f"[COMPARE] {sys.argv[1]} vs {sys.argv[2]}")
bad = 0
for k in sorted(set(A) | set(B)):
    if k not in A or k not in B:
        print(f"[COMPARE] MISSING {k}")
        bad = 1
    elif A[k] != B[k]:
        print(f"[COMPARE] VERDICT DIFF {k}: serial={A[k]} overlap={B[k]}")
        bad = 1
if bad:
    print("[COMPARE] FALSIFIER FIRED: verdicts differ between schedules")
    sys.exit(1)
print("[COMPARE] OK: all stage verdicts identical between serial and overlapped schedules")
sys.exit(0)
PY
        ;;
    report)
        shift
        exec python3 - "$@" <<'PY'
import json, sys, statistics
def total(p):
    for line in open(p):
        r = json.loads(line)
        if "total_s" in r:
            return r["total_s"]
    raise SystemExit(f"no total_s in {p}")
ts = [total(p) for p in sys.argv[1:]]
print("walls_s:", ts, "median_s:", statistics.median(ts))
PY
        ;;
    anti-vacuity)
        # Two witnesses, both must REFUSE (a pass here is the failure):
        # 1) two overlapped stages sharing a MIX_BUILD_ROOT -> RESOURCE_CONFLICT
        # 2) t1-offline ∥ t3-sdk-smoke -> LOAD_CONFLICT
        pfx="$ROOT_PREFIX"
        bad_row="dup-build|1|build:shared,dets:tmp/d|env MIX_BUILD_ROOT=${pfx}shared mix test"
        clash_row="other|1|build:shared|env MIX_BUILD_ROOT=${pfx}shared mix test"
        echo "[ANTI-VACUITY] witness 1: two overlapped stages, same MIX_BUILD_ROOT"
        out="$(printf '%s\n%s\n' "$bad_row" "$clash_row" | "$0" check)"
        echo "$out"
        grep -q "RESOURCE_CONFLICT dup-build other build:shared" <<<"$out" || die "anti-vacuity 1 FAILED: dup build root not refused"
        echo "[ANTI-VACUITY] witnessed: RESOURCE_CONFLICT refusal"
        t1row="t1-offline|1|build:t1,load|env MIX_BUILD_ROOT=${pfx}t1 mix test"
        t3row="t3-sdk-smoke|3|port:9443|node verification/ts/run-all.mjs"
        echo "[ANTI-VACUITY] witness 2: t1-offline scheduled concurrent with t3-sdk-smoke"
        out="$(printf '%s\n%s\n' "$t1row" "$t3row" | "$0" check)"
        echo "$out"
        grep -q "CONFLICT LOAD_CONFLICT t1-offline t3-sdk-smoke" <<<"$out" || die "anti-vacuity 2 FAILED: load pair not refused"
        echo "[ANTI-VACUITY] witnessed: LOAD_CONFLICT refusal"
        echo "[ANTI-VACUITY] PASS: both injected schedules refused"
        ;;
    *)
        die "usage: overlap_court.sh {serial|overlap|check|compare|report|anti-vacuity}"
        ;;
esac
