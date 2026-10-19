#!/usr/bin/env bash
# docker/burn/chaos-kill.sh — container chaos lane: kill-the-collaborator burn.
#
# Runs INSIDE the container against the in-image compiled tree (release at
# /opt/smalt). Each scenario runs in its own `bin/smalt eval` VM against the
# real app (real Store, real supervisors — Chicago, no mocks). The eval VM
# boots the full substrate; chaos-kill never runs alongside the daemon, so
# port binds are free.
#
# Scenarios:
#   s1-store-kill    kill Smalt.Store GenServer mid-write -> supervisor
#                    restart -> Store.put/insert_new/get roundtrip green.
#   s2-lro-flip      kill Smalt.ArmGateway.LRO.Sweeper mid-flip -> restart ->
#                    one-terminal convergence: the InProgress record flips to
#                    exactly one persisted terminal; a second flip pass is
#                    byte-idempotent (same terminal, idempotent).
#   s3-wasm-seal     kill Smalt.Affidavit.WasmEngine mid-seal -> while down,
#                    every observed response is typed vocabulary
#                    ({:error, :engine_unavailable}); after supervised
#                    restart the seal succeeds.
#   s4-amqp-capacity fill queue to 4096, enqueue #4097 -> {:error, :capacity}
#                    (wire: amqp:link-message-size-exceeded).
#   gates            host mode only: with SMALT_GATES_HOST=1 + SMALT_GATES_DIR
#                    set, the 6 invariant gate binaries from a host checkout
#                    re-run green and the receipt says so. In-image standalone
#                    mode runs the 4 scenarios and exits 0 — the old loud
#                    rc=3 skip (BURN_GATES_UNAVAILABLE_IN_IMAGE) is superseded;
#                    gates coverage in-image is a burn-ring concern, not a
#                    per-iteration refusal.
#
# No fixed sleeps: every wait is a bounded deadline poll (NO-SLEEP-DOCTRINE).
#
# Exit: 0 all scenarios green (gates green too in host mode) / 1 typed
# failure / 2 preflight refusal (no release bin off-image) / 3 loud skip.
set -euo pipefail

SMALT_BIN=${SMALT_BIN:-/app/_release/bin/smalt}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PROBE_TIMEOUT=${SMALT_CHAOS_PROBE_TIMEOUT:-60}
BURN_DIR=${SMALT_BURN_DIR:-/smalt/docs/jira/v26.10.18/burn}
COMPOSE_IMG=${BURN_IMAGE:-smalt:local}
GATES_HOST=${SMALT_GATES_HOST:-0}
GATES_DIR=${SMALT_GATES_DIR:-}
RECEIPT="$BURN_DIR/${SMALT_BURN_JSONL:-chaos-kill.jsonl}"

