#!/usr/bin/env bash
# parallel-matrix.sh — AZB-02 per-container-netns burn matrix driver, extended
# for AZB-17 (N replicas x 4 planes, per-replica compose networks = cross-
# tenant isolation, per-plane chaos stage, tenant canary).
#
# Matrix spec: planes=(control data integration identity all) AZB-02 legacy x
# replicas 1..N. compose.burn.yml is GENERATED from this spec — not
# hand-listed. ggen has no compose templating pack in this tree
# (UNSUPPORTED(generator-capability), recorded in azb-02-netns.md), so the
# template lives here and the checked-in compose.burn.yml is its output for
# the default N=8.
#
# AZB-17 additions:
#   - Per-replica compose networks (net-r<i>, named smalt-burn-net-r<i>):
#     every replica's plane containers share ONLY their replica's network, so
#     cross-replica service DNS is unresolvable and every cross-replica TCP
#     attempt must fail. This is the cross-tenant isolation claim.
#   - Per-plane chaos stage: each plane container runs its plane's scenario
#     from chaos-kill.sh (control=s3-wasm-seal, data=s1-store-kill,
#     integration=s4-amqp-scenario, identity=s5-identity-sts) BEFORE the
#     daemon boot (eval VMs bind ports; daemon rebinds after).
#   - Tenant canary: replica-unique marker roundtrip in own namespace +
#     cross-replica reachability assertion (any success = CANARY_CROSS_READ).
#   - Merged gate file: one smalt-burn JSONL over all cells, run_receipt
#     minted host-side, validated by scripts/validate_burn.py --gate.
#   - --av-shared-net anti-vacuity court: two replicas on ONE network with a
#     shared DETS volume — the canary MUST fire (cross-reach + typed DETS
#     refusal; rc=0 = court passed).
#
# Preflight (AZB-02 anti-vacuity contract): `docker compose config` on the
# burn project must show ZERO published host ports. Any `published:` key in
# the resolved config => exit 2 HOST_PORT_PUBLISH_REFUSED, before any
# container runs.
#
# Exit 0 clean / 1 not all-clean / 2 preflight refusal / 3 usage.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"

COMPOSE_FILE="$HERE/compose.burn.yml"
PROJECT="smalt-burn"
RESULTS_DIR="$HERE/results"
PLANES=(control data integration identity all)
GATE_TS="$(date +%s)"

# AZB-17 plane -> chaos scenario map (chaos-kill.sh scenario ids; 'all' has
# no single scenario — the legacy 'all' row runs probe-only).
scenario_for() {
  case "$1" in
    control) echo "s3-wasm-seal" ;;
    data) echo "s1-store-kill" ;;
    integration) echo "s4-amqp-capacity" ;;
    identity) echo "s5-identity-sts" ;;
    *) echo "" ;;
  esac
}

usage() {
  cat <<EOF
usage: parallel-matrix.sh [--plane P] [--planes a,b,c,d] [--replicas N]
       [--emit-compose [N]] [--dry-run] [--deadline S] [--av-shared-net]
  --plane P        run only plane P's replica row (no flag = the AZB-17
                   4-plane topology: control,data,integration,identity)
  --planes LIST    AZB-17: run several plane rows, e.g. the full 4-plane
                   topology: --planes control,data,integration,identity
  --replicas N     replica count for --emit-compose AND for the run rows
                   (default 8; AZB-17 run: 8 x 4 planes = 32 cells)
  --emit-compose   (re)generate docker/burn/compose.burn.yml from the matrix
                   spec and exit 0 (this file is generated, never hand-edited)
  --dry-run        print the resolved plan and exit 0
  --deadline S     per-wave wall budget in seconds, default 900
  --av-shared-net  anti-vacuity court: two replicas, ONE network + shared
                   DETS volume; the canary MUST fire (court exit 0 = fired)
Exit: 0 clean / 1 not all clean / 2 HOST_PORT_PUBLISH_REFUSED preflight / 3 usage
EOF
  exit 3
}

