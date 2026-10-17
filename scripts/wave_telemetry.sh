#!/usr/bin/env bash
# scripts/wave_telemetry.sh — wave-level wall-clock telemetry (lane S-8, v26.10.15 idea).
#
# The next baseline reads a file, not archaeology: lanes record their own
# queue/compile/substrate/test wall-clock waits as JSONL rows in the same
# bench results directory shape as scripts/bench/lib.sh rows.
#
# Usage:
#   scripts/wave_telemetry.sh emit [--phase dispatch|complete] [--out <path>]
#       phase defaults to "complete" (v1 rows had no phase; they are complete
#       rows). Dispatch rows record queue entry; complete rows record exit.
#       Default out path: $WAVE_TELEMETRY_OUT, else the newest
#       docs/jira/v*/ window's bench/wave-telemetry.jsonl (--out overrides).
#       Reads env vars set by the lane at exit:
#         LANE_ID         (required, non-empty)
#         QUEUE_WAIT_S    (seconds, number)
#         COMPILE_WAIT_S  (seconds, number)
#         SUBSTRATE_WAIT_S(seconds, number)
#         TEST_WALL_S     (seconds, number)
#         RESULT          (pass|fail)
#       Extra env vars (wave-telemetry schema):
#         WAVE_ID   (wave label, default "w1")
#         TYPE      (row type, default "verify")
#         VERDICT   (PASS|FAIL|...; defaults from RESULT: pass->PASS fail->FAIL)
#         DEFECTS   (integer defect count, default 0)
#         DEFECT_REFS (optional; comma-separated KD refs "KD-99:scripts/x.sh:1"
#                     — parsed into kd_ids:[...] and refs:[...] arrays)
#       Appends one row:
#         phase=dispatch: {wave, lane, phase, dispatched_at}
#         phase=complete: {wave, lane, phase, completed_at,
#          type, verdict, defects, kd_ids, refs,
#          queue_wait_s, compile_wait_s, substrate_wait_s, test_wall_s,
#          result, total_s}
#       Malformed env (non-numeric waits, bad RESULT): visible-over-silent —
#       writes a minimal {wave, lane, verdict:"MISSING", reason, ts} row to
#       the out path, warns on stderr, exits 0 (a lane must not fail because
#       telemetry failed). Missing LANE_ID: stderr warn only (no row possible).
#
#   scripts/wave_telemetry.sh report [--out-file <path>] [--machine]
#       Human table by default; --machine prints exactly one line:
#         VERDICT CLEAN            — every dispatched lane has a complete row
#                                    with verdict PASS, defects=0, numeric
#                                    waits, and there are no MISSING rows
#         VERDICT DIRTY <reasons>  — anything else
#
#   scripts/wave_telemetry.sh wrap -- <command...>
#       Records wall time around any command and emits with TEST_WALL_S.
#       Propagates the command's exit status as RESULT.
#
# Schema (keys validated on emit; rows live next to bench rows in the
# newest active docs/jira/v*/ window):
#
# Spec: docs/jira/v26.10.15/WAVE_TELEMETRY.md

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Default out: WAVE_TELEMETRY_OUT env wins, else newest docs/jira/v*/ dir
# (sorts lexicographically; zero-padded versions sort correctly), so rows land
# in the active milestone window instead of a stale hardcoded one.
default_out() {
  if [ -n "${WAVE_TELEMETRY_OUT:-}" ]; then
    printf '%s' "$WAVE_TELEMETRY_OUT"; return
  fi
  local newest
  newest=$(ls -d "$REPO"/docs/jira/v*/ 2>/dev/null | sort -V | tail -1)
  if [ -n "$newest" ]; then
    printf '%s' "${newest%/}/bench/wave-telemetry.jsonl"
  else
    printf '%s' "$REPO/docs/jira/v26.10.14/bench/wave-telemetry.jsonl"
  fi
}

die_loud() { # skip-loud: warn, never break the lane
  echo "wave_telemetry[emit]: $1" >&2
}

# Visible-over-silent: a malformed lane env must not vanish. Emit a minimal
# MISSING row to the active out path (exit still 0 — telemetry never breaks
# a lane). If we can't even build the row (no LANE_ID), the stderr warning
# is all we have.
emit_missing_row() {
  local out="$1" reason="$2" lane="${LANE_ID:-}"
  if [ -z "$lane" ]; then
    die_loud "$reason (no LANE_ID — cannot write MISSING row)"
    return 0
  fi
  mkdir -p "$(dirname "$out")"
  # Tamper-evidence (R163b E4): MISSING rows carry a
  # dedicated "missing": true key so the report predicate can detect them
  # independently of the verdict string (a tampered verdict no longer hides).
  printf '{"wave":"%s","lane":"%s","missing":true,"verdict":"MISSING","reason":"%s","ts":"%s"}\n' \
    "${WAVE_ID:-w1}" "$lane" "$reason" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$out"
  die_loud "$reason — wrote MISSING row to $out"
}