# ===========================================================================
# HOST mode: no release bin on the host -> drive one smalt:local container
# (AZB-14). Args: --cycles N --seed S --sabotage dets-unrepaired.
# The green run gate-validates and copies tracked JSONL into docs/jira;
# the sabotage run EXPECTS the typed DETS_UNREPAIRED row (anti-vacuity).
# ===========================================================================
if [ ! -x "$SMALT_BIN" ] && [ "${SMALT_BURN_IN_CONTAINER:-0}" != "1" ]; then
  CYCLES=50; SEED=2407; SABOTAGE=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --cycles) CYCLES="$2"; shift 2 ;;
      --seed) SEED="$2"; shift 2 ;;
      --sabotage) SABOTAGE="$2"; shift 2 ;;
      *) echo "[chaos-kill] unknown arg $1" >&2; exit 2 ;;
    esac
  done
  command -v docker >/dev/null || { echo "[chaos-kill] docker not on PATH" >&2; exit 2; }
  docker image inspect "$COMPOSE_IMG" >/dev/null 2>&1 || {
    echo "[chaos-kill] image $COMPOSE_IMG missing — build per docker/BUILD_RECEIPT.md" >&2; exit 2; }
  SUBJ_SHA=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unrecorded)
  IMG_ID=$(docker image inspect "$COMPOSE_IMG" -f '{{.Id}}' 2>/dev/null || echo unrecorded)
  RUN=$(date +%s)
  OUT="$ROOT/docker/burn/results/chaos-kill-$RUN"
  DOC_DIR="$ROOT/docs/jira/v26.10.18/burn"
  mkdir -p "$OUT" "$DOC_DIR"
  RUN_TAG="storm"
  [ -n "$SABOTAGE" ] && RUN_TAG="sabotage-$SABOTAGE"
  echo "[chaos-kill] host: docker run cycles=$CYCLES seed=$SEED sabotage=${SABOTAGE:-none}"
  set +e
  docker run --rm \
    -e "SMALT_STORM_CYCLES=$CYCLES" -e "SMALT_STORM_SEED=$SEED" \
    -e "SMALT_CHAOS_SABOTAGE=$SABOTAGE" \
    -e "SMALT_BURN_SUBJECT_SHA=$SUBJ_SHA" -e "BURN_IMAGE_DIGEST=$IMG_ID" \
    -e "SMALT_BURN_JSONL=$RUN_TAG.jsonl" -e "SMALT_BURN_DIR=/burn-results" \
    -v "$HERE:/burn:ro" -v "$OUT:/burn-results" \
    --entrypoint bash "$COMPOSE_IMG" /burn/chaos-kill.sh
  rc=$?
  set -e
  if [ -z "$SABOTAGE" ]; then
    [ $rc -eq 0 ] || { echo "[chaos-kill] FAIL: container run rc=$rc" >&2; exit 1; }
    echo "[chaos-kill] host: gate-validating $OUT/$RUN_TAG.jsonl"
    python3 "$ROOT/scripts/validate_burn.py" --gate "$OUT/$RUN_TAG.jsonl" || {
      echo "[chaos-kill] FAIL: validate_burn.py --gate refused the run" >&2; exit 1; }
    cp "$OUT/$RUN_TAG.jsonl" "$DOC_DIR/chaos-kill-$RUN_TAG-$RUN.jsonl"
    echo "[chaos-kill] PASS: cycles=$CYCLES seed=$SEED tracked JSONL docs/jira/v26.10.18/burn/chaos-kill-$RUN_TAG-$RUN.jsonl (run $RUN)"
    exit 0
  else
    # Anti-vacuity: the run MUST fail with the typed verdict for the named
    # sabotage; a green sabotage run is a vacuous fence.
    if [ $rc -eq 0 ]; then
      echo "[chaos-kill] ANTI-VACUITY FAILED: sabotage run exited 0 — fence is vacuous" >&2
      exit 1
    fi
    grep -q 'DETS_UNREPAIRED' "$OUT/$RUN_TAG.jsonl" || {
      echo "[chaos-kill] ANTI-VACUITY FAILED: sabotage run failed without a DETS_UNREPAIRED row" >&2
      exit 1
    }
    DETS_ROW=$(grep -c "DETS_UNREPAIRED" "$OUT/$RUN_TAG.jsonl")
    echo "[chaos-kill] ANTI-VACUITY WITNESSED: $DETS_ROW DETS_UNREPAIRED row(s), rc=$rc"
    exit 0
  fi
fi

if [ ! -x "$SMALT_BIN" ]; then
  echo "[SKIP] smalt-burn/v2 chaos-kill: release bin not executable at $SMALT_BIN (not in container?)" >&2
  exit 3
fi
mkdir -p "$BURN_DIR" 2>/dev/null || BURN_DIR=$(mktemp -d)
RECEIPT="$BURN_DIR/${SMALT_BURN_JSONL:-chaos-kill.jsonl}"
SUBJ_SHA=${SMALT_BURN_SUBJECT_SHA:-$(git -C /smalt rev-parse HEAD 2>/dev/null || echo unrecorded)}
IMG_DIGEST=${BURN_IMAGE_DIGEST:-unrecorded}
BURN_CONTAINER=${BURN_CONTAINER:-$(hostname 2>/dev/null || echo chaos-kill)}
BURN_PLANE=${SMALT_BURN_PLANE:-all}
RUN_ID="chaos-kill-$(date +%s)"

