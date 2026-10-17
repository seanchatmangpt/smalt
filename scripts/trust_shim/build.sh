#!/usr/bin/env bash
# Build smalt_trust_shim.dylib (gitignored; source is committed).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/smalt_trust_shim.dylib"
cc -dynamiclib \
  -framework Security -framework CoreFoundation \
  -o "$OUT" \
  "$DIR/smalt_trust_shim.c"
echo "built: $OUT"
nm -gU "$OUT" | grep -i interpose >/dev/null 2>&1 || true
echo "verify injection viability: codesign -dv --verbose=2 <target binary> | grep -i flags"
