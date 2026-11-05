#!/usr/bin/env bash
# kafka_sasl_court.sh — non-vacuity court for the KD-191 Kafka SASL face
# (lane 10, v26.11.6). Reusable protocol in lib.sh:
#
#   BASELINE  sha256(lib/smalt/messaging/kafka/sasl.ex)
#   BEFORE    the healthy module refuses malformed PLAIN tokens: the
#             KD-191 court suite (test/internal/kafka_sasl_court_test.exs)
#             runs GREEN on the unmodified subject.
#   SHIM      neuter parse_plain's two shape-refusal arms (fallback clause
#             + inner case-miss arm) — marked SHIM-COURT.
#   AFTER     the shimmed module ADMITS malformed tokens, so the same
#             court suite turns RED. This flip is the non-vacuity proof:
#             parse_plain's shape gate demonstrably changes outcomes.
#   RESTORE   byte-exact vs baseline sha256 or [FAIL:RESTORE] (fail-closed).
#
# Exit: 0 non-vacuous / 1 typed FAIL / 3 loud SKIP.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"
source scripts/shim_court/lib.sh

SUBJECT=lib/smalt/messaging/kafka/sasl.ex
COURT=test/internal/kafka_sasl_court_test.exs

[ -f "$REPO/$SUBJECT" ] || shim_court_skip "subject missing: $SUBJECT"
[ -f "$REPO/$COURT" ] || shim_court_skip "court missing: $COURT"
export PATH="$HOME/.asdf/shims:$PATH"
command -v mix >/dev/null || shim_court_skip "mix (asdf elixir pin) not on PATH"

# Fail-closed rg guard (tools.md law): never fake-pass without ripgrep.
command -v rg >/dev/null 2>&1 || { echo "refusing to fake-pass: rg missing"; exit 2; }

export MIX_BUILD_ROOT=_build-shim-kafka-sasl
# KD-174's produce-face fix landed mid-wave: the :vendored_probe leg is
# green and runs in the plain mix test population (tag kept as a marker).
COURT_CMD="mix test $COURT"

# BEFORE: court green on the unmodified subject (shape refusals hold).
BEFORE_CMD="$COURT_CMD > /dev/null 2>&1"
# AFTER: the flip IS the proof — same suite must turn RED under the shim.
AFTER_CMD="if $COURT_CMD > /dev/null 2>&1; then echo \"court unexpectedly GREEN under shim\" >&2; exit 1; else exit 0; fi"

apply_shim() {
    python3 - "$SHIM_FILE" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
old1 = '  def parse_plain(_), do: {:error, :malformed_plain}'
new1 = '  def parse_plain(_), do: {:ok, "", "shim-authcid", "shim-pw"} # SHIM-COURT'
old2 = """      _ ->
        {:error, :malformed_plain}
    end
  end"""
new2 = """      _ ->
        {:ok, "", "shim-authcid", "shim-pw"} # SHIM-COURT
    end
  end"""
if old1 not in src or old2 not in src:
    print("apply_shim: expected parse_plain refusal arms not found", file=sys.stderr)
    sys.exit(1)
open(path, "w").write(src.replace(old1, new1, 1).replace(old2, new2, 1))
PYEOF
}

shim_court_self_check

with_shim "$REPO/$SUBJECT" "$BEFORE_CMD" "$AFTER_CMD"