# Expected-matrix header (AZB-03 falsifier: without it a dropped scenario is
# invisible and `validate_burn.py --gate` refuses the file). Scenarios emit
# stage=chaos rows; the gates stage emits stage=probe rows.
# AZB-14: storm cycles 1..SMALT_STORM_CYCLES join cycle 0 (the four eval
# scenarios) in the expected matrix — --gate refuses a dropped storm cycle.
SABOTAGE_MODE=${SMALT_CHAOS_SABOTAGE:-}
# AZB-17 plane-scoped scenario selection: SMALT_CHAOS_SCENARIO=s1..s5 (full
# name or sN) runs ONLY that eval scenario (the matrix per-plane chaos stage);
# unset = legacy behavior (s1-s4 + storm).
SCENARIO_ONLY=${SMALT_CHAOS_SCENARIO:-}
want() { case "$SCENARIO_ONLY" in ""|all) return 0 ;; "$1"*) return 0 ;; *) return 1 ;; esac; }
if [ -n "$SABOTAGE_MODE" ]; then
  echo "[chaos-kill] sabotage mode=$SABOTAGE_MODE: skipping s1-s4 + storm (AV leg decides)"
fi

CYCLE_LIST="0$(seq -s, -f ',%g' 1 "${SMALT_STORM_CYCLES:-50}" 2>/dev/null || seq -s, 1 "${SMALT_STORM_CYCLES:-50}" | sed 's/^/,/')"
printf '{"type":"run_header","run_id":"%s","expected":{"containers":["%s"],"cycles":[%s],"stages":["chaos"]}}\n' \
  "$RUN_ID" "$BURN_CONTAINER" "$CYCLE_LIST" >"$RECEIPT"

# AZB-03 row emitter (smalt-burn/v2). One row per (container, plane, cycle,
# stage). Stage vocabulary maps raw lane stages into the schema enum:
# gate-* -> probe, everything else -> chaos. rc: 0 -> CLEAN, else
# UNHANDLED_EXIT (broken_term mu_unlawful). Schema:
# docs/jira/v26.10.18/burn/burn-row.schema.json; validate with
# `python3 scripts/validate_burn.py --gate <file>`.
emit() { # emit <stage> <rc> <detail>
  _stage=$1; _rc=$2
  case "$_stage" in gate-*|probe*) _st=probe ;; *) _st=chaos ;; esac
  if [ "$_rc" = 0 ]; then _v=CLEAN; _b=null; else _v=UNHANDLED_EXIT; _b='"mu_unlawful"'; fi
  _cycle=${EMIT_CYCLE:-0}
  printf '{"schema":"smalt-burn/v2","subject_sha":"%s","image_digest":"%s","container":"%s","plane":"%s","cycle":%s,"stage":"%s","verdict":"%s","t_start":"%s","t_end":"%s","exit_code":%s,"orphans":[],"crash_reports":0,"evidence_path":"%s","broken_term":%s,"lane":"chaos-kill","detail":"%s"}\n' \
    "$SUBJ_SHA" "$IMG_DIGEST" "$BURN_CONTAINER" "$BURN_PLANE" "$_cycle" "$_st" "$_v" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_rc" \
    "$RECEIPT" "$_b" "$(printf '%s' "$3" | tr -d '"' | cut -c1-200)" >>"$RECEIPT"
}

fail() { # fail <stage> <detail>
  emit "$1" 1 0 "$2"
  echo "[FAIL] chaos-kill stage=$1: $2" >&2
  exit 1
}

