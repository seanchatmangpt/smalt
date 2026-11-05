#!/usr/bin/env bash
# LANE-4 (v26.11.6): build the AoQ QUIC NIF dylib and stage it for smalt.
#
# Builds cgap-beam with the `quic` feature (quinn engine behind the
# LANE-02 NIF boundary) and copies the dylib to
# priv/aoq/aq_beam_nif (extension-stripped, as load_nif expects).
#
# The dylib is a build artifact: NEVER committed (gitignored at
# priv/aoq/aq_beam_nif.*), always staged by this script.
#
# cgap root resolution order:
#   1. SMALT_AOQ_NIF_CGAP_ROOT env
#   2. config :smalt, :aoq, cgap_root:
#   3. default: ../cgap relative to this script's checkout
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CGAP_ROOT="${SMALT_AOQ_NIF_CGAP_ROOT:-}"

if [ -z "$CGAP_ROOT" ]; then
  # config :smalt, :aoq, cgap_root: "/path" — read via a tiny eval so we
  # don't need a bootstrapped mix run.
  CGAP_ROOT="$(cd "$ROOT" && mix run --no-start -e '
    IO.puts(Application.get_env(:smalt, :aoq, []) |> Keyword.get(:cgap_root, "") |> to_string())
  ' 2>/dev/null || true)"
fi

if [ -z "$CGAP_ROOT" ]; then
  CGAP_ROOT="$(cd "$ROOT/.." && pwd)/cgap"
fi

if [ ! -d "$CGAP_ROOT/crates/cgap-beam" ]; then
  echo "build_aoq_nif: cgap root not found (tried SMALT_AOQ_NIF_CGAP_ROOT, config :smalt, :aoq, cgap_root:, $ROOT/../cgap)" >&2
  exit 2
fi

echo "build_aoq_nif: cgap root = $CGAP_ROOT"
(cd "$CGAP_ROOT" && cargo build -p cgap-beam --features quic --release)

DEST_DIR="$ROOT/priv/aoq"
DYLIB="$CGAP_ROOT/target/release/libcgap_beam.dylib"

case "$(uname -s)" in
  Linux) DYLIB="$CGAP_ROOT/target/release/libcgap_beam.so" ;;
esac

if [ ! -f "$DYLIB" ]; then
  echo "build_aoq_nif: cargo succeeded but dylib missing: $DYLIB" >&2
  exit 2
fi

mkdir -p "$DEST_DIR"
# OTP load_nif appends ".so" on EVERY platform (macOS included) - a
# .dylib-named copy is never opened (witnessed in the LANE-4 court:
# dlopen tried only aq_beam_nif.so). Stage under the .so name.
cp "$DYLIB" "$DEST_DIR/aq_beam_nif.so"
# The extensionless copy is the dispatch-contract artifact name (the
# loader path is priv/aoq/aq_beam_nif; OTP appends .so itself).
cp "$DYLIB" "$DEST_DIR/aq_beam_nif"

chmod 644 "$DEST_DIR/aq_beam_nif" "$DEST_DIR/aq_beam_nif.so"
echo "build_aoq_nif: staged $DEST_DIR/aq_beam_nif.so (+ extensionless copy)"
