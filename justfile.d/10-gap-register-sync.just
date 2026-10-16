# 10-gap-register-sync — DoD lane module (owned by its lane; see docs/jira/v26.10.14)

# gap-sync: re-run the audit greps and diff the gap/defect register against the lane-13 census. Exit 1 on drift.
@gap-sync:
    #!/usr/bin/env bash
    set -euo pipefail
    REPO="{{justfile_directory()}}"
    WP="$REPO/docs/WIRE_PARITY.md"
    KD="$REPO/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md"
    GR="$REPO/docs/jira/v26.10.14/receipts/13-gap-register.md"
    fail() { echo "gap-sync: DRIFT: $1" >&2; exit 1; }

    for f in "$WP" "$KD" "$GR"; do
      [ -f "$f" ] || fail "missing $f"
    done

    # -- KNOWN_DIVERGENCES: every registered id present, table rows well-formed, all OPEN --
    want="KD-35"
    grep -q "| $want |" "$KD" || fail "$want row missing from KNOWN_DIVERGENCES.md"
    n_rows=$(grep -cE '^\| KD-[0-9]+ \|' "$KD")
    [ "$n_rows" -ge 35 ] || fail "KD table rows regressed below the v26.10.14 census floor: $n_rows"
    n_ids=$(grep -oE 'KD-[0-9]+' "$KD" | sort -u | wc -l | tr -d ' ')
    [ "$n_ids" -ge 35 ] || fail "unique KD ids regressed below the census floor: $n_ids"
    # every KD row's status cell must be OPEN (last cell)
    bad_status=$(grep -E "^\| KD-[0-9]+ \|" "$KD" | awk -F'|' '{gsub(/ /,"",$(NF-1)); if ($(NF-1)!="OPEN" && $(NF-1) !~ /^CLOSED/) print NR": "$0}' | head -5)
    [ -z "$bad_status" ] || fail "KD rows with unrecognized status (must be OPEN or CLOSED*):\n$bad_status"

    # -- census: 5 CLOSED-with-receipt tokens = 2 strikethrough in WIRE_PARITY + 3 CLOSED rows in C1_ARM_REST --
    closed=$(grep -oE '~~`GAP\([a-z0-9-]+\)`~~' "$WP" | sort -u | wc -l | tr -d ' ')
    [ "$closed" -eq 2 ] || fail "WIRE_PARITY strikethrough CLOSED tokens: expected 2, found $closed"
    closed_c1=$(sed -n '83,85p' "$REPO/docs/compliance/C1_ARM_REST.md" | grep -cE 'CLOSED 2026-10-15 \((lens-9 cycle-1|V261014-05)\)')
    [ "$closed_c1" -eq 3 ] || fail "C1_ARM_REST:83-85 CLOSED rows: expected 3, found $closed_c1"

    # -- WIRE_PARITY census: 9 typed-UNSUPPORTED open tokens, live GAP(...) form --
    live_gap=$(grep -oE 'GAP\([a-z0-9-]+\)' "$WP" | sort -u \
      | grep -vE 'lro-no-failed-path|blob-error-envelope-json|blob-x-ms-error-code-header-absent|^GAP\(name\)$' | wc -l | tr -d ' ')
    [ "$live_gap" -eq 9 ] || fail "WIRE_PARITY typed-UNSUPPORTED GAP tokens: expected 9, found $live_gap"

    # -- register receipt census strings still on disk --
    grep -q "CLOSED-with-receipt: \`lro-no-failed-path\`" "$GR" || fail "lane-13 CLOSED census line missing from 13-gap-register.md"
    grep -q "Typed-UNSUPPORTED with close condition (open, tokenized, 9)" "$GR" || fail "lane-13 UNSUPPORTED census line missing from 13-gap-register.md"

    # -- WIRE_PARITY carries the KD cross-reference (KD-04 token-delta note, no contradiction) --
    grep -q "KNOWN_DIVERGENCES.md" "$WP" || fail "WIRE_PARITY cross-reference to KNOWN_DIVERGENCES.md missing"
    grep -q "KD-04" "$WP" || fail "WIRE_PARITY cross-reference does not cite KD-04"

    echo "gap-sync: OK — KD register census floors hold; WIRE_PARITY census matches lane-13 (5 CLOSED-with-receipt, 9 typed-UNSUPPORTED); no contradictions."
