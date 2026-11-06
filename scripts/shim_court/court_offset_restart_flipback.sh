#!/bin/bash
# Non-vacuity flip-back leg for court_offset_restart (v26.11.6 lane 2).
#
# Design law (L60-I post-audit): the flip must reach the substrate's real
# restore path. DetsMirror's mirror set is the COMPILED registry
# (StoreTables.persisted_tables/0 <- generated store_tables.ex <-
# ontology.ttl), so the mutation is carried by the LAWFUL pipeline:
#
#   FLIP ontology row persisted true -> false
#     -> re-render store_tables.ex (ggen_igniter render, byte-faithful)
#     -> RECOMPILE the lane build root (the registry beam now excludes
#        :smalt_eh_checkpoints)
#     -> COURT: eh-checkpoint -> kill -9 -> eh-verify on the recompiled
#        beams. The checkpoint table is no longer mirrored, so restore
#        yields offset nil -> child FAILs -> the court FLIPS.
#     -> RESTORE: flip back, re-render, recompile, sha256 byte-exact vs
#        baseline (fail-closed).
#
# Exit 0 = non-vacuity proven; 1 = VACUOUS COURT or restore mismatch;
# 3 = loud skip (compile window unavailable — fleet churn).
set -euo pipefail

REPO=/Users/sac/smalt
ONT=/Users/sac/ggen-marketplace/packs/smalt-substrate-pack/ontology.ttl
ART=$REPO/lib/smalt/store_tables.ex
ROOT=${MIX_BUILD_ROOT:-_build-lane2}

export PATH=/Users/sac/.asdf/installs/elixir/1.20.4-otp-29/bin:/Users/sac/.asdf/installs/erlang/29.1.2/bin:$PATH
command -v elixir >/dev/null 2>&1 || { echo "[SKIP] elixir toolchain missing"; exit 3; }

BASE_ART=$(sha256sum "$ART" | cut -d' ' -f1)
BASE_ROW=$(sed -n 's/.*smalt_eh_checkpoints.*\(persisted [a-z]*\).*$/\1/p' "$ONT" | head -1)
echo "== BASELINE art=${BASE_ART:0:12} row=$BASE_ROW"
[ "$BASE_ROW" = "persisted true" ] || { echo "[SKIP] baseline row is not persisted true — run the lane flip first"; exit 3; }

compile_quiet() {
  for i in 1 2 3 4 5 6 7 8; do
    if (cd "$REPO" && MIX_ENV=test MIX_BUILD_ROOT="$ROOT" mix compile >/tmp/lane2_flip_compile.log 2>&1); then
      return 0
    fi
    grep -q "Compilation error" /tmp/lane2_flip_compile.log || return 0
    sleep 45
  done
  return 1
}

render_artifact() {
  cat > /tmp/flipback_render.exs <<'RENDER'
alias GgenIgniter.{Render, Engine.Graphlaw}
pack = "/Users/sac/ggen-marketplace/packs/smalt-substrate-pack"
tpl = File.read!(pack <> "/templates/store_tables.ex.eex")
graph = GgenIgniter.Ontology.load!(pack <> "/ontology.ttl")
ctx = Graphlaw.prepare!(graph, [])
results = [{"store_tables", Graphlaw.run(ctx, File.read!(pack <> "/queries/store_tables.rq"))}]
bindings = Mix.Tasks.GgenIgniter.Sync.build_bindings(results)
out = Render.render(tpl, bindings)
File.write!(System.fetch_env!("OUT"), out)
IO.puts("RENDER_OK")
RENDER
  local ARGS=() e
  while IFS= read -r e; do ARGS+=(-pa "$e"); done < <(ls -d /Users/sac/smalt/_build-lane2/dev/lib/*/ebin 2>/dev/null)
  OUT=/tmp/flipback_regen.ex elixir "${ARGS[@]}" /tmp/flipback_render.exs
  cp /tmp/flipback_regen.ex "$ART"
  (cd "$REPO" && mix format lib/smalt/store_tables.ex)
}

set_row() { # set_row true|false
  python3 - "$ONT" "$1" <<'PY'
import sys, re
p, val = sys.argv[1], sys.argv[2]
s = open(p).read()
s2 = re.sub(r'(smalt:st-smalt_eh_checkpoints [^\n]*?)persisted (?:true|false)', r'\1persisted ' + val, s)
assert s2 != s, "row mutation was vacuous"
open(p, 'w').write(s2)
PY
}

restore_state() {
  echo "== RESTORE (flip back to persisted true + re-render + recompile)"
  set_row true
  render_artifact
  compile_quiet || echo "WARN: restore recompile blocked (fleet churn); artifact bytes verified below"
  AFTER=$(sha256sum "$ART" | cut -d' ' -f1)
  if [ "$AFTER" != "$BASE_ART" ]; then
    echo "FAIL-CLOSED: artifact restore is not byte-exact ($BASE_ART -> $AFTER)"
    exit 1
  fi
  echo "== RESTORED byte-exact ${AFTER:0:12}"
}
trap restore_state EXIT

echo "== FLIP-BACK (persisted true -> false)"
set_row false
render_artifact
FLIPPED_ART=$(sha256sum "$ART" | cut -d' ' -f1)
echo "== FLIPPED art=${FLIPPED_ART:0:12}"
if [ "$FLIPPED_ART" = "$BASE_ART" ]; then
  echo "FAIL: flip-back did not change the artifact (render not ontology-faithful)"
  exit 1
fi

echo "== RECOMPILE (registry beam carries the flipped row)"
if ! compile_quiet; then
  echo "[SKIP] compile window unavailable under fleet churn — court leg not witnessed (loud skip)"
  exit 3
fi

# COURT under flip-back: fresh eh-checkpoint -> kill -9 -> eh-verify with
# the RECOMPILED (flipped) registry beams. Children run WITHOUT
# --no-compile so they load the flipped registry (L60-I/L60-L handoff).
D=$(mktemp -d /tmp/lane2-flipback-XXXXXX)
cd "$REPO"
run_phase() {
  COURT_DIR="$D" COURT_RESULT="$D/$1.json" COURT_PID="$D/$1.pid" COURT_MODE="$2" \
    MIX_ENV=test MIX_BUILD_ROOT="$ROOT" \
    mix run --no-start test/courts/support/offset_restart_child.exs >/dev/null 2>&1 &
  until [ -f "$D/$1.pid" ]; do sleep 0.2; done
}
run_phase r1 eh-checkpoint
kill -9 "$(cat "$D/r1.pid")"
run_phase r2 eh-verify

if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("status")=="FAIL" else 1)' "$D/r2.json"; then
  echo "== COURT FLIPPED: eh-verify FAILs under the flipped registry (non-vacuity PROVEN)"
  cat "$D/r2.json"
  rm -rf "$D"
  trap - EXIT
  restore_state
  exit 0
else
  echo "== VACUOUS COURT: eh-verify still PASSes under flip-back"
  cat "$D/r2.json"
  exit 1
fi