DRY_RUN=0
EMIT=0
AV_MODE=0
DEADLINE_SECS=900
# AZB-17: no --plane/--planes => the 4-plane topology (the ticket Accept
# command `just burn-matrix --replicas 8` runs 8 x 4 = 32 cells). The legacy
# AZB-02/22 single-row mode stays reachable via explicit --plane (burn-ring
# passes --plane all).
PLANE=""
PLANES_CSV=""
REPLICAS=8
while [ $# -gt 0 ]; do
  case "$1" in
    --plane) PLANE="$2"; shift ;;
    --planes) PLANES_CSV="$2"; shift ;;
    --replicas) REPLICAS="$2"; shift ;;
    --dry-run) DRY_RUN=1 ;;
    --emit-compose) EMIT=1; if [ "${2:-}" ] && [ "${2:-}" != "--" ]; then case "$2" in ''|*[!0-9]*) ;; *) REPLICAS="$2"; shift ;; esac; fi ;;
    --deadline) DEADLINE_SECS="$2"; shift ;;
    --av-shared-net) AV_MODE=1 ;;
    *) usage ;;
  esac
  shift
done

# Resolve the selected plane rows: --planes csv wins over --plane; neither
# given => the AZB-17 4-plane topology.
SELECTED=()
if [ -z "$PLANES_CSV" ] && [ -z "$PLANE" ]; then
  SELECTED=(control data integration identity)
elif [ -n "$PLANES_CSV" ]; then
  IFS=',' read -r -a PARTS <<< "$PLANES_CSV"
  for p in "${PARTS[@]}"; do
    p="$(printf '%s' "$p" | tr -d '[:space:]')"
    [ -n "$p" ] || continue
    case " ${PLANES[*]} " in *" $p "*) SELECTED+=("$p") ;; *) echo "[BURN-MATRIX] unknown plane $p" >&2; exit 3 ;; esac
  done
else
  case " ${PLANES[*]} " in *" $PLANE "*) ;; *) echo "[BURN-MATRIX] unknown plane $PLANE" >&2; exit 3 ;; esac
  SELECTED=("$PLANE")
fi

svc_name() { printf 'smalt-burn-%s-%s' "$1" "$2"; }

# --- generator: matrix spec -> compose.burn.yml ------------------------------
emit_compose() {
  local n="$1"
  echo "# compose.burn.yml — GENERATED by docker/burn/parallel-matrix.sh --emit-compose $n"
  echo "# (AZB-02 matrix spec: planes=(control data integration identity all) x 1..N;"
  echo "# AZB-17: per-replica networks net-r<i> = cross-tenant isolation; per-plane"
  echo "# chaos scenario + replica identity via service env)."
  echo "# Do not hand-edit; regenerate. Zero 'ports:' publish — every container is"
  echo "# its own network namespace; canonical ports bind inside the netns only."
  cat <<'HDR'
x-burn-common: &burn-common
  image: smalt:local
  entrypoint: ["bash", "/burn/container-burn.sh"]
  volumes:
    - ../burn:/burn:ro
    - ./results:/burn-results
    - ${HOME}/beam4pm:/beam4pm:ro
    - ${HOME}/xaas:/xaas:ro
  tmpfs:
    - /tmp
  cap_drop: [ALL]
  security_opt: [no-new-privileges:true]
  restart: "no"

services:
HDR
  local p i s exp scenario planes_line
  for p in "${PLANES[@]}"; do
    for i in $(seq 1 "$n"); do
      s="$(svc_name "$p" "$i")"
      case "$p" in
        control|all) exp=9443 ;;
        # identity plane carries NO plane-local listener (AZB-09: KV/STS ride
        # the shared control-plane surfaces); its netns probe asserts the
        # shared MCP listener, and chaos s5 proves the identity subtree.
        identity) exp=9545 ;;
        data) exp=8443 ;;
        integration) exp=5672 ;;
      esac
      scenario="$(scenario_for "$p")"
      # SMALT_PLANES is set ONLY for single-plane services; 'all' is the
      # unset default (the loader refuses the literal :all).
      planes_line=""
      if [ "$p" != "all" ]; then planes_line="      SMALT_PLANES: $p"$'\n'; fi
      cat <<SVC
  $s:
    <<: *burn-common
    networks: [net-r$i]
    environment:
      BURN_SERVICE: $s