is_num() {
  case "$1" in
    ''|*[!0-9.+-]*) return 1 ;;
    *) return 0 ;;
  esac
}

is_int() {
  case "$1" in
    ''|*[!0-9-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# DEFECT_REFS="KD-99:scripts/x.sh:1,KD-7:docs/y.md:12" ->
#   kd_ids=["KD-99","KD-7"], refs=["scripts/x.sh:1","docs/y.md:12"]
# Format is colon-split with the kd id first; entries without a kd id are
# kept in refs only. Skips empty entries (trailing commas etc).
ref_arrays() {
  python3 - "$1" <<'PY'
import json, sys
kd, refs = [], []
for e in (sys.argv[1] or "").split(","):
    e = e.strip()
    if not e:
        continue
    parts = e.split(":")
    if parts[0].startswith("KD-"):
        kd.append(parts[0])
        rest = parts[1:]
    else:
        rest = parts
    if rest:
        refs.append(":".join(rest))
print(json.dumps({"kd_ids": kd, "refs": refs}))
PY
}

ts_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

emit_row() { # $1=out $2=phase(dispatch|complete)
  local out="$1" phase="$2"
  local lane="${LANE_ID:-}"
  [ -n "$lane" ] || { die_loud "LANE_ID missing/empty — skipping emit"; return 0; }

  # Type-aware: wave is ALWAYS a JSON string, even when the lane passes an
  # integer wave id ("fix int drift" — v1 rows let numeric waves emit as
  # unquoted ints, breaking group-by). json_escape guarantees quoting.
  local wave
  wave=$(json_escape "${WAVE_ID:-w1}")

  mkdir -p "$(dirname "$out")"
  if [ "$phase" = dispatch ]; then
    printf '{"wave":%s,"lane":"%s","phase":"dispatch","dispatched_at":"%s"}\n' \
      "$wave" "$lane" "$(ts_utc)" >>"$out"
    return 0
  fi

  local q="${QUEUE_WAIT_S:-0}" c="${COMPILE_WAIT_S:-0}" s="${SUBSTRATE_WAIT_S:-0}" t="${TEST_WALL_S:-0}"
  for v in "$q" "$c" "$s" "$t"; do
    is_num "$v" || { emit_missing_row "$out" "non-numeric wait value '$v'"; return 0; }
  done

  local result="${RESULT:-}"
  case "$result" in
    pass|fail) : ;;
    *) emit_missing_row "$out" "RESULT must be pass|fail, got '${result:-<unset>}'"; return 0 ;;
  esac

  local total
  total=$(python3 -c "print(f'{$q + $c + $s + $t:.3f}')")

  local type="${TYPE:-verify}" defects="${DEFECTS:-0}"
  local verdict="${VERDICT:-}"
  case "$verdict" in
    '') [ "$result" = pass ] && verdict=PASS || verdict=FAIL ;;
  esac
  # R163b emit_row coherence: VERDICT=PASS RESULT=fail (or the inverse) must
  # not both persist — refuse the combination loudly via a MISSING row.
  case "$verdict" in
    PASS) [ "$result" = pass ] || { emit_missing_row "$out" "VERDICT=PASS but RESULT=$result — refusing incoherent row"; return 0; } ;;
    FAIL) [ "$result" = fail ] || { emit_missing_row "$out" "VERDICT=FAIL but RESULT=$result — refusing incoherent row"; return 0; } ;;
  esac
  is_int "$defects" || { emit_missing_row "$out" "non-integer DEFECTS '$defects'"; return 0; }

  local arrs
  arrs=$(ref_arrays "${DEFECT_REFS:-}")
  local kd_ids refs
  kd_ids=$(printf '%s' "$arrs" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["kd_ids"]))')
  refs=$(printf '%s' "$arrs" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["refs"]))')

  printf '{"wave":%s,"lane":"%s","phase":"complete","completed_at":"%s","type":"%s","verdict":"%s","defects":%s,"kd_ids":%s,"refs":%s,"queue_wait_s":%s,"compile_wait_s":%s,"substrate_wait_s":%s,"test_wall_s":%s,"result":"%s","total_s":%s}\n' \
    "$wave" "$lane" "$(ts_utc)" "$type" "$verdict" "$defects" "$kd_ids" "$refs" "$q" "$c" "$s" "$t" "$result" "$total" \
    >>"$out"
}

