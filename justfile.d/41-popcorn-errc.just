# 41-popcorn-errc.just — popcorn_demo ERRC operator tooling (ERRC-C1, v26.10.20)
#
# One-shot status report, lane-build-root lease reclamation (dry-run default),
# and newest-receipt standings for the popcorn_demo Chicago testbed.
# House law (per justfile.d/40-popcorn.just): justfile_directory() inside an
# imported module resolves to the ROOT justfile's dir; prefixed vars;
# shebang recipes with {{VAR}} interpolation. This module owns only these
# recipes — the root justfile gains one import line.

ERRC_ROOT := justfile_directory()
ERRC_POPCORN := ERRC_ROOT / "popcorn_demo"

# One-shot 80/20 report: substrate status, receipt standings, popcorn_demo
# file inventory, present lane build roots.
@popcorn-errc-status:
    #!/usr/bin/env bash
    set -euo pipefail
    shopt -s nullglob
    cd "{{ERRC_ROOT}}"
    echo "== substrate =="
    just substrate-status || echo "[ERRC] substrate-status failed (exit $?)"
    echo
    echo "== popcorn_demo receipt standings =="
    for f in "{{ERRC_POPCORN}}"/receipts/*.md; do
        s=$(grep -h -m1 -E '^[-*]? *Standing:' "$f" || true)
        echo "$(basename "$f"): ${s:-NO-STANDING-LINE}"
    done
    [ -e "{{ERRC_POPCORN}}/receipts" ] || echo "(no receipts dir)"
    echo
    echo "== popcorn_demo inventory (lib test scripts bench) =="
    for d in lib test scripts bench; do
        echo "--- popcorn_demo/$d ---"
        ls -la "{{ERRC_POPCORN}}/$d" 2>/dev/null || echo "(absent)"
    done
    echo
    echo "== lane build roots present =="
    du -sh "{{ERRC_POPCORN}}"/_build-* 2>/dev/null || echo "(none)"
    exit 0

# Lease reclamation (same-checkout-fanout cleanup law): delete popcorn_demo
# lane build roots. Dry-run default; `just popcorn-lane-clean -y` deletes.
@popcorn-lane-clean *args:
    #!/usr/bin/env bash
    set -euo pipefail
    del=0
    case "{{args}}" in *-y*) del=1 ;; esac
    found=0
    for d in "{{ERRC_POPCORN}}"/_build-lane* "{{ERRC_POPCORN}}"/_build-errc-* "{{ERRC_POPCORN}}"/_build-court "{{ERRC_POPCORN}}"/_build-integ*; do
        [ -e "$d" ] || continue
        found=1
        if [ "$del" = 1 ]; then
            rm -rf "$d"
            echo "[DELETED] $d"
        else
            echo "[WOULD DELETE] $d"
        fi
    done
    [ "$found" = 1 ] || echo "(no lane build roots present)"
    exit 0

# Newest 5 receipts' standing lines.
@popcorn-receipts:
    #!/usr/bin/env bash
    set -euo pipefail
    for f in $(ls -t "{{ERRC_POPCORN}}"/receipts/*.md | head -5); do
        s=$(grep -h -m1 -E '^[-*]? *Standing:' "$f" || true)
        echo "$(basename "$f"): ${s:-NO-STANDING-LINE}"
    done
    exit 0