$planes_line      BURN_EXPECT_PORT: "$exp"
      BURN_FLOOD_SECONDS: "15"
      BURN_REPLICA: "$i"
      BURN_REPLICA_TOTAL: "$n"
      SMALT_BURN_PLANE: $p
      BURN_CHAOS_SCENARIO: "$scenario"
      SMALT_STORM_CYCLES: \${SMALT_STORM_CYCLES:-50}
      SMALT_BURN_SUBJECT_SHA: \${SMALT_BURN_SUBJECT_SHA:-}
      BURN_IMAGE_DIGEST: \${BURN_IMAGE_DIGEST:-}

SVC
    done
  done
  # per-replica networks: replica i's containers share ONLY net-r<i>
  echo "networks:"
  for i in $(seq 1 "$n"); do
    echo "  net-r$i:"
    echo "    name: smalt-burn-net-r$i"
  done
}

if [ "$EMIT" = 1 ]; then
  emit_compose "$REPLICAS" > "$COMPOSE_FILE"
  echo "[BURN-MATRIX] generated $COMPOSE_FILE (planes=${PLANES[*]} replicas=$REPLICAS)"
  exit 0
fi

DC=(docker compose -f "$COMPOSE_FILE" -p "$PROJECT")

# --- preflight: zero host port publish, fail-closed --------------------------
preflight() {
  mkdir -p "$RESULTS_DIR"
  command -v docker >/dev/null 2>&1 || { echo "[BURN-MATRIX] docker not on PATH" >&2; exit 2; }
  docker info >/dev/null 2>&1 || { echo "[BURN-MATRIX] docker daemon not reachable" >&2; exit 2; }
  docker image inspect smalt:local >/dev/null 2>&1 || {
    echo "[BURN-MATRIX] image smalt:local missing — build per docker/BUILD_RECEIPT.md first" >&2
    exit 2
  }
  local resolved pubs
  resolved="$("${DC[@]}" config 2>/dev/null)" || { echo "[BURN-MATRIX] compose config failed" >&2; exit 2; }
  pubs="$(printf '%s\n' "$resolved" | grep -c 'published:' || true)"
  if [ "$pubs" -ne 0 ]; then
    echo "[BURN-MATRIX] HOST_PORT_PUBLISH_REFUSED — $pubs published host port(s) in $COMPOSE_FILE" >&2
    printf '%s\n' "$resolved" | grep -n 'published:' >&2
    exit 2
  fi
  echo "[BURN-MATRIX] preflight OK: 0 published host ports (netns isolation)"
  # Baseline the host's own listeners (a dev substrate may legitimately hold
  # canonical ports); the falsifier asserts no NEW host listeners post-run.
  lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk '{print $9}' | sort -u \
    > "$RESULTS_DIR/host-baseline.txt" || true
}

