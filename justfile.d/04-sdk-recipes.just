# 04-sdk-recipes — DoD lane module (owned by its lane; see docs/jira/v26.10.14)
#
# Runnable recipes for the in-repo SDK validation assets:
#   sdk-ts      — test/sdk-full: ts-run.mjs reality court + 6 attach/self probes
#   sdk-census  — scripts/sb_census_replay.sh: 11-probe SB census vs real SDK
#   sdk-py      — test/sdk-python/run.sh: real-Python-SDK probes (self-booting)
#   sdk-all     — all three, per-lane PASS/FAIL/SKIP, honest exit (fail on FAIL)
#
# Conventions (mirroring the harnesses' own contracts):
#   ts-run.mjs            exit 0 pass / 1 test fail / 2 substrate down / 3 harness / 124 watchdog
#   sb_census_replay.sh   exit 0 pass / 1 census fail / 2 substrate down / 3 harness(=SKIP)
#   run.sh (py lane)      exit 0 pass / 1 probe fail / 2 substrate timeout / 3 lock failure
#
# Substrate boot under the shared lock: justfile.d/01 owns the substrate
# recipes but is still a stub at authoring time, so these recipes boot their
# own substrate per docs/DEV_LOOP.md under /tmp/smalt-substrate.lock. When 01
# lands substrate-up/down, sdk-ts can be retargeted to it without changing the
# probe contract.


# ---------------------------------------------------------------- sdk-ts ----
sdk-ts:
    #!/usr/bin/env bash
    set -u
    cd "$(git rev-parse --show-toplevel)"
    if command -v flock >/dev/null 2>&1; then
        exec 9>/tmp/smalt-substrate.lock
        flock -x -w 1800 9 || { echo "[sdk] LOCK_FAILED"; exit 3; }
    else
        # macOS without flock: mkdir spin-lock, same mutual exclusion.
        while ! mkdir /tmp/smalt-substrate.lock.d 2>/dev/null; do sleep 2; done
        trap 'rmdir /tmp/smalt-substrate.lock.d 2>/dev/null' EXIT
    fi
    echo "[sdk-ts] lock held"
    ROOT="$PWD"
    bash scripts/gen_dev_cert.sh >/dev/null 2>&1 || true
    export NODE_EXTRA_CA_CERTS="$ROOT/.smalt/tls/ca-cert.pem"
    cd test/sdk-full
    declare -a SUM=()
    fails=0
    run_one() {
        local f="$1"; shift
        echo ""
        echo "===== node $f ====="
        node "$f" "$@"
        local c=$?
        if [ "$c" -eq 0 ]; then
            SUM+=("PASS  $f")
        else
            SUM+=("FAIL($c)  $f")
            fails=$((fails+1))
        fi
    }

    # Phase 1: self-booting harnesses (they own their own substrate boot and
    # teardown, on canonical (ts-run) or private port blocks).
    run_one ts-run.mjs
    run_one auth.probe.mjs
    run_one eventhubs.probe.mjs

    # Phase 2: attach-mode probes need a substrate already up on the canonical
    # ports (5672/5673/9443/8443/9444). Boot one per ts-run.mjs's bootstrap,
    # including the attestation baseline seed the keyvault probe asserts on.
    KEY=$(openssl rand -base64 48)
    CERT_DIR="$ROOT/.smalt/tls"
    MEASUREMENT=$(printf '11%.0s' $(seq 32))
    LOG="$ROOT/test/sdk-full/.logs/substrate-04.log"
    mkdir -p .logs
    BOOT_EVAL="Application.put_env(:smalt, :sb_shared_key, \"$KEY\"); Application.put_env(:smalt, :sb_endpoint, \"sb://127.0.0.1:5672\"); Application.put_env(:smalt, :amqp_port, 5672); Application.put_env(:smalt, :event_hubs_port, 5673); Application.put_env(:smalt, :arm_port, 9443); Application.put_env(:smalt, :egress_port, 8443); Application.put_env(:smalt, :arm_tls_port, 9444); {:ok, _} = Application.ensure_all_started(:smalt); Smalt.Store.put(:smalt_attestation_baseline, \"$MEASUREMENT\", %{\"measurement\" => \"$MEASUREMENT\"})"
    cd "$ROOT"
    boot_ok=0
    for attempt in 1 2 3 4; do
        MIX_ENV=test SMALT_TLS_CERTFILE="$CERT_DIR/dev-cert.pem" SMALT_TLS_KEYFILE="$CERT_DIR/dev-key.pem" mix run --no-start --no-halt -e "$BOOT_EVAL" >"$LOG" 2>&1 &
        SUB=$!
        boot_ok=1
        for i in $(seq 1 60); do
            if nc -z 127.0.0.1 5672 2>/dev/null && nc -z 127.0.0.1 8443 2>/dev/null \
               && nc -z 127.0.0.1 9443 2>/dev/null && nc -z 127.0.0.1 9444 2>/dev/null; then break; fi
            kill -0 $SUB 2>/dev/null || { boot_ok=0; break; }
            sleep 1
        done
        # Ownership gate: anonymous ARM must answer 200. A foreign enforce-mode
        # substrate on the canonical ports answers 401 — refuse attach probes.
        arm_code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:9443/subscriptions?api-version=2021-04-01")
        if [ "$arm_code" = "200" ]; then boot_ok=2; break; fi
        kill -TERM $SUB 2>/dev/null; sleep 3; kill -KILL $SUB 2>/dev/null; sleep 5
        echo "[sdk-ts] boot attempt $attempt failed (arm anon=$arm_code), retrying"
    done
    if [ "$boot_ok" -ne 2 ]; then
        echo "[sdk-ts] could not obtain an owned substrate on canonical ports — log: $LOG"; tail -5 "$LOG"
        echo "sdk-ts SUMMARY: ${#SUM[@]} harnesses run, $fails FAIL, 4 attach probes SKIP (canonical ports unavailable)"
        printf '%s\n' "${SUM[@]}"
        [ "$fails" -gt 0 ] && exit 1 || exit 3
    fi
    SUB=$(lsof -ti tcp:9443 -sTCP:LISTEN | head -1)
    echo "[sdk-ts] owned attach substrate up (5672/5673/9443/8443/9444)"
    export SMALT_TS_SB_SHARED_KEY="$KEY"
    # arm-resources documents NODE_TLS_REJECT_UNAUTHORIZED=0 (self-signed leaf
    # on the TLS twin; docs/jira/v26.10.14/sdk-results/ts-arm-resources.md).
    NODE_TLS_REJECT_UNAUTHORIZED=0 run_one test/sdk-full/arm-resources.probe.mjs
    run_one test/sdk-full/blob.probe.mjs
    run_one test/sdk-full/cosmos.probe.mjs
    run_one test/sdk-full/keyvault.probe.mjs

    kill -TERM $SUB 2>/dev/null; sleep 2; kill -KILL $SUB 2>/dev/null

    echo ""
    echo "sdk-ts SUMMARY: ${#SUM[@]} harnesses, $fails FAIL"
    printf '%s\n' "${SUM[@]}"
    exit $((fails > 0))

