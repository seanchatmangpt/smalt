#!/bin/bash
# Non-vacuity flip-back leg for court_offset_restart (v26.11.6 lane 2).
#
# BASELINE -> FLIP-BACK (ontology row persisted true -> false + re-render
# store_tables.ex) -> COURT (eh-verify must FAIL: the checkpoint table is
# no longer in persisted_tables/0, so restore yields offset nil) ->
# RESTORE (flip back to persisted true + re-render, sha256 byte-exact,
# fail-closed).
#
# Exit 0 = non-vacuity proven; exit 1 = VACUOUS COURT; exit 3 = loud skip.
set -euo pipefail

REPO=/Users/sac/smalt
ONT=/Users/sac/ggen-marketplace/packs/smalt-substrate-pack/ontology.ttl
ART=$REPO/lib/smalt/store_tables.ex

export PATH=/Users/sac/.asdf/installs/elixir/1.20.4-otp-29/bin:/Users/sac/.asdf/installs/erlang/29.1.2/bin:$PATH
command -v elixir >/dev/null 2>&1 || { echo "[SKIP] elixir toolchain missing"; exit 3; }

BASE_ART=$(sha256sum "$ART" | cut -d' ' -f1)
echo "== BASELINE art=${BASE_ART:0:12}"

restore_state() {
  echo "== RESTORE (flip back to persisted true + re-render)"
  python3 - "$ONT" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
row = 'smalt:tableName "smalt_eh_checkpoints"'
import re
s = re.sub(r'(smalt:st-smalt_eh_checkpoints [^\n]*?)persisted false', r'\1persisted true', s)
open(p, 'w').write(s)
PY
  render_artifact
  AFTER=$(sha256sum "$ART" | cut -d' ' -f1)
  if [ "$AFTER" != "$BASE_ART" ]; then
    echo "FAIL-CLOSED: artifact restore is not byte-exact ($BASE_ART -> $AFTER)"
    exit 1
  fi
  echo "== RESTORED byte-exact ${AFTER:0:12}"
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
  EBINS=$(ls -d /Users/sac/smalt/_build-lane2/dev/lib/*/ebin 2>/dev/null)
  ARGS=()
  for e in $EBINS; do ARGS+=(-pa "$e"); done
  OUT=/tmp/flipback_regen.ex elixir "${ARGS[@]}" /tmp/flipback_render.exs
  cp /tmp/flipback_regen.ex "$ART"
  (cd "$REPO" && mix format lib/smalt/store_tables.ex)
}

trap restore_state EXIT

echo "== FLIP-BACK (persisted true -> false)"
python3 - "$ONT" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()
s2 = re.sub(r'(smalt:st-smalt_eh_checkpoints [^\n]*?)persisted true', r'\1persisted false', s)
assert s2 != s, "flip-back mutation was vacuous (row not found)"
open(p, 'w').write(s2)
PY
render_artifact
FLIPPED_ART=$(sha256sum "$ART" | run_inline_placeholder 2>/dev/null || sha256sum "$ART" | cut -d' ' -f1)
FLIPPED_ART=$(sha256sum "$ART" | cut -d' ' -f1)
echo "== FLIPPED art=${FLIPPED_ART:0:12}"
if [ "$FLIPPED_ART" = "$BASE_ART" ]; then
  echo "FAIL: flip-back did not change the artifact (render not ontology-faithful)"
  exit 1
fi

# COURT under flip-back: a fresh eh-checkpoint -> kill -9 -> eh-verify on a
# FRESH dir must FAIL (the checkpoint table is no longer mirrored, so the
# restored offset is nil and the child writes status FAIL).
D=$(mktemp -d /tmp/lane2-flipback-XXXXXX)
cd "$REPO"
COURT_DIR=$D COURT_RESULT=$D/r.json COURT_PID=$D/p.pid COURT_MODE=eh-checkpoint \
  MIX_ENV=test MIX_BUILD_ROOT=_build-lane2 \
  mix run --no-start --no-compile test/courts/support/offset_restart_child.exs >/dev/null 2>&1 &
until [ -f "$D/p.pid" ]; do sleep 0.2; done
kill -9 "$(cat "$D/p.pid")"

COURT_DIR=$D COURT_RESULT=$D/r2.json COURT_PID=$D/p2.pid COURT_MODE=eh-verify \
  MIX_ENV=test MIX_BUILD_ROOT=_build-lane2 \
  mix run --no-start --no-compile test/courts/support/offset_restart_child.exs >/dev/null 2>&1

if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("status")=="FAIL" else 1)' "$D/r2.json"; then
  echo "== COURT FLIPPED: eh-verify FAILs under flip-back (non-vacuity PROVEN)"
  rm -rf "$D"
  trap - EXIT
  restore_state
  exit 0
else
  echo "== VACUOUS COURT: eh-verify still PASSes under flip-back"
  cat "$D/r2.json"
  exit 1
fi
