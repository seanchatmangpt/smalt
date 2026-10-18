# 26-rewitness — KD re-witness recovery (v26.10.17; design:
# docs/jira/v26.10.17/KD_REWITNESS_DESIGN.md). Touching a shim file resets the
# witness mtime chain for every KD row its file covers (~12 rows on
# connection.ex alone). This recipe re-runs a row's registered falsifier and
# mints a fresh PASS receipt so kd_flip's gate clears.

# List KD rows whose witness chain is stale (witness mtime < newest shim mtime).
@kd-stale:
    #!/usr/bin/env bash
    set -euo pipefail
    python3 scripts/kd_flip.py 2>&1 | grep -E "FLIP-PENDING-WITNESS" || echo "[KD-STALE] no pending-witness rows"

# Re-witness a KD row by id: runs the registered falsifier command from the
# row's close-condition cell (falsifier: `<cmd>` convention) and mints
# docs/jira/v26.10.17/receipts/rNNN-kd<id>-rewitness.md. The falsifier string
# is read from KNOWN_DIVERGENCES.md; a row without one exits 3 typed.
@rewitness KD:
    #!/usr/bin/env bash
    set -euo pipefail
    id="{{KD}}"
    row=$(grep -E "^\| KD-$id \|" docs/jira/v26.10.14/KNOWN_DIVERGENCES.md | tail -1)
    if [ -z "$row" ]; then echo "KD-$id not in register" >&2; exit 1; fi
    cmd=$(echo "$row" | grep -oE 'falsifier: \`[^\`]+\`' | head -1 | sed 's/falsifier: `//; s/`//')
    if [ -z "$cmd" ]; then
      echo "REFUSED: KD-$id carries no machine-parseable 'falsifier: \\`cmd\\`' cell (typed skip, exit 3)" >&2
      exit 3
    fi
    echo "[REWITNESS] KD-$id: $cmd"
    out=$(mktemp /tmp/rewitness-kd$id.XXXXXX.md)
    {
      echo "# rNNN-kd$id-rewitness — fresh falsifier run (just rewitness $id)"
      echo
      echo "Standing: PENDING (flip gate input; rename with standing once read)"
      echo "Date: $(date +%F)"
      echo
      echo '```'
      MIX_BUILD_ROOT=_build-rewitness $cmd 2>&1 | tail -25
      echo '```'
    } > "$out"
    echo "[REWITNESS] receipt at $out — rename with the next free rNNN + standing"
