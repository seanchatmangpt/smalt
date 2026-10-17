# 10-gap-register-sync — DoD lane module (owned by its lane; see docs/jira/v26.10.14)

# SHIM-COURT lane hygiene: module-scope root binding (just 1.56 shebang-safe)
GAP_SYNC_ROOT := justfile_directory()

# gap-sync: re-run the audit greps and diff the gap/defect register against the lane-13 census. Exit 1 on drift.
@gap-sync:
    #!/usr/bin/env bash
    set -euo pipefail
    REPO="{{GAP_SYNC_ROOT}}"
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
    # every KD row's status cell must be OPEN (bare or annotated: "OPEN — note ...") or CLOSED*.
    # OPEN family: cell STARTS WITH "OPEN"; CLOSED family unchanged: cell must match ^CLOSED.
    # Split is backtick-aware: a `|` inside inline code is literal text, not a cell boundary.
    kd_rows() { grep -E "^\| KD-[0-9]+ \|" "$KD" | sed 's/\\|//g'; }
    status_cell() { awk '{
      n=0; in_code=0; cur="";
      for (i=1;i<=length($0);i++) { c=substr($0,i,1);
        if (c=="`") in_code=!in_code;
        else if (c=="|" && !in_code) { n++; f[n]=cur; cur="" }
        else cur=cur c }
      n++; f[n]=cur;
      cell=f[n-1]; gsub(/ /,"",cell); print cell }'; }
    bad_status=$( { kd_rows | status_cell | grep -vE '^(OPEN|CLOSED)' || true; } | head -5 )
    [ -z "$bad_status" ] || fail "KD rows with unrecognized status (must be OPEN* or CLOSED*):\n$bad_status"
    # census partition: every row counted exactly once as OPEN or CLOSED (no double counting)
    n_open=$(kd_rows | status_cell | grep -cE '^OPEN')
    n_closed=$(kd_rows | status_cell | grep -cE '^CLOSED')
    [ "$((n_open + n_closed))" -eq "$n_rows" ] || fail "KD status census does not partition: rows=$n_rows open=$n_open closed=$n_closed"
    echo "gap-sync: KD status census: rows=$n_rows OPEN=$n_open CLOSED=$n_closed"

    # -- census: 6 CLOSED-with-receipt tokens = 3 strikethrough in WIRE_PARITY + 3 CLOSED rows in C1_ARM_REST --
    #    Strikethrough tokens (receipt-backed closures, token retired):
    #    1. GAP(blob-error-envelope-json)        — v26.10.14 lane 06, receipt 06-blob-x-ms-error-code-header-absent.md
    #    2. GAP(blob-x-ms-error-code-header-absent) — CLOSED 2026-10-15, same receipt
    #    3. GAP(eventhubs-partition-metadata-absent) — CLOSED 2026-10-15, receipt s2-eh-shims.md, KD-19 closed
    closed=$(grep -oE '~~`GAP\([a-z0-9-]+\)`~~' "$WP" | sort -u | wc -l | tr -d ' ')
    [ "$closed" -eq 3 ] || fail "WIRE_PARITY strikethrough CLOSED tokens: expected 3, found $closed"
    closed_c1=$(sed -n '83,85p' "$REPO/docs/compliance/C1_ARM_REST.md" | grep -cE 'CLOSED 2026-10-15 \((lens-9 cycle-1|V261014-05)\)')
    [ "$closed_c1" -eq 3 ] || fail "C1_ARM_REST:83-85 CLOSED rows: expected 3, found $closed_c1"

    # -- WIRE_PARITY census: 8 typed-UNSUPPORTED open tokens, live GAP(...) form --
    #    Exclusions: GAP(name) meta-token + 4 receipt-backed CLOSED/struck tokens
    #    (lro-no-failed-path, blob-error-envelope-json, blob-x-ms-error-code-header-absent,
    #    eventhubs-partition-metadata-absent — CLOSED 2026-10-15, s2-eh-shims.md, KD-19).
    #    Gap-census residual fix 2026-10-16 (NEXT_WINDOW section 2): the struck
    #    eventhubs token postdated the exclusion list and inflated the live count 8->9.
    live_gap=$(grep -oE 'GAP\([a-z0-9-]+\)' "$WP" | sort -u \
      | grep -vE 'lro-no-failed-path|blob-error-envelope-json|blob-x-ms-error-code-header-absent|eventhubs-partition-metadata-absent|^GAP\(name\)$' | wc -l | tr -d ' ')
    [ "$live_gap" -eq 8 ] || fail "WIRE_PARITY typed-UNSUPPORTED GAP tokens: expected 8, found $live_gap"

    # -- register receipt census strings still on disk --
    grep -q "CLOSED-with-receipt: \`lro-no-failed-path\`" "$GR" || fail "lane-13 CLOSED census line missing from 13-gap-register.md"
    grep -q "Typed-UNSUPPORTED with close condition (open, tokenized, 9)" "$GR" || fail "lane-13 UNSUPPORTED census line missing from 13-gap-register.md"

    # -- WIRE_PARITY carries the KD cross-reference (KD-04 token-delta note, no contradiction) --
    grep -q "KNOWN_DIVERGENCES.md" "$WP" || fail "WIRE_PARITY cross-reference to KNOWN_DIVERGENCES.md missing"
    grep -q "KD-04" "$WP" || fail "WIRE_PARITY cross-reference does not cite KD-04"

    echo "gap-sync: OK — KD register census floors hold; WIRE_PARITY census matches lane-13 (6 CLOSED-with-receipt, 8 typed-UNSUPPORTED live; historical lane-13 record reads 9); no contradictions."