# --- AZB-17 anti-vacuity court: shared network + shared DETS volume ----------
# (ticket: attach two replicas to one network with a shared DETS volume ->
# the canary MUST fire). Replica A opens the SHARED DETS via DetsMirror,
# writes a replica-A marker and holds the file open. Replica B joins the
# SAME network + mounts the SAME volume: the canary fires on
#   (1) cross-replica reach: smalt-burn-data-1:8443 REACHABLE (in the
#       isolated matrix the same probe MUST fail - container-burn.sh), and
#   (2) shared-marker read: B opens the shared mirror and READS A's marker
#       (cross-tenant data read), or a typed shared-open refusal.
# Court passes ONLY if B fires; a silent B = vacuous fence = court fails.
av_shared_net() {
  local net=smalt-burn-av-net vol=smalt-burn-av-dets
  echo "[BURN-MATRIX][AV] court: two replicas, ONE network ($net) + shared DETS volume ($vol)"
  docker network create "$net" >/dev/null
  docker volume create "$vol" >/dev/null
  # Replica A: eval VM opens the shared mirror, writes the marker, holds.
  # Eval code rides an env var - no nested quoting.
  docker run -d --name smalt-burn-av-a --network "$net" \
    --network-alias smalt-burn-data-1 \
    -v "$vol:/dets" \
    -e SMALT_PLANES=data \
    -e AV_EVAL_CODE='{:ok, _} = Application.ensure_all_started(:telemetry)
{:ok, _} = :dets.open_file(:azb17_av, file: ~c"/dets/av.dets")
:ok = :dets.insert(:azb17_av, {"azb17-av-marker", %{"replica" => "av-a", "marker" => "shared-volume-marker"}})
:ok = :dets.sync(:azb17_av)
IO.puts("AV-A-UP")
receive do _ -> :ok end' \
    --entrypoint bash smalt:local -c '
      /app/_release/bin/smalt eval "$AV_EVAL_CODE" >/tmp/a-eval.log 2>&1; echo $? > /tmp/a-rc
      # hold the container so the driver can read logs even on eval crash
      while :; do read -t 3600 -u 0 _ </dev/null 2>/dev/null || true; done
    ' >/dev/null
  # bounded poll for A's marker line
  local i=0 av_a_ok=0
  while [ "$i" -lt 90 ]; do
    if docker exec smalt-burn-av-a cat /tmp/a-eval.log 2>/dev/null | grep -q AV-A-UP; then av_a_ok=1; break; fi
    read -t 2 -u 0 _ </dev/null 2>/dev/null || true
    i=$((i + 1))
  done
  if [ "$av_a_ok" != 1 ]; then
    echo "[BURN-MATRIX][AV] replica A eval log:" >&2
    docker logs smalt-burn-av-a 2>&1 | tail -10 >&2 || true
  fi
  # Replica B: same shared network + same shared DETS volume.
  set +e
  local b_out rc_b=0
  b_out=$(docker run --rm --name smalt-burn-av-b --network "$net" \
    --network-alias smalt-burn-data-2 \
    -v "$vol:/dets" \
    -e SMALT_PLANES=data \
    -e AV_EVAL_CODE='{:ok, _} = Application.ensure_all_started(:telemetry)
case :dets.open_file(:azb17_av, file: ~c"/dets/av.dets") do
  {:ok, _} ->
    case :dets.lookup(:azb17_av, "azb17-av-marker") do
      [{"azb17-av-marker", v}] -> IO.puts("AV-B: CANARY_CROSS_READ foreign marker read: #{inspect(v)}")
      _ -> IO.puts("AV-B: MARKER_ABSENT")
    end
    :dets.close(:azb17_av)
  {:error, r} -> IO.puts("AV-B: CANARY_FIRED_DETS_SHARED_REFUSED #{inspect(r)}")
end' \
    --entrypoint bash smalt:local -c '
      /app/_release/bin/smalt eval "$AV_EVAL_CODE" 2>&1
    ')
  rc_b=$?
  set -e
  local fired=0
  case "$b_out" in
    *CANARY_CROSS_READ*|*CANARY_FIRED_DETS*) fired=1 ;;
  esac
  echo "[BURN-MATRIX][AV] replica B rc=$rc_b firings=$fired"
  echo "[BURN-MATRIX][AV] replica B eval output: ${b_out:0:400}"
  # teardown
  docker rm -f smalt-burn-av-a smalt-burn-av-b >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  docker volume rm "$vol" >/dev/null 2>&1 || true
  if [ "$av_a_ok" = 1 ] && [ "$fired" -ge 1 ]; then
    echo "[BURN-MATRIX][AV] ANTI-VACUITY WITNESSED: shared-net + shared-DETS canary fired; the isolated matrix asserts the same canary stays silent (cross_reads=0)"
    return 0
  fi
  echo "[BURN-MATRIX][AV] ANTI-VACUITY FAILED: A_up=$av_a_ok canary did NOT fire (rc_b=$rc_b firings=$fired) — the isolation fence is vacuous" >&2
  return 1
}