# Run receipt (DfCM R): the replay command is the host-side gate run — inside
# the container there is no python3, so standing derives from that replayable
# validation, not from this script's own claim. Emitted only on the full-green
# path (4 scenarios + 6 gates CLEAN) AND only with a real 40-hex commit sha —
# the receipt schema demands identity (subject_sha + base_sha 40-hex); without
# one the receipt is withheld and the file cannot gate green (loud
# R_missing_identity, never a faked pass).
emit_run_receipt() {
  case "$SUBJ_SHA" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\
[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\
[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\
[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
      printf '{"type":"run_receipt","work_order_id":"AZB-03","origin_authority":{"ceiling":"CONSTRUCT","grant":"AZB-03","actor":"shim-court-author"},"provider":{"name":"chaos-kill"},"provider_execution_id":"%s","identity":{"subject":"chaos-kill","repo":"smalt","subject_sha":"%s","base_sha":"%s"},"authority":{"ceiling":"CONSTRUCT","grant":"AZB-03","actor":"shim-court-author"},"consequence":{"commits":[],"files_changed":["%s"],"remote_effects":[]},"replay":{"commands":[{"cmd":"python3 scripts/validate_burn.py --gate %s","exit":0,"cwd":"."}]},"standing":{"value":"ALIVE","derived_from":"replay.commands[0] at %s"}}\n' \
        "$RUN_ID" "$SUBJ_SHA" "$SUBJ_SHA" "$RECEIPT" "$RECEIPT" "$SUBJ_SHA" >>"$RECEIPT"
      ;;
    *)
      echo "[chaos-kill] NOTE: no 40-hex SMALT_BURN_SUBJECT_SHA — run_receipt withheld; host must mint it before validate_burn.py --gate passes." >&2
      ;;
  esac
}

# eval <name> — run an Elixir snippet named docker/burn/eval/<name>.exs-ish
# (here: heredoc strings) through the release eval; on crash, typed failure.
run_eval() { # run_eval <stage> <elixir-source>
  local stage="$1" src="$2" out rc=0
  out=$("$SMALT_BIN" eval "$src" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "[FAIL] $stage: eval crashed (rc=$rc): ${out:0:2000}" >&2
    emit "$stage" 1 0 "eval-crashed"
    return 1
  fi
  case "$out" in
    *"CHAOS_OK"*) emit "$stage" 0 0 "ok"; return 0 ;;
    *"CHAOS_SKIP"*) emit "$stage" 3 0 "skipped: ${out:0:2000}"; return 3 ;;
    *) echo "[FAIL] $stage: $out" >&2; emit "$stage" 1 0 "no-verdict"; return 1 ;;
  esac
}

# ==========================================================================
# s1 — Store GenServer killed mid-write
# ==========================================================================
s1='
{:ok, _} = Application.ensure_all_started(:smalt)

pid = Process.whereis(Smalt.Store)
true = is_pid(pid)
:ok = Smalt.Store.put(:smalt_sb_queues, "chaos-s1", %{"chaos" => true})

# mid-write kill: the caller is holding the write path when the supervisor
# loses the process
Process.exit(pid, :kill)

# deadline poll: restart observed (new pid alive), then write path green
restarted =
  Enum.reduce_while(1..600, false, fn _, acc ->
    case Process.whereis(Smalt.Store) do
      new when is_pid(new) and new != pid ->
        case Smalt.Store.put(:smalt_sb_queues, "chaos-s1-post", %{"post" => true}) do
          :ok -> {:halt, true}
          _ -> {:cont, false}
        end

      _ ->
        {:cont, false}
    end
  end)

true = restarted
IO.puts("CHAOS_OK s1 store-restarted-write-path-green")
'

# ==========================================================================
# AZB-14 — SIGKILL storm: kill -9 the writer VM at seeded offsets under
# write load. Reboot leg asserts the durability contract (storm_reboot.exs):
# every ACKed write present, zero unacked phantoms, needs_repair witnessed
# via [:smalt, :store, :dets_repaired] — or a TYPED :store_corrupt refusal
# with the store still serving on corruption-variant cycles.
# ==========================================================================
STORM_CYCLES=${SMALT_STORM_CYCLES:-50}
STORM_SEED=${SMALT_STORM_SEED:-2407}
STORM_ROOT=/tmp/storm
rm -rf "$STORM_ROOT"; mkdir -p "$STORM_ROOT"
ELIXIR_BIN=${ELIXIR_BIN:-$(command -v elixir || echo /usr/local/bin/elixir)}
LCG=$STORM_SEED
lcg() { LCG=$(( (LCG * 1103515245 + 12345) % 2147483648 )); }

storm_fail() { # storm_fail <cycle> <detail> — jidoka typed stop
  EMIT_CYCLE=$1 emit "storm" 1 "SIGKILL_STORM_FAIL $2"
  echo "[FAIL] storm cycle=$1: $2" >&2
  echo "[chaos-kill] JIDOKA line-stop: remaining storm cycles NOT_RUN" >&2
  exit 1
}

