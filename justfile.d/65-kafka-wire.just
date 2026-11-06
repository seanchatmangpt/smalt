# 65-kafka-wire.just — kafka-wire-pack sync + drift gate (lane R2-I, 2026-11-05).
#
# The pack ontology (ggen-marketplace packs/kafka-wire-pack/ontology.ttl) is the
# single source of truth for the served version matrix; smalt consumes it via
# `ggen sync run` (ggen.toml [packs] pin, absolute path per the
# kubernetes-workload-pack convention). FM-WRITE-002 forbids .. traversal, so
# sync runs FROM SMALT ROOT and renders:
#   lib/smalt/messaging/kafka/wire_projection.ex
#   lib/smalt/messaging/kafka/records_projection.ex
#   docs/reference/kafka-version-matrix.md
# Freeze slots (.ggen/freeze/kafka-wire-pack/*.blake3) make any hand-edit of a
# generated file (or pack edit without re-lock) a typed refusal on the next sync.
# rs/go/consumer-group template families are deferred (frontmatter stripped,
# rules-consumed convention — self-discovery skips them loudly).

SMALT_KAFKA_PACK := env_var_or_default("SMALT_KAFKA_PACK", "/Users/sac/ggen-marketplace/packs/kafka-wire-pack")

# rg fail-loud guard: refuse to fake-pass when ripgrep is absent.
_rg_guard:
    @command -v rg >/dev/null 2>&1 || { echo "refusing to fake-pass: rg missing"; exit 2; }

# ---------------------------------------------------------------------------
# kafka-wire-sync: re-lock (pack changed on disk) and re-render the three
# projections from the pack ontology. Fail-closed on any gate row.
# ---------------------------------------------------------------------------
kafka-wire-sync:
    #!/usr/bin/env bash
    set -euo pipefail
    PACK="{{SMALT_KAFKA_PACK}}"
    [ -f "$PACK/ontology.ttl" ] || { echo "[KAFKA-WIRE-SYNC-SKIP] $PACK/ontology.ttl missing — pack not landed; loud skip" >&2; exit 3; }
    [ -f "$PACK/pack.toml" ] || { echo "[KAFKA-WIRE-SYNC-SKIP] $PACK/pack.toml missing; loud skip" >&2; exit 3; }
    cd /Users/sac/smalt
    # Re-lock: intentional pack edits land in ggen-marketplace, so the smalt
    # lock is expected to lag; the typed FM-PACK-008 refusal is the drift signal.
    rm -f ggen.lock
    sync_out=$(ggen sync run --format json --skip-ea-admission 2>/dev/null) \
      || { echo "[KAFKA-WIRE-SYNC-FAIL] ggen sync run exited nonzero" >&2; exit 1; }
    written=$(printf '%s' "$sync_out" | python3 -c 'import sys,json; print(",".join(p for p in json.load(sys.stdin).get("written",[]) if "kafka" in p or "version-matrix" in p))') \
      || { echo "[KAFKA-WIRE-SYNC-FAIL] could not parse sync JSON" >&2; exit 1; }
    rows=$(printf '%s' "$sync_out" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d.get("written",[]))+len(d.get("skipped",[])))') \
      || { echo "[KAFKA-WIRE-SYNC-FAIL] could not parse sync JSON" >&2; exit 1}
    [ "$rows" -gt 0 ] || { echo "[KAFKA-WIRE-SYNC-FAIL] 0 rows rendered (vacuous render)" >&2; exit 1; }
    echo "[KAFKA-WIRE-SYNC] ok (rows=$rows; kafka-written=${written:-none})"

# ---------------------------------------------------------------------------
# kafka-wire-drift-gate: sync replay must be byte-identical. Any drift on the
# generated paths (hand-edit, stale freeze, pack edit without re-lock) exits 1.
# ---------------------------------------------------------------------------
kafka-wire-drift-gate: _rg_guard
    #!/usr/bin/env bash
    set -euo pipefail
    cd /Users/sac/smalt
    before=$(sha256sum lib/smalt/messaging/kafka/wire_projection.ex lib/smalt/messaging/kafka/records_projection.ex docs/reference/kafka-version-matrix.md .ggen/freeze/kafka-wire-pack/*.blake3 2>/dev/null)
    rm -f ggen.lock
    ggen sync run --format quiet --skip-ea-admission >/dev/null 2>&1 \
      || { echo "[KAFKA-WIRE-DRIFT-FAIL] sync refused" >&2; exit 1; }
    after=$(sha256sum lib/smalt/messaging/kafka/wire_projection.ex lib/smalt/messaging/kafka/records_projection.ex docs/reference/kafka-version-matrix.md .ggen/freeze/kafka-wire-pack/*.blake3 2>/dev/null)
    if [ "$before" != "$after" ]; then
      echo "[KAFKA-WIRE-DRIFT-FAIL] generated surface drifted across sync replay — hand-edit or stale freeze" >&2
      diff <(echo "$before") <(echo "$after") >&2 || true
      exit 1
    fi
    echo "[KAFKA-WIRE-DRIFT-GATE] ok — sync replay byte-identical"

# ---------------------------------------------------------------------------
# kafka-wire-gates: pack-side qualification court (9/9 FLIP-OK) + consumer-side
# smoke (drift gate + sasl court test). This is the one-command gate surface.
# ---------------------------------------------------------------------------
kafka-wire-gates:
    #!/usr/bin/env bash
    set -euo pipefail
    PACK="{{SMALT_KAFKA_PACK}}"
    echo "[KAFKA-WIRE-GATES] pack qualification (9 gates, pass+fail witnesses)"
    (cd "$PACK/qualification" && python3 verify.py > /tmp/kafka-wire-gates-qual.json) \
      || { echo "[KAFKA-WIRE-GATES-FAIL] pack qualification refused" >&2; exit 1; }
    python3 -c 'import json; d=json.load(open("/tmp/kafka-wire-gates-qual.json")); assert d["verdict"]=="CONFORMANT" and d["flips"]==9, d["verdict"]; print("[KAFKA-WIRE-GATES] pack court CONFORMANT 9/9 FLIP-OK")' \
      || { echo "[KAFKA-WIRE-GATES-FAIL] court verdict not CONFORMANT 9/9" >&2; exit 1; }
    echo "[KAFKA-wire-gates] consumer drift gate"
    just --justfile justfile.d/65-kafka-wire.just kafka-wire-drift-gate
    echo "[KAFKA-WIRE-GATES] sasl court + kafka suites"
    export PATH="$(dirname "$(asdf which elixir)"):$(pwd)/bin:$PATH"
    MIX_BUILD_ROOT=_build-laneR2I mix test test/internal/kafka_sasl_court_test.exs 2>&1 | tail -3
    echo "[KAFKA-WIRE-GATES] ok"
