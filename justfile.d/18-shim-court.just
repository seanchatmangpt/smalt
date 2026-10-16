# 18-shim-court — reusable shim-court harness (lane S-6, v26.10.14)
# Protocol + contract: scripts/shim_court/README.md

# Run one shim court by name: `just shim-court arm` -> scripts/shim_court/arm_court.sh
shim-court name:
    @bash -c '\
        court="scripts/shim_court/{{name}}_court.sh"; \
        if [ ! -f "$court" ]; then \
            echo "no court named \"{{name}}\" (scripts/shim_court/{{name}}_court.sh not found)"; \
            echo "available courts:"; \
            for f in scripts/shim_court/*_court.sh; do \
                [ -e "$f" ] || continue; \
                echo "  $(basename "$f" _court.sh)"; \
            done; \
            exit 2; \
        fi; \
        exec bash "$court"'

# Run every present shim court and summarize verdicts (PASS/FAIL/SKIP/pending).
shim-courts:
    @bash -c '\
        courts=(); \
        for f in scripts/shim_court/*_court.sh; do \
            [ -e "$f" ] || continue; courts+=("$f"); \
        done; \
        if [ ${#courts[@]} -eq 0 ]; then \
            echo "no shim courts present yet (scripts/shim_court/*_court.sh)"; \
            exit 2; \
        fi; \
        pass=0; fail=0; skip=0; failed_names=""; skipped_names=""; \
        echo "== shim-courts aggregate: ${#courts[@]} court(s) =="; \
        for c in "${courts[@]}"; do \
            name="$(basename "$c" _court.sh)"; \
            out="$(bash "$c" 2>&1)"; rc=$?; \
            printf "%s\n" "$out"; \
            case $rc in \
                0) pass=$((pass+1)); printf "  -> %s: PASS\n" "$name";; \
                1) fail=$((fail+1)); failed_names="$failed_names $name"; \
                   printf "  -> %s: FAIL\n" "$name";; \
                3) skip=$((skip+1)); skipped_names="$skipped_names $name"; \
                   printf "  -> %s: SKIP (loud, rc=3)\n" "$name";; \
                *) skip=$((skip+1)); skipped_names="$skipped_names $name"; \
                   printf "  -> %s: BLOCKED (rc=%s)\n" "$name" "$rc";; \
            esac; \
        done; \
        echo "== summary: $pass PASS, $fail FAIL, $skip SKIP =="; \
        [ -n "$failed_names" ] && echo "failed:$failed_names"; \
        [ -n "$skipped_names" ] && echo "skipped:$skipped_names"; \
        [ "$fail" -eq 0 ]'