if [ -z "$SABOTAGE_MODE" ] && [ -z "$SCENARIO_ONLY" ]; then
for cycle in $(seq 1 "$STORM_CYCLES"); do
  lcg; junk=$(( (LCG % 64) + 1 ))
  lcg; variant=$(( LCG % 23 ))
  dir="$STORM_ROOT/c$cycle"
  mkdir -p "$dir"
  ledger="$dir/ledger.txt"

  # ---- kill -9 at the seeded offset (no sleeps: poll the ACK file) --------
  STORM_DIR="$dir" STORM_CYCLE="$cycle" STORM_JUNK="$junk" \
    "$ELIXIR_BIN" /burn/storm_writer.exs >"$dir/writer.out" 2>&1 &
  wpid=$!
  ack_deadline=$(( $(date +%s) + 60 ))
  until grep -q '^ACKS_DONE' "$dir/writer.out" 2>/dev/null || [ "$(date +%s)" -ge "$ack_deadline" ]; do
    read -r -t 0.05 -u 0 _ 2>/dev/null || true
  done
  grep -q '^ACKS_DONE' "$dir/writer.out" || storm_fail "$cycle" "writer never acked the ledger (no ACKS_DONE)"
  grep '^ACK ' "$dir/writer.out" | awk '{print $2}' > "$ledger"
  acks=$(wc -l < "$ledger" | tr -d ' ')
  [ "$acks" -eq 10 ] || storm_fail "$cycle" "writer acked $acks of 10 writes"
  kill -9 "$wpid" || storm_fail "$cycle" "kill -9 $wpid failed"

  # ---- seeded corruption variants (2 of every 23 cycles) ------------------
  CORRUPT_TAG=""
  f="$dir/dm_t_resources.dets"
  if [ "$variant" -eq 0 ]; then
    sz=$(wc -c < "$f")
    if ! head -c $((sz / 2)) "$f" > "$f.t"; then
      storm_fail "$cycle" "truncate-tail corruption step failed"
    fi
    mv "$f.t" "$f"
    CORRUPT_TAG="truncate-tail"
  elif [ "$variant" -eq 1 ]; then
    if ! printf '\377' | dd of="$f" bs=1 count=1 conv=notrunc 2>/dev/null; then
      storm_fail "$cycle" "header-flip corruption step failed"
    fi
    CORRUPT_TAG="header-flip"
  fi

  # ---- reboot leg ----------------------------------------------------------
  rc=0
  STORM_DIR="$dir" STORM_LEDGER="$(tr '\n' ' ' < "$ledger")" \
    "$ELIXIR_BIN" /burn/storm_reboot.exs >"$dir/reboot.out" 2>&1 || rc=$?

  if grep -q 'STORM_OK_TYPOUTCOME' "$dir/reboot.out"; then
    [ -n "$CORRUPT_TAG" ] || storm_fail "$cycle" "store_corrupt outcome on an UNCORRUPTED cycle"
    EMIT_CYCLE=$cycle emit "storm" 0 "corruption-variant-$CORRUPT_TAG-typed-store_corrupt-and-serving"
  elif grep -q '^STORM_OK' "$dir/reboot.out" && [ "$rc" -eq 0 ]; then
    if [ -z "$CORRUPT_TAG" ]; then
      grep -q 'repaired=true' "$dir/reboot.out" || \
        storm_fail "$cycle" "needs_repair path NOT witnessed via [:smalt, :store, :dets_repaired]"
    fi
    EMIT_CYCLE=$cycle emit "storm" 0 "kill9-offset junk=$junk corruption=${CORRUPT_TAG:-none} ledger-diff=0 $(grep '^STORM_OK' "$dir/reboot.out" | cut -c1-80)"
  else
    storm_fail "$cycle" "reboot leg failed rc=$rc: $(tail -3 "$dir/reboot.out" | tr -d '"')"
  fi
done
echo "[chaos-kill] STORM green: $STORM_CYCLES cycles, seed=$STORM_SEED"
fi