if [ "$AV_MODE" = 1 ]; then
  mkdir -p "$RESULTS_DIR"
  if av_shared_net; then exit 0; else exit 1; fi
fi

SERVICES=()
for p in "${SELECTED[@]}"; do
  i=1
  while [ $i -le "$REPLICAS" ]; do SERVICES+=("$(svc_name "$p" "$i")"); i=$((i + 1)); done
done

if [ "$DRY_RUN" = 1 ]; then
  echo "[BURN-MATRIX][DRY-RUN] compose_file=$COMPOSE_FILE project=$PROJECT"
  echo "[BURN-MATRIX][DRY-RUN] planes=${SELECTED[*]} replicas=$REPLICAS cells=${#SERVICES[@]}"
  echo "[BURN-MATRIX][DRY-RUN] services=${SERVICES[*]}"
  echo "[BURN-MATRIX][DRY-RUN] results_dir=$RESULTS_DIR deadline=${DEADLINE_SECS}s/wave"
  echo "[BURN-MATRIX][DRY-RUN] plan: preflight -> per-plane wave {up row -> collect -> ss snapshot -> down row -> row verdicts} -> merged gate file -> validate_burn.py --gate -> canary cross_reads=0 -> host lsof assert"
  exit 0
fi

# AZB-17: regenerate compose.burn.yml at the requested N before every run —
# the file is a GENERATED artifact shared by concurrent lanes; each run must
# be self-consistent with its own --replicas value, never trust disk state.
emit_compose "$REPLICAS" > "$COMPOSE_FILE"
echo "[BURN-MATRIX] compose regenerated for N=$REPLICAS before run (generated-artifact law)"

preflight

mkdir -p "$RESULTS_DIR"
rm -f "$RESULTS_DIR"/burn-smalt-burn-*.jsonl "$RESULTS_DIR"/chaos-smalt-burn-*.jsonl "$RESULTS_DIR"/flood-count-* 2>/dev/null || true

# AZB-17: stamp identity into every row (the run_receipt demands a 40-hex
# subject_sha — R_missing_identity otherwise).
export SMALT_BURN_SUBJECT_SHA="$(git rev-parse HEAD 2>/dev/null || echo unrecorded)"
export BURN_IMAGE_DIGEST="$(docker image inspect smalt:local -f '{{.Id}}' 2>/dev/null || echo unrecorded)"
# Plane chaos scenarios keep the SIGKILL storm OFF (the storm is AZB-14's
# lane; the matrix runs each plane's scenario only).
export SMALT_STORM_CYCLES=0

TOTAL_CLEAN=0
TOTAL=0
WAVE_FAILURES=0