cmd_emit() {
  local out phase=complete
  out="$(default_out)"
  while [ $# -gt 0 ]; do
    case "$1" in
      --phase) phase="$2"; shift 2 ;;
      --out) out="$2"; shift 2 ;;
      *) die_loud "unknown emit arg '$1'"; shift ;;
  esac
  done
  case "$phase" in
    dispatch|complete) emit_row "$out" "$phase" ;;
    *) die_loud "--phase must be dispatch|complete, got '$phase'"; return 0 ;;
  esac
}

cmd_wrap() {
  local out=""
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    case "$1" in
      --out) out="$2"; shift 2 ;;
      *) echo "usage: wave_telemetry.sh wrap [--out <path>] -- <command...>" >&2; return 2 ;;
    esac
  done
  [ "${1:-}" = "--" ] && shift
  [ -n "$out" ] && out="--out $out" || out=""
  [ $# -gt 0 ] || { echo "wrap: no command given after --" >&2; return 2; }
  local t0 t1 rc=0
  t0=$(python3 -c 'import time; print(time.time())')
  "$@" || rc=$?
  t1=$(python3 -c 'import time; print(time.time())')
  TEST_WALL_S=$(python3 -c "print(f'{$t1 - $t0:.3f}')") \
  RESULT=$([ $rc -eq 0 ] && echo pass || echo fail) \
    "$0" emit $out
  return $rc
}

cmd_report() {
  local out machine=0
  out="$(default_out)"
  while [ $# -gt 0 ]; do
    case "$1" in
      --out-file) out="$2"; shift 2 ;;
      --machine) machine=1; shift ;;
      *) echo "usage: wave_telemetry.sh report [--out-file <path>] [--machine]" >&2; return 2 ;;
    esac
  done
  python3 - "$out" "$machine" <<'PY'
import json, sys, os
path, machine = sys.argv[1], sys.argv[2] == "1"
rows = []
if os.path.exists(path):
    with open(path) as f:
        for i, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                print(f"wave-report[WARN] malformed line {i} skipped", file=sys.stderr)

# D67 CLEAN/DIRTY predicate (R163b hardening). CLEAN iff:
#   - at least one dispatch row and at least one complete row
#   - no duplicate (lane, wave) dispatch rows and no duplicate (lane, wave)
#     complete rows (E2)
#   - every dispatch row's wave matches its lane's complete row's wave,
#     compared in normalized form str(w).lstrip("0") so "01" and "1" pair
#     but genuinely different waves do not (E3)
#   - every complete row (phase == "complete" REQUIRED — phase-less legacy
#     rows are not complete rows, E4): verdict PASS AND result "pass"
#     (both fields must agree, E1), defects == 0, all four waits numeric,
#     wave is a string, and (if present) kd_ids/refs are lists
#   - no MISSING rows, detected via the dedicated missing:true key
#     independently of the verdict string (E4)
def dirty_reasons(rows):
    if not rows:
        return ["no telemetry rows"]
    d = []
    dispatch = [r for r in rows if r.get("phase") == "dispatch"]
    complete = [r for r in rows if r.get("phase") == "complete"]
    if any(r.get("missing") is True or r.get("verdict") == "MISSING" for r in rows):
        d.append("MISSING rows present")
    if not dispatch:
        d.append("no dispatch rows")
    if not complete:
        d.append("no complete rows")
    # E2: duplicate rows per (lane, wave) per phase are DIRTY.
    from collections import Counter
    counts = Counter((r.get("lane"), r.get("phase")) for r in rows
                     if r.get("phase") in ("dispatch", "complete"))
    for (lane, phase), n in sorted(counts.items(), key=lambda kv: (str(kv[0][0]), kv[0][1])):
        if n > 1:
            d.append(f"lane {lane}: {n} duplicate {phase} rows")
    dl = {r.get("lane") for r in dispatch}
    cl = {r.get("lane") for r in complete}
    for lane in sorted(dl - cl):
        d.append(f"lane {lane}: dispatched but never completed")
    for lane in sorted(cl - dl):
        d.append(f"lane {lane}: completed but never dispatched")
    # (R177f 2a) non-string dispatch-row wave: v1 legacy emits let numeric
    # waves through unquoted. A non-string dispatch wave must be DIRTY —
    # mirror of the complete-row "wave not a string" check — otherwise the
    # wave-pairing comparison below silently skips it.
    for r in dispatch:
        lane = r.get("lane", "?")
        if not isinstance(r.get("wave"), str):
            d.append(f"lane {lane}: dispatch wave {r.get('wave')!r} not a string")
    # E3 (R177f 2b): paired dispatch/complete waves must agree EXACTLY after
    # stripping a single leading "w" ("WAVE-1" style labels). The previous
    # str(w).lstrip("0") normalization collapsed distinct labels ("000" and
    # "0" and "00" all -> "") so different waves paired equal. Rule: norm(w) =
    # w[1:] if w.startswith("w") else w; pairing requires norm equal AND the
    # raw strings equal. "01" vs "1" no longer pairs by design — emit has
    # always written string waves (default "w1"); zero-padded distinct labels
    # are distinct waves.
    def norm_wave(w):
        return w[1:] if w.startswith("w") else w
    dispatch_wave = {}
    for r in dispatch:
        w = r.get("wave")
        if isinstance(w, str):
            dispatch_wave[r.get("lane")] = w
    for r in complete:
        lane = r.get("lane")
        w = r.get("wave")
        if lane in dispatch_wave and isinstance(w, str):
            dw = dispatch_wave[lane]
            if norm_wave(dw) != norm_wave(w) or dw != w:
                d.append(f"lane {lane}: dispatch wave {dw!r} != complete wave {w!r}")
    for r in complete:
        lane = r.get("lane", "?")
        # E1: verdict and result must both be present and agree.
        if r.get("verdict") != "PASS" or r.get("result") != "pass":
            d.append(f"lane {lane}: verdict {r.get('verdict')!r}/result {r.get('result')!r} != PASS/pass")
        if r.get("defects") != 0:
            d.append(f"lane {lane}: defects {r.get('defects')!r} != 0")
        for k in ("queue_wait_s", "compile_wait_s", "substrate_wait_s", "test_wall_s"):
            v = r.get(k)
            if not isinstance(v, (int, float)) or isinstance(v, bool):
                d.append(f"lane {lane}: {k}={v!r} not numeric")
        if not isinstance(r.get("wave"), str):
            d.append(f"lane {lane}: wave not a string")
        for k in ("kd_ids", "refs"):
            if k in r and not isinstance(r[k], list):
                d.append(f"lane {lane}: {k} not a list")
    return d