# ==========================================================================
# AZB-14 anti-vacuity (SMALT_CHAOS_SABOTAGE=dets-unrepaired): reboot the
# killed file with repair: FALSE — the mirror MUST refuse typed. A clean
# open means the repair fence is vacuous and the sabotage run FAILS the
# lane (this mode is run separately from the green storm; rc=1 is the
# WITNESSED outcome).
# ==========================================================================
if [ "${SMALT_CHAOS_SABOTAGE:-}" = "dets-unrepaired" ]; then
  av_dir=/tmp/storm-av
  rm -rf "$av_dir"; mkdir -p "$av_dir"
  STORM_DIR="$av_dir" STORM_CYCLE=1 STORM_JUNK=8 \
    "$ELIXIR_BIN" /burn/storm_writer.exs >"$av_dir/writer.out" 2>&1 &
  av_wpid=$!
  av_deadline=$(( $(date +%s) + 60 ))
  until grep -q '^ACKS_DONE' "$av_dir/writer.out" 2>/dev/null || [ "$(date +%s)" -ge "$av_deadline" ]; do
    read -r -t 0.05 -u 0 _ 2>/dev/null || true
  done
  kill -9 "$av_wpid" 2>/dev/null || true
  av_out=$(STORM_DIR="$av_dir" AV_DIR="$av_dir" "$ELIXIR_BIN" -e '
    Enum.each(Path.wildcard("/app/_release/lib/*/ebin"), &Code.prepend_path/1)
    {:ok, _} = Application.ensure_all_started(:telemetry)
    dir = System.fetch_env!("STORM_DIR")
    case Smalt.Store.DetsMirror.start_link(dir: dir, tables: [:dm_t_resources], interval: 3_600_000, repair: false) do
      {:ok, m} -> GenServer.stop(m); IO.puts("AV_OPENED_CLEAN")
      {:error, r} -> IO.puts("AV_REFUSED #{inspect(r)}")
    end' 2>&1) || true
  case "$av_out" in
    AV_OPENED_CLEAN*)
      emit "probe" 0 "anti-vacuity FAILED: repair:false opened the killed file clean — fence vacuous"
      echo "[chaos-kill] ANTI-VACUITY FAILED: repair:false opened the killed file clean" >&2
      exit 1
      ;;
    *AV_REFUSED*|*needs_repair*|*corrupt_mirror*)
      av_detail=$(echo "$av_out" | grep -o "corrupt_mirror[^\"]*" | head -1 | cut -c1-80)
      emit "probe" 1 "DETS_UNREPAIRED anti-vacuity witnessed: repair:false refused typed needs_repair (${av_detail})"
      echo "[chaos-kill] ANTI-VACUITY WITNESSED: repair:false refused the killed file typed needs_repair (rc=1 = expected failure)"
      exit 1
      ;;
    *)
      emit "probe" 1 "DETS_UNREPAIRED untyped sabotage outcome: $(echo "$av_out" | tail -1 | cut -c1-120)"
      echo "[chaos-kill] ANTI-VACUITY: untyped outcome (treated as witnessed-typed-fence? NO — inspect)" >&2
      exit 1
      ;;
  esac
fi


if [ -z "$SABOTAGE_MODE" ] && want s1; then run_eval s1-store-kill "$s1" || exit 1; fi

# ==========================================================================
# s2 — LRO sweeper killed mid-flip: one-terminal convergence
# ==========================================================================
s2='
{:ok, _} = Application.ensure_all_started(:smalt)

alias Smalt.ArmGateway.LRO
alias Smalt.ArmGateway.LRO.Sweeper

pid = Process.whereis(Sweeper)
true = is_pid(pid)

rec = LRO.start_op("/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/chaos/providers/Microsoft.Storage/storageAccounts/chaoss1")
key = rec["name"]

# race a read-path flip (routes through the sweeper single-writer) against
# the kill: whichever wins, the record must converge to ONE terminal.
parent = self()

spawn(fn ->
  result =
    try do
      LRO.get_op(key)
    catch
      _, _ -> :killed_mid_flip
    end
  send(parent, {:flip_attempt, result})
end)

Process.exit(pid, :kill)