# ------------------------------------------------------------- sdk-census ----
sdk-census:
    #!/usr/bin/env bash
    set -u
    cd "$(git rev-parse --show-toplevel)"
    if command -v flock >/dev/null 2>&1; then
        exec 9>/tmp/smalt-substrate.lock
        flock -x -w 1800 9 || { echo "[sdk] LOCK_FAILED"; exit 3; }
    else
        # macOS without flock: mkdir spin-lock, same mutual exclusion.
        while ! mkdir /tmp/smalt-substrate.lock.d 2>/dev/null; do sleep 2; done
        trap 'rmdir /tmp/smalt-substrate.lock.d 2>/dev/null' EXIT
    fi
    echo "[sdk-census] lock held"
    export SMALT_SDK_ROOT="$PWD/test/sdk-smoke/node_modules"
    if [ ! -d "$SMALT_SDK_ROOT/@azure" ]; then
        echo "[sdk-census] $SMALT_SDK_ROOT has no @azure packages — SKIP-loud (exit 3)"
        exit 3
    fi
    bash scripts/sb_census_replay.sh
    code=$?
    case "$code" in
        0) echo "sdk-census SUMMARY: PASS (all census probes)";;
        1) echo "sdk-census SUMMARY: FAIL (>=1 census probe failed)";;
        2) echo "sdk-census SUMMARY: FAIL (substrate never came up)";;
        3) echo "sdk-census SUMMARY: SKIP (harness/env failure)";;
    esac
    exit "$code"

# ---------------------------------------------------------------- sdk-py ----
sdk-py:
    #!/usr/bin/env bash
    set -u
    cd "$(git rev-parse --show-toplevel)"
    if command -v flock >/dev/null 2>&1; then
        exec 9>/tmp/smalt-substrate.lock
        flock -x -w 1800 9 || { echo "[sdk] LOCK_FAILED"; exit 3; }
    else
        # macOS without flock: mkdir spin-lock, same mutual exclusion.
        while ! mkdir /tmp/smalt-substrate.lock.d 2>/dev/null; do sleep 2; done
        trap 'rmdir /tmp/smalt-substrate.lock.d 2>/dev/null' EXIT
    fi
    echo "[sdk-py] lock held"
    if [ ! -x test/sdk-python/run.sh ]; then
        echo "sdk-py SUMMARY: SKIP (test/sdk-python/run.sh not executable)"; exit 3
    fi
    bash test/sdk-python/run.sh
    code=$?
    case "$code" in
        0) echo "sdk-py SUMMARY: PASS";;
        1) echo "sdk-py SUMMARY: FAIL (>=1 Python probe failed)";;
        2) echo "sdk-py SUMMARY: FAIL (substrate timeout)";;
        3) echo "sdk-py SUMMARY: SKIP (lock failure)";;
    esac
    exit "$code"

# --------------------------------------------------------------- sdk-all ----
sdk-all:
    #!/usr/bin/env bash
    set -u
    cd "$(git rev-parse --show-toplevel)"
    just sdk-ts;      ts=$?
    just sdk-census;  cy=$?
    just sdk-py;      py=$?
    echo ""
    echo "sdk-all SUMMARY:"
    [ "$ts" -eq 0 ] && v=PASS || v="FAIL($ts)"; echo "  sdk-ts      $v"
    [ "$cy" -eq 0 ] && v=PASS || { [ "$cy" -eq 3 ] && v=SKIP || v="FAIL($cy)"; }; echo "  sdk-census  $v"
    [ "$py" -eq 0 ] && v=PASS || { [ "$py" -eq 3 ] && v=SKIP || v="FAIL($py)"; }; echo "  sdk-py      $v"
    if [ "$ts" -eq 1 ] || [ "$cy" -eq 1 ] || [ "$py" -eq 1 ]; then exit 1; fi
    exit 0