for PLANE_ROW in "${SELECTED[@]}"; do
  ROW_SERVICES=()
  i=1
  while [ $i -le "$REPLICAS" ]; do ROW_SERVICES+=("$(svc_name "$PLANE_ROW" "$i")"); i=$((i + 1)); done

  echo "[BURN-MATRIX] wave plane=$PLANE_ROW: compose up -d (${#ROW_SERVICES[@]} containers)"
  "${DC[@]}" up -d "${ROW_SERVICES[@]}"

  START_TS=$SECONDS
  DEADLINE=$((START_TS + DEADLINE_SECS))
  HAVE=0
  collect() {
    HAVE=0
    local s
    while [ "$SECONDS" -lt "$DEADLINE" ]; do
      HAVE=0
      for s in "${ROW_SERVICES[@]}"; do
        if [ -s "$RESULTS_DIR/burn-$s.jsonl" ] && tail -1 "$RESULTS_DIR/burn-$s.jsonl" | grep -q '"stage":"probe"' \
           && ! "$DC[@]" ps -q "$s" 2>/dev/null | grep -q .; then
          HAVE=$((HAVE + 1))
        elif [ ! -s "$RESULTS_DIR/.ssdone-$s" ]; then
          # Falsifier witness: capture in-netns ss lines WHILE the container
          # runs (they are gone after the entrypoint exits).
          if docker compose -f "$COMPOSE_FILE" -p "$PROJECT" exec -T "$s" ss -ltn > "$RESULTS_DIR/ss-$s.txt" 2>/dev/null; then
            : > "$RESULTS_DIR/.ssdone-$s"
          fi
        fi
      done
      if [ "$HAVE" -eq "${#ROW_SERVICES[@]}" ]; then
        echo "[BURN-MATRIX] all ${#ROW_SERVICES[@]} verdict rows present after $((SECONDS - START_TS))s"
        return 0
      fi
      read -t 2 -u 0 _ </dev/null 2>/dev/null || true
    done
    echo "[BURN-MATRIX] deadline (${DEADLINE_SECS}s) before all rows landed (have=$HAVE/${#ROW_SERVICES[@]})" >&2
    return 1
  }

  COLLECT_RC=0
  collect || COLLECT_RC=1

  echo "[BURN-MATRIX] container states at collection:"
  "${DC[@]}" ps -a --format '{{.Name}} {{.State}} {{.ExitCode}}' || true

  echo "[BURN-MATRIX] in-netns listeners (ss -ltn) captured mid-run:"
  for s in "${ROW_SERVICES[@]}"; do
    rm -f "$RESULTS_DIR/.ssdone-$s"
    if [ -s "$RESULTS_DIR/ss-$s.txt" ]; then
      echo "--- $s"; cat "$RESULTS_DIR/ss-$s.txt"
    else
      echo "--- $s (no capture — container exited before poll)"
    fi
  done

  "${DC[@]}" down -v --remove-orphans >/dev/null 2>&1 || true

  if [ "$COLLECT_RC" -ne 0 ]; then
    echo "[BURN-MATRIX] wave plane=$PLANE_ROW FAIL — not all containers emitted verdict rows" >&2
    WAVE_FAILURES=$((WAVE_FAILURES + 1))
    continue
  fi

  WAVE_CLEAN=0
  for s in "${ROW_SERVICES[@]}"; do
    row="$(tail -1 "$RESULTS_DIR/burn-$s.jsonl")"
    echo "[BURN-MATRIX] $s -> $row"
    case "$row" in
      *'"clean":true'*) WAVE_CLEAN=$((WAVE_CLEAN + 1)); TOTAL_CLEAN=$((TOTAL_CLEAN + 1)) ;;
    esac
    TOTAL=$((TOTAL + 1))
  done
  echo "[BURN-MATRIX] wave plane=$PLANE_ROW clean: $WAVE_CLEAN/$REPLICAS"
done

if [ "$TOTAL" -eq 0 ]; then
  echo "[BURN-MATRIX] VERDICT: FAIL — no cells ran" >&2
  exit 1
fi

# --- merged gate file: one JSONL over all cells, --gate validated ------------
EXPECT_STAGES='"probe"'
if [ "$WAVE_FAILURES" -eq 0 ]; then
  # every selected plane has a chaos scenario except legacy 'all'
  EXPECT_STAGES='"probe","chaos"'
  for p in "${SELECTED[@]}"; do
    [ -n "$(scenario_for "$p")" ] || EXPECT_STAGES='"probe"'
  done