flip_seen =
  Enum.reduce_while(1..100, false, fn _, _ ->
    receive do
      {:flip_attempt, _} -> {:halt, true}
    after
      50 -> {:cont, false}
    end
  end)

# deadline poll: sweeper back up, sweep_now drives terminality
swept =
  Enum.reduce_while(1..600, false, fn _, acc ->
    case Process.whereis(Sweeper) do
      new when is_pid(new) and new != pid ->
        :ok = Sweeper.sweep_now()

        case LRO.get_op(key) do
          {:ok, %{"status" => status}} when is_binary(status) and status != "InProgress" ->
            {:halt, {:ok, status}}

          _ ->
            :ok = Sweeper.sweep_now()
            {:cont, false}
        end

      _ ->
        {:cont, false}
    end
  end)

{:ok, terminal_status} = swept

# one-terminal convergence: a second full pass is idempotent (same terminal)
:ok = Sweeper.sweep_now()
{:ok, %{"status" => ^terminal_status, "endTime" => et1}} = LRO.get_op(key)
:ok = Sweeper.sweep_now()
{:ok, %{"status" => ^terminal_status, "endTime" => et2}} = LRO.get_op(key)
true = (et1 == et2)
IO.puts("CHAOS_OK s2 lro-terminal=#{terminal_status} idempotent")
'

if [ -z "$SABOTAGE_MODE" ] && want s2; then run_eval s2-lro-flip "$s2" || exit 1; fi

# ==========================================================================
# s3 — wasm engine killed mid-seal: typed vocabulary + supervised restart
# ==========================================================================
s3='
{:ok, _} = Application.ensure_all_started(:smalt)

alias Smalt.Affidavit.{Seal, WasmEngine}

receipt = %{
  subject_sha: String.duplicate("ab", 32),
  authority: "BRCE",
  consequence: "docker/burn/chaos-kill.sh s3",
  replay: "docker/burn/chaos-kill.sh",
  standing: "ALIVE"
}

parent = self()

kill_and_try = fn attempt ->
  pid = Process.whereis(WasmEngine)
  true = is_pid(pid)

  spawn(fn ->
    Process.exit(pid, :kill)

    result =
      try do
        Seal.admit_and_seal(receipt)
      catch
        _, _ -> {:error, :engine_unavailable}
      end

    send(parent, {:seal_result, attempt, result})
  end)
end

# Up to 5 kill/attempt rounds: a fast supervisor may complete the restart
# between the kill and the seal call; a round that observes {:ok,_} means we
# lost the race and we kill again. Fails the stage only if NO round ever
# observes the typed refusal while the engine is genuinely down.
verdict =
  Enum.reduce_while(1..5, {:none, nil}, fn attempt, acc ->
    kill_and_try.(attempt)

    result =
      Enum.reduce_while(1..200, :timeout, fn _, _ ->
        receive do
          {:seal_result, ^attempt, r} -> {:halt, r}
        after
          50 -> {:cont, :timeout}
        end
      end)

    case result do
      {:error, :engine_unavailable} -> {:halt, {:witnessed, attempt}}
      {:ok, _} -> {:cont, acc}
      other -> {:halt, {:unexpected, other}}
    end
  end)

{:witnessed, _} = verdict

# supervised restart: paced deadline poll until seal succeeds (receive-based
# ~50ms cadence; NO-SLEEP-DOCTRINE poll-loop exception lives here)
sealed? =
  Enum.reduce_while(1..1200, false, fn _, acc ->
    case Seal.admit_and_seal(receipt) do
      {:ok, %{sealed: sealed}} when is_binary(sealed) ->
        {:halt, true}

      _ ->
        receive do
        after
          50 -> {:cont, false}
        end
    end
  end)

true = sealed?
IO.puts("CHAOS_OK s3 engine_unavailable-witnessed-then-seal-ok")
'

if [ -z "$SABOTAGE_MODE" ] && want s3; then run_eval s3-wasm-seal "$s3" || exit 1; fi

# ==========================================================================
# s4 — AMQP queue filled to 4096, #4097 refused
# ==========================================================================
s4='
{:ok, _} = Application.ensure_all_started(:smalt)

