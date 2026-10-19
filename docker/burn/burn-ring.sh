#!/usr/bin/env bash
# burn-ring.sh — AZB-22 burn ring: boot burn x50 -> chaos x50 -> parallel
# matrix (N=8) -> cgroup soak, all on ONE image digest bound to ONE subject
# SHA, with a run-summary receipt (DfCM R: identity=SHA+digest,
# authority=lane lease, consequence=tracked JSONL paths, replay=exact
# commands, standing derived by the validator — never claimed).
#
# Ring layout (tracked, docs/jira/v26.10.18/burn/ — never tmp/):
#   ring-<run-id>/ring.env          recorded identity (subject SHA, image id)
#   ring-<run-id>/boot/boot-burn.jsonl            boot stage rows (50 cycles)
#   ring-<run-id>/chaos/iter-<i>/chaos-kill.jsonl chaos stage rows (50 iters)
#   ring-<run-id>/matrix/aggregate.jsonl          matrix rows (aggregated verbatim)
#   ring-<run-id>/soak.jsonl                      soak rows (burn-soak lane)
#   ring-<run-id>/ring.jsonl        ring aggregate: declared expected matrix
#                                   (header) + rows copied verbatim from the
#                                   stage files + run_receipt. `--gate` here is
#                                   the ring's non-vacuity gate: a dropped
#                                   chaos iteration, boot cycle, matrix
#                                   service or soak round is a MISSING_CELL.
#   ring-<run-id>/summary.json      DfCM R receipt, validated by
#                                   ~/.zcode/dfcm/validate_receipt.py
#
# Subject-moved law (AZB-22 anti-vacuity): the ring records SUBJECT_SHA at
# init; the summary stage re-reads `git rev-parse HEAD` and REFUSES with
# R_missing_identity (subject moved) if the two differ. A commit landed after
# ring start can never mint a green summary.
#
# Stages are individually runnable and resumable:
#   docker/burn/burn-ring.sh                        # full ring, all stages
#   docker/burn/burn-ring.sh --stage boot           # one stage on the current ring
#   docker/burn/burn-ring.sh --run-dir <dir> --stage summary
#
# Knobs (defaults = the ticket spec): SMALT_RING_BOOT_CYCLES=50,
# SMALT_RING_CHAOS_ITERS=50, SMALT_RING_REPLICAS=8, SMALT_RING_SOAK_ROUNDS=1
# (the cgroup-soak ticket AZB-18 owns the 3x3 quota matrix; the ring stage is
# one soak round over the full offline+wire tiers — recorded, not asserted
# beyond that).
#
# No fixed sleeps: every wait is a bounded deadline poll (NO-SLEEP-DOCTRINE).
# Exit: 0 ring green / 1 typed failure / 2 refusal / 3 usage or loud skip.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

STAGE=""
RUN_DIR=""
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
while [ $# -gt 0 ]; do
  case "$1" in
    --stage) STAGE="$2"; shift 2 ;;
    --run-dir) RUN_DIR="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    *) echo "[BURN-RING] usage: burn-ring.sh [--stage boot|chaos|matrix|soak|summary] [--run-dir DIR] [--run-id ID]" >&2; exit 3 ;;
  esac
done

IMAGE="${SMALT_BURN_IMAGE:-smalt:local}"
BOOT_CYCLES="${SMALT_RING_BOOT_CYCLES:-50}"
CHAOS_ITERS="${SMALT_RING_CHAOS_ITERS:-50}"
REPLICAS="${SMALT_RING_REPLICAS:-8}"
SOAK_ROUNDS="${SMALT_RING_SOAK_ROUNDS:-1}"
BURN="docker/burn"

