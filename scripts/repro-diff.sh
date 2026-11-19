#!/usr/bin/env bash
# DETB-3: two local smalt releases from one tree, compared by sha256 manifest.
# Contract: SOURCE_DATE_EPOCH and ERL_COMPILER_OPTIONS=deterministic must be set.
# REPRO_DIFF_INJECT=1 appends a timestamp file to tree b (non-vacuity: must exit 1).
set -u
cd "$(dirname "$0")/.." || exit 2
ROOT_DIR="$PWD"  # in-tree build roots: mix writes relative include symlinks (yamerl) that break out of tree

: "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH must be set (operator epoch policy)}"
export SOURCE_DATE_EPOCH
export ERL_COMPILER_OPTIONS="${ERL_COMPILER_OPTIONS:-deterministic}"
if [ "$ERL_COMPILER_OPTIONS" != "deterministic" ]; then
  echo "ERL_COMPILER_OPTIONS must be deterministic" >&2
  exit 2
fi

for d in a b; do
  rm -rf "$ROOT_DIR/_build-repro-$d" "/tmp/detb3-$d"
  MIX_BUILD_ROOT="$ROOT_DIR/_build-repro-$d" MIX_ENV=prod \
    mix release --path "/tmp/detb3-$d" --overwrite || { echo "build $d failed" >&2; exit 1; }
done

if [ "${REPRO_DIFF_INJECT:-0}" = "1" ]; then
  date +%s%N > /tmp/detb3-b/INJECTED-TIMESTAMP
fi

for d in a b; do
  (cd "/tmp/detb3-$d" && find . -type f | sort | xargs shasum -a 256) > "/tmp/detb3-$d.sha"
  echo "== manifest $d ($(wc -l < "/tmp/detb3-$d.sha") files)"
  cat "/tmp/detb3-$d.sha"
done

if [ ! -s /tmp/detb3-a.sha ] || [ ! -s /tmp/detb3-b.sha ]; then
  echo "EMPTY MANIFEST" >&2; exit 1
fi
if [ "$(grep -c '\.beam' /tmp/detb3-a.sha)" -lt 1 ]; then
  echo "NO .beam ENTRIES" >&2; exit 1
fi

if diff /tmp/detb3-a.sha /tmp/detb3-b.sha; then
  echo IDENTICAL
else
  echo "DIFFERENT" >&2; exit 1
fi