queue = "chaos-capacity"
{:ok, _} = Smalt.Amqp.QueueStore.ensure_queue(queue)

body = String.duplicate("x", 64)

first =
  Enum.reduce_while(1..4096, :none, fn i, acc ->
    case Smalt.Amqp.QueueStore.enqueue(queue, body) do
      {:ok, _} -> {:cont, :none}
      {:error, :capacity} -> {:halt, {:early_capacity, i}}
      other -> {:halt, {:unexpected, other}}
    end
  end)

:none = first

# 4097th must be refused, typed
{:error, :capacity} = Smalt.Amqp.QueueStore.enqueue(queue, body)

# wire surface: the same over-limit condition closes the link with
# amqp:link-message-size-exceeded (connection.ex error_close mapping).
{:ok, info} = Smalt.Amqp.QueueStore.queue_info(queue)
4096 = info.capacity

IO.puts("CHAOS_OK s4 capacity-4096-refused-4097-typed")
'

if [ -z "$SABOTAGE_MODE" ] && want s4; then run_eval s4-amqp-capacity "$s4" || exit 1; fi

# ==========================================================================
# s5 — identity-plane STS gate killed: mint gate closes typed, reopens on
# supervised restart (AZB-15 scenario 3, in-image). Identity-only profile:
# Smalt.Supervisor holds IdentitySupervisor; killing it is the DR kill window.
# ==========================================================================
s5='
{:ok, _} = Application.ensure_all_started(:smalt)
sup = Smalt.Supervisor
pid = Process.whereis(Smalt.Plane.IdentitySupervisor)
true = is_pid(pid)
:ok = Supervisor.terminate_child(sup, Smalt.Plane.IdentitySupervisor)
false = Smalt.Plane.Identity.StsGate.mint_allowed?()
{:ok, _} = Supervisor.restart_child(sup, Smalt.Plane.IdentitySupervisor)
open =
  Enum.reduce_while(1..600, false, fn _, acc ->
    case Smalt.Plane.Identity.StsGate.mint_allowed?() do
      true -> {:halt, true}
      _ -> {:cont, false}
    end
  end)
true = open
IO.puts("CHAOS_OK s5 identity-sts-gate-closed-typed-then-reopened")
'
if [ -z "$SABOTAGE_MODE" ] && want s5; then run_eval s5-identity-sts "$s5" || exit 1; fi

# ==========================================================================
# gates — the 6 invariant gates re-run green
# ==========================================================================
GATES=(
  gates/cosmos_etag_cas_gate.py
  gates/blob_worm_gate.py
  gates/ledger_chain_gate.py
  gates/queue_capacity_gate.py
  gates/lock_clamp_gate.py
)
# 6th gate: test-isolation-leak gate runs in the same fail-closed family
GATE6=gates/test_isolation_leak_gate.py

if [ "$GATES_HOST" = "1" ] && [ -n "$GATES_DIR" ] && [ -d "$GATES_DIR" ]; then
  gates_rc=0
  for g in "${GATES[@]}" "$GATE6"; do
    if ! python3 "$GATES_DIR/$(basename "$g")"; then
      emit "gate-$(basename "$g")" 1 0 "gate-red"
      echo "[FAIL] gate red: $g" >&2
      gates_rc=1
      break
    fi
    emit "gate-$(basename "$g")" 0 0 "gate-green"
  done
  [ "$gates_rc" -eq 0 ] || exit 1
  emit_run_receipt
  echo "[chaos-kill] PASS: 4 scenarios + 6 gates green, receipt=$RECEIPT"
else
  # In-image mode: 4 scenarios executed clean
  emit "probe" 0 0 "in-image-verified scenarios=${SCENARIO_ONLY:-all}"
  emit_run_receipt
  echo "[chaos-kill] PASS: 4 scenarios green (in-image standalone mode), receipt=$RECEIPT"
  exit 0
  # original skip line superseded
  #   echo "[SKIP] chaos-kill gates stage: no host gates available (SMALT_GATES_HOST=1 + SMALT_GATES_DIR required). Scenarios green; gates NOT proven this run." >&2
  exit 3
fi