reasons = dirty_reasons(rows)
if machine:
    if reasons:
        print("VERDICT DIRTY " + "; ".join(reasons))
    else:
        print("VERDICT CLEAN")
    sys.exit(0)

if not rows:
    print(f"wave-report: no telemetry at {path} — empty state, nothing recorded yet.")
    sys.exit(0)
print(f"Wave telemetry — {len(rows)} lane row(s) from {path}\n")
hdr = f"{'lane':<16}{'phase':<10}{'queue_s':>9}{'compile_s':>11}{'substr_s':>10}{'test_s':>9}{'total_s':>9}  verdict"
print(hdr); print("-" * len(hdr))
waits = ("queue_wait_s","compile_wait_s","substrate_wait_s","test_wall_s","total_s")
tot = dict.fromkeys(waits, 0.0)
npass = nfail = 0
for r in sorted(rows, key=lambda r: (r.get("lane",""), r.get("phase",""))):
    phase = r.get("phase") if r.get("phase") in ("dispatch", "complete") else "?"
    vals = {}
    for k in waits:
        v = r.get(k, 0)
        try:
            v = float(v)
        except (TypeError, ValueError):
            v = 0.0
        vals[k] = v
        if phase == "complete":
            tot[k] += v
    if phase == "complete":
        npass += r.get("verdict") == "PASS"; nfail += r.get("verdict") != "PASS"
    print(f"{r.get('lane','?'):<16}{phase:<10}"
          f"{vals['queue_wait_s']:>9.3f}{vals['compile_wait_s']:>11.3f}"
          f"{vals['substrate_wait_s']:>10.3f}{vals['test_wall_s']:>9.3f}"
          f"{vals['total_s']:>9.3f}  {r.get('verdict', r.get('result','?'))}")
print("-" * len(hdr))
print(f"{'TOTAL (complete)':<26}{tot['queue_wait_s']:>9.3f}{tot['compile_wait_s']:>11.3f}"
      f"{tot['substrate_wait_s']:>10.3f}{tot['test_wall_s']:>9.3f}{tot['total_s']:>9.3f}"
      f"  PASS={npass} FAIL/other={nfail}")
if reasons:
    print("\nDIRTY: " + "; ".join(reasons))
else:
    print("\nCLEAN")
PY
}

case "${1:-}" in
  emit) shift; cmd_emit "$@" ;;
  wrap) shift; cmd_wrap "$@" ;;
  report) shift; cmd_report "$@" ;;
  *)
    echo "usage: wave_telemetry.sh emit [--phase dispatch|complete] [--out <path>] | report [--out-file <path>] [--machine] | wrap -- <command...>" >&2
    exit 2
    ;;
esac