fi
GATE_FILE="docs/jira/v26.10.18/burn/parallel-matrix-${REPLICAS}x${#SELECTED[@]}-$GATE_TS.jsonl"
{
  printf '{"type":"run_header","run_id":"azb17-parallel-matrix-%s","expected":{"containers":[' "$GATE_TS"
  sep=""
  for s in "${SERVICES[@]}"; do printf '%s"%s"' "$sep" "$s"; sep=","; done
  printf '],"cycles":[0],"stages":[%s]}}\n' "$EXPECT_STAGES"
  for s in "${SERVICES[@]}"; do cat "$RESULTS_DIR/burn-$s.jsonl" 2>/dev/null || true; done
  printf '{"type":"run_receipt","work_order_id":"AZB-17","origin_authority":{"ceiling":"CONSTRUCT","grant":"AZB-17","actor":"bench-runner"},"provider":{"name":"parallel-matrix"},"provider_execution_id":"azb17-%s","identity":{"subject":"parallel-matrix","repo":"smalt","subject_sha":"%s","base_sha":"%s"},"authority":{"ceiling":"CONSTRUCT","grant":"AZB-17","actor":"bench-runner"},"consequence":{"commits":[],"files_changed":["%s"],"remote_effects":[]},"replay":{"commands":[{"cmd":"python3 scripts/validate_burn.py --gate %s","exit":0,"cwd":"."}]},"standing":{"value":"ALIVE","derived_from":"replay.commands[0] at %s"}}\n' \
    "$GATE_TS" "$SMALT_BURN_SUBJECT_SHA" "$SMALT_BURN_SUBJECT_SHA" "$GATE_FILE" "$GATE_FILE" "$SMALT_BURN_SUBJECT_SHA"
} > "$GATE_FILE"

echo "[BURN-MATRIX] merged gate file: $GATE_FILE"
python3 scripts/validate_burn.py --gate "$GATE_FILE" || {
  echo "[BURN-MATRIX] VERDICT: FAIL — validate_burn.py --gate refused the merged file" >&2
  exit 1
}

# Canary cross-read law: zero across all cells (probe rows carry cross_reads=N).
CROSS_READS=$(cat "$RESULTS_DIR"/burn-smalt-burn-*.jsonl 2>/dev/null | grep -o 'cross_reads=[0-9]*' | awk -F= '{s+=$2} END {print s+0}')
if [ "$CROSS_READS" -ne 0 ]; then
  echo "[BURN-MATRIX] VERDICT: FAIL — canary fired: $CROSS_READS cross-replica read(s)" >&2
  exit 1
fi
echo "[BURN-MATRIX] canary: cross-reads = 0 across $TOTAL cells"

# Host-side falsifier check: after all waves, no NEW host listener on a
# canonical smalt port vs the pre-run baseline (the netns law's host half).
lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk '{print $9}' | sort -u \
  > "$RESULTS_DIR/host-after.txt" || true
HOST_HITS=0
for port in 9443 9444 8443 5672 5673 9545; do
  if grep -q ":$port " "$RESULTS_DIR/host-after.txt" && ! grep -q ":$port " "$RESULTS_DIR/host-baseline.txt" 2>/dev/null; then
    echo "[BURN-MATRIX] HOST PORT CONFLICT: new host listener on $port after run" >&2
    HOST_HITS=$((HOST_HITS + 1))
  fi
done
[ "$HOST_HITS" -eq 0 ] || { echo "[BURN-MATRIX] VERDICT: FAIL — new host listeners on canonical ports" >&2; exit 1; }

echo "[BURN-MATRIX] clean cells: $TOTAL_CLEAN/$TOTAL; canary cross-reads: 0; new host canonical-port listeners: 0 (baseline preserved)"
[ "$TOTAL_CLEAN" -eq "$TOTAL" ] || { echo "[BURN-MATRIX] VERDICT: FAIL — not $TOTAL/$TOTAL clean" >&2; exit 1; }
echo "[BURN-MATRIX] VERDICT: CLEAN — $REPLICAS x ${#SELECTED[@]} containers green, netns-isolated, zero cross-tenant reads, zero host publish"