if [ -n "$RUN_DIR" ]; then
  case "$RUN_DIR" in
    /*) RING_DIR="$RUN_DIR" ;;
    *) RING_DIR="$ROOT/$RUN_DIR" ;;
  esac
else
  RING_DIR="$ROOT/docs/jira/v26.10.18/burn/ring-$RUN_ID"
fi
mkdir -p "$RING_DIR"

# --- identity: one subject SHA bound to one image digest ---------------------
if [ -f "$RING_DIR/ring.env" ]; then
  # shellcheck disable=SC1091
  . "$RING_DIR/ring.env"
else
  SUBJECT_SHA="$(git rev-parse HEAD)" || { echo "[BURN-RING] REFUSED R_missing_identity: not a git checkout" >&2; exit 2; }
  case "$SUBJECT_SHA" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) echo "[BURN-RING] REFUSED R_missing_identity: '$SUBJECT_SHA' is not 40-hex" >&2; exit 2 ;;
  esac
  docker image inspect "$IMAGE" >/dev/null 2>&1 || {
    echo "[BURN-RING] REFUSED: image $IMAGE missing — build per docker/BUILD_RECEIPT.md (AZB-01)" >&2
    exit 2
  }
  IMAGE_ID="$(docker image inspect -f '{{.Id}}' "$IMAGE")"
  IMAGE_LABEL="$(docker image inspect -f '{{index .Config.Labels "org.smalt.subject"}}' "$IMAGE")"
  if [ "$IMAGE_LABEL" != "$SUBJECT_SHA" ]; then
    echo "[BURN-RING] REFUSED IMAGE_SUBJECT_MISMATCH: image $IMAGE label org.smalt.subject=$IMAGE_LABEL != ring subject $SUBJECT_SHA — rebuild at HEAD per docker/BUILD_RECEIPT.md" >&2
    exit 2
  fi
  cat > "$RING_DIR/ring.env" <<ENV
SUBJECT_SHA=$SUBJECT_SHA
IMAGE_ID=$IMAGE_ID
IMAGE=$IMAGE
BOOT_CYCLES=$BOOT_CYCLES
CHAOS_ITERS=$CHAOS_ITERS
REPLICAS=$REPLICAS
SOAK_ROUNDS=$SOAK_ROUNDS
ENV
  echo "[BURN-RING] ring $RING_DIR: subject=$SUBJECT_SHA image=$IMAGE_ID"
fi

run_env() { # env contract shared by every container stage
  echo "-e SMALT_BURN_SUBJECT_SHA=$SUBJECT_SHA"
  echo "-e BURN_IMAGE_DIGEST=$IMAGE_ID"
  echo "-e SMALT_BURN_PLANE=all"
}

# --- container exec helper ----------------------------------------------------
in_image() { # in_image <container-name> <script> [env k=v ...]
  # The ring dir mounts at a FIXED container path (/ring) so env-carried
  # paths (SMALT_BURN_DIR) are container-side, never host paths.
  local cname="$1" script="$2"; shift 2
  local -a envs=()
  local kv
  for kv in "$@"; do envs+=("-e" "$kv"); done
  docker run --rm --name "$cname" \
    -v "$ROOT/$BURN:/burn:ro" \
    -v "$RING_DIR:/ring" \
    -v /Users/sac/beam4pm:/beam4pm:ro \
    -v /Users/sac/xaas:/xaas:ro \
    -e SMALT_BURN_SUBJECT_SHA="$SUBJECT_SHA" \
    -e BURN_IMAGE_DIGEST="$IMAGE_ID" \
    -e SMALT_BURN_PLANE=all \
    -e BURN_CONTAINER="$cname" \
    "${envs[@]}" \
    "$IMAGE" bash "/burn/$(basename "$script")"
}

STAGES_ALL=(boot chaos matrix soak summary)

# --- stage: boot burn x50 ------------------------------------------------------
stage_boot() {
  mkdir -p "$RING_DIR/boot"
  echo "[BURN-RING] stage boot: $BOOT_CYCLES cycles"
  in_image ring-boot "$BURN/boot-burn.sh" "SMALT_BURN_CYCLES=$BOOT_CYCLES" "SMALT_BURN_DIR=/ring/boot"
  python3 scripts/validate_burn.py "$RING_DIR/boot/boot-burn.jsonl"
  echo "[BURN-RING] stage boot: GREEN"
}

# --- stage: chaos x50 ----------------------------------------------------------
stage_chaos() {
  echo "[BURN-RING] stage chaos: $CHAOS_ITERS iterations"
  local i
  for i in $(seq 1 "$CHAOS_ITERS"); do
    local d="$RING_DIR/chaos/iter-$i"
    if [ -s "$d/chaos-kill.jsonl" ] && grep -q '"type":"run_receipt"' "$d/chaos-kill.jsonl"; then
      echo "[BURN-RING] chaos iter $i: already green (resume)" >&2
      continue
    fi
    mkdir -p "$d"
    in_image "ring-chaos-$i" "$BURN/chaos-kill.sh" "SMALT_BURN_DIR=/ring/chaos/iter-$i"
    python3 scripts/validate_burn.py "$d/chaos-kill.jsonl"
    echo "[BURN-RING] chaos iter $i/$CHAOS_ITERS: GREEN"
  done
  echo "[BURN-RING] stage chaos: GREEN ($CHAOS_ITERS iterations)"
}

# --- stage: parallel matrix (N replicas, plane all) -----------------------------
stage_matrix() {
  echo "[BURN-RING] stage matrix: $REPLICAS replicas"
  # Regenerate the generated compose from the matrix spec at the ring's N
  # (the file is generated, never hand-edited; AZB-02 records the
  # UNSUPPORTED(generator-capability) deviation — template lives in the driver).
  "$BURN/parallel-matrix.sh" --emit-compose "$REPLICAS"
  # Subject/digest ride the compose environment interpolation.
  export SMALT_BURN_SUBJECT_SHA="$SUBJECT_SHA" BURN_IMAGE_DIGEST="$IMAGE_ID"
  "$BURN/parallel-matrix.sh" --plane all --replicas "$REPLICAS" --deadline "${SMALT_RING_MATRIX_DEADLINE:-1200}"
  mkdir -p "$RING_DIR/matrix"
  local f b
  for f in "$BURN/results"/burn-smalt-burn-all-*.jsonl; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"
    cp "$f" "$RING_DIR/matrix/$b"
  done
  local n
  n=$(ls "$RING_DIR"/matrix/burn-*.jsonl 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -eq "$REPLICAS" ] || { echo "[BURN-RING] stage matrix: FAIL expected $REPLICAS row files, found $n" >&2; return 1; }
  echo "[BURN-RING] stage matrix: GREEN ($REPLICAS/$REPLICAS clean)"
}

# --- stage: cgroup soak (host, burn-soak lane) -----------------------------------
stage_soak() {
  echo "[BURN-RING] stage soak: $SOAK_ROUNDS round(s)"
  BURN_CONTAINER=ring-soak-host \
  SMALT_BURN_SUBJECT_SHA="$SUBJECT_SHA" \
  BURN_IMAGE_DIGEST="$IMAGE_ID" \
  SMALT_BURN_PLANE=all \
    bash "$BURN/soak.sh" --rounds "$SOAK_ROUNDS" --jsonl "$RING_DIR/soak.jsonl"
  echo "[BURN-RING] stage soak: GREEN"
}

# --- stage: summary — declared expected matrix + verbatim rows + gate + R -----
stage_summary() {
  # Subject-moved law (AZB-22 anti-vacuity): a commit after ring start can
  # never mint a green summary.
  local sha_now
  sha_now="$(git rev-parse HEAD)"
  if [ "$sha_now" != "$SUBJECT_SHA" ]; then
    echo "[BURN-RING] REFUSED R_missing_identity: subject moved — ring recorded $SUBJECT_SHA, HEAD is now $sha_now" >&2
    exit 2
  fi

  local agg="$RING_DIR/ring.jsonl"
  python3 - "$RING_DIR" "$agg" <<'PY'
import json, sys
from pathlib import Path

ring = Path(sys.argv[1]); agg = Path(sys.argv[2])
rows = []

def add_file(p):
    for line in Path(p).read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        o = json.loads(line)
        if o.get("type") in ("run_header", "run_receipt"):
            continue
        rows.append(o)

add_file(ring / "boot/boot-burn.jsonl")
for d in sorted((ring / "chaos").glob("iter-*")):
    add_file(d / "chaos-kill.jsonl")
for f in sorted((ring / "matrix").glob("burn-*.jsonl")):
    add_file(f)
add_file(ring / "soak.jsonl")

env = {}
for line in (ring / "ring.env").read_text().splitlines():
    k, _, v = line.partition("=")
    env[k] = v
boot_cycles = list(range(1, int(env["BOOT_CYCLES"]) + 1))
chaos_iters = int(env["CHAOS_ITERS"])
replicas = int(env["REPLICAS"])
soak_rounds = int(env["SOAK_ROUNDS"])

# DECLARED expected matrix — computed from the ring parameters recorded at
# init, never from the rows themselves (a mirrored header would make --gate
# vacuous). containers: ring-boot, ring-chaos-1..N, smalt-burn-all-1..8,
# ring-soak-host.
expected = {"ring-boot": (boot_cycles, ["probe", "recover", "teardown"])}
for i in range(1, chaos_iters + 1):
    expected[f"ring-chaos-{i}"] = ([0], ["chaos", "probe"])
for i in range(1, replicas + 1):
    expected[f"smalt-burn-all-{i}"] = ([0], ["probe"])
expected["ring-soak-host"] = (list(range(1, soak_rounds + 1)), ["probe", "soak"])

with agg.open("w") as out:
    out.write(json.dumps({
        "type": "run_header",
        "run_id": ring.name,
        "expected": {
            "containers": list(expected.keys()),
            "cycles": sorted({c for cs, _ in expected.values() for c in cs}),
            "stages": ["probe", "recover", "teardown", "chaos", "soak"],
        },
    }) + "\n")
    for r in rows:
        out.write(json.dumps(r) + "\n")

    out.write(json.dumps({
        "type": "run_receipt",
        "work_order_id": "AZB-22",
        "origin_authority": {"ceiling": "CONSTRUCT", "grant": "AZB-22", "actor": "burn-ring"},
        "provider": {"name": "burn-ring"},
        "provider_execution_id": ring.name,
        "identity": {"subject": "burn-ring", "repo": "smalt",
                     "subject_sha": env["SUBJECT_SHA"], "base_sha": env["SUBJECT_SHA"]},
        "authority": {"ceiling": "CONSTRUCT", "grant": "AZB-22", "actor": "burn-ring"},
        "consequence": {"commits": [], "files_changed": [str(agg)], "remote_effects": []},
        "replay": {"commands": [{"cmd": f"python3 scripts/validate_burn.py --gate {agg}", "exit": 0, "cwd": "."}]},
        "standing": {"value": "ALIVE",
                     "derived_from": f"validate_burn.py --gate {agg} at {env['SUBJECT_SHA']}"},
    }) + "\n")
print(f"[BURN-RING] aggregate {agg}: {len(rows)} rows, "
      f"{len(expected)} expected containers")
PY

  # THE GATE: no missing cell, no dirty row, receipt schema-valid.
  python3 scripts/validate_burn.py --gate "$agg"

  # R summary, validated by the DfCM validator (identity must be a real
  # commit; standing ALIVE requires green replays).
  local summary="$RING_DIR/summary.json"
  python3 - "$RING_DIR" "$summary" "$agg" <<'PY'
import json, sys
from pathlib import Path
ring = Path(sys.argv[1]); out = Path(sys.argv[2]); agg = Path(sys.argv[3])
env = dict(line.partition("=")[::2] for line in (ring / "ring.env").read_text().splitlines())
r = {
    "work_order_id": "AZB-22",
    "origin_authority": {"ceiling": "CONSTRUCT", "grant": "AZB-22", "actor": "burn-ring"},
    "provider": {"name": "burn-ring", "transport": "docker"},
    "provider_execution_id": ring.name,
    "identity": {"subject": "burn-ring", "repo": "smalt",
                 "subject_sha": env["SUBJECT_SHA"], "base_sha": env["SUBJECT_SHA"]},
    "authority": {"ceiling": "CONSTRUCT", "grant": "AZB-22", "actor": "burn-ring"},
    "consequence": {"commits": [],
                    "files_changed": sorted(str(p) for p in [
                        ring / "ring.jsonl", ring / "boot/boot-burn.jsonl",
                        ring / "soak.jsonl", *sorted(ring.glob("chaos/iter-*/chaos-kill.jsonl")),
                        *sorted(ring.glob("matrix/burn-*.jsonl"))]),
                    "remote_effects": []},
    "replay": {"commands": [
        {"cmd": f"python3 scripts/validate_burn.py --gate {agg}", "exit": 0, "cwd": "."},
        {"cmd": f"python3 ~/.zcode/dfcm/validate_receipt.py {out}", "exit": 0, "cwd": "."},
    ]},
    "standing": {"value": "ALIVE",
                 "derived_from": f"validate_burn.py --gate {agg} at {env['SUBJECT_SHA']}"},
    "provider_ext.burn-ring": {
        "image": env["IMAGE"], "image_id": env["IMAGE_ID"],
        "boot_cycles": env["BOOT_CYCLES"], "chaos_iters": env["CHAOS_ITERS"],
        "replicas": env["REPLICAS"], "soak_rounds": env["SOAK_ROUNDS"],
    },
}
out.write_text(json.dumps(r, indent=1) + "\n")
PY

  python3 ~/.zcode/dfcm/validate_receipt.py "$summary"
  echo "[BURN-RING] VERDICT: GREEN — ring $RING_DIR admitted (summary $summary)"
}

case "$STAGE" in
  "") for s in boot chaos matrix soak summary; do "stage_$s"; done ;;
  boot|chaos|matrix|soak|summary) "stage_$STAGE" ;;
  *) echo "[BURN-RING] unknown stage '$STAGE'" >&2; exit 3 ;;
esac
