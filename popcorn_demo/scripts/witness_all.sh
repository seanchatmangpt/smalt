#!/usr/bin/env bash
# witness_all.sh — one-command full witness for the popcorn_demo loop
# (the loop's terminal artifact).
#
# Steps (loud, each recorded in a FAIL ledger; final exit 0 IFF all green):
#   1. substrate preflight — curl 9443; boot via `9>&- just substrate-up`
#      from the repo root if down.
#   2. blob CORS rule re-seed — the exact Set Blob Service Properties PUT
#      (?restype=service&comp=properties) with bearer minted from the
#      emulator STS (9443). Expect 202. The body carries BOTH the
#      StaticWebsite block and the <Cors> rule (parity: a PUT without a
#      Cors block clears stored rules, so the seed must carry both).
#   3. compile + full mix test under the host toolchain
#      (asdf elixir 1.20.3-otp-28, OTP 28 bin dir FIRST — erlmcp erl
#      shadow hazard). The mix test `Result` line is embedded in the
#      receipt verbatim.
#   4. cook under the runtime toolchain (OTP 29.0.6 + elixir 1.20.4-otp-29,
#      exact-match enforced by the packager) then
#      `node scripts/browser_smoke.mjs` — SMOKE_RECEIPT line + exit embedded.
#   5. `bash scripts/live_gate_court.sh` — non-vacuity court for the smoke
#      gate (exit 0 PASS / 3 loud SKIP recorded as a ledger entry).
#   6. `python3 popcorn_demo/scripts/receipt_index.py --check`.
#
# Receipt: popcorn_demo/receipts/<UTC>-witness-all.md
# Standing line: ALIVE iff all steps green; PARTIAL_ALIVE otherwise
# (with the FAIL ledger embedded). Context: full.
#
# Modes:
#   witness_all.sh            full run
#   witness_all.sh --dry-run  print the steps without executing anything
#
# Exit: 0 all green | 1 one or more FAIL ledger entries.
set -euo pipefail

REPO="${REPO:-/Users/sac/smalt}"
DEMO="$REPO/popcorn_demo"
ARM="http://127.0.0.1:9443"
EGRESS="http://127.0.0.1:8443"
TENANT="${TENANT:-witness-all}"
ACCOUNT="${ACCOUNT:-popcorn}"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

cd "$REPO"
mkdir -p "$DEMO/receipts"
STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
RECEIPT="$DEMO/receipts/$STAMP-witness-all.md"

# --- fail ledger ------------------------------------------------------------
FAILS=()
ledger() { # ledger <status> <label> <detail>
  local status="$1" label="$2" detail="$3"
  if [ "$status" = "PASS" ]; then
    echo "PASS  $label"
  else
    echo "FAIL  $label — $detail" >&2
    FAILS+=("$label: $detail")
  fi
}

# step1 preflight: probe 9443; boot the substrate if down.
step1_preflight() {
  echo "== step 1: substrate preflight =="
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY   preflight: curl -fsS $ARM/metadata/endpoints"
    echo "DRY   if down: (cd $REPO && 9>&- just substrate-up)"
    return 0
  fi
  if curl -fsS --max-time 5 "$ARM/metadata/endpoints" >/dev/null 2>&1; then
    ledger PASS "substrate-preflight" ""
    return 0
  fi
  echo "substrate down on 9443 — booting via 9>&- just substrate-up"
  if ! (cd "$REPO" && 9>&- just substrate-up) ; then
    ledger FAIL "substrate-preflight" "substrate down and substrate-up failed"
    return 1
  fi
  # Bounded readiness poll on a real observable (no-sleep law: poll, never
  # a fixed settle sleep).
  local deadline=$((SECONDS + 120)) up=0
  while [ "$SECONDS" -lt "$deadline" ]; do
    if curl -fsS --max-time 3 "$ARM/metadata/endpoints" >/dev/null 2>&1; then up=1; break; fi
    command sleep 1 # SLEEP-CLASS: POLL-STEP — bounded readiness poll
  done
  if [ "$up" -eq 1 ]; then
    ledger PASS "substrate-preflight" ""
  else
    ledger FAIL "substrate-preflight" "substrate did not become ready on 9443 within 120s"
    return 1
  fi
}

# step2: blob CORS rule re-seed (Set Blob Service Properties, 202 expected).
step2_cors_seed() {
  echo "== step 2: blob CORS rule re-seed =="
  if [ "$DRY_RUN" -eq 1 ]; then
    cat <<EOF
DRY   sts-mint: curl -sS -X POST $ARM/$TENANT/oauth2/v2.0/token \\
        -d 'grant_type=client_credentials&client_id=witness-all&client_secret=witness-all&resource=https://management.azure.com'
DRY   cors-seed: curl -sS -o /dev/null -w '%{http_code}' -X PUT \\
        "$EGRESS/$ACCOUNT?restype=service&comp=properties" \\
        -H "Authorization: Bearer <sts-token>" \\
        -H 'Content-Type: application/xml' \\
        --data-binary @<xml-file>
DRY   expected: HTTP 202 (Azure Set Service Properties parity)
DRY   xml body: StorageServiceProperties{StaticWebsite{Enabled=true,
DRY     IndexDocument=index.html, ErrorDocument404Path=404.html},
DRY     Cors{CorsRule{AllowedOrigins=*, AllowedMethods=GET,PUT,HEAD,OPTIONS,
DRY     AllowedHeaders=*, ExposedHeaders=*, MaxAgeInSeconds=3600}}}
EOF
    return 0
  fi

  local token
  token="$(curl -sS --max-time 10 -X POST "$ARM/$TENANT/oauth2/v2.0/token" \
    -d 'grant_type=client_credentials&client_id=witness-all&client_secret=witness-all&resource=https://management.azure.com' \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')" || {
    ledger FAIL "cors-seed" "STS token mint at $ARM/$TENANT/oauth2/v2.0/token failed"
    return 1
  }

  local xmlfile
  xmlfile="$(mktemp /tmp/witness-all-cors.XXXXXX)"
  cat > "$xmlfile" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<StorageServiceProperties>
  <StaticWebsite>
    <Enabled>true</Enabled>
    <IndexDocument>index.html</IndexDocument>
    <ErrorDocument404Path>404.html</ErrorDocument404Path>
  </StaticWebsite>
  <Cors>
    <CorsRule>
      <AllowedOrigins>*</AllowedOrigins>
      <AllowedMethods>GET,PUT,HEAD,OPTIONS,POST</AllowedMethods>
      <AllowedHeaders>*</AllowedHeaders>
      <ExposedHeaders>*</ExposedHeaders>
      <MaxAgeInSeconds>3600</MaxAgeInSeconds>
    </CorsRule>
  </Cors>
</StorageServiceProperties>
XML

  local code
  code="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -X PUT \
    "$EGRESS/$ACCOUNT?restype=service&comp=properties" \
    -H "Authorization: Bearer $token" \
    -H 'x-ms-version: 2021-12-02' \
    -H 'Content-Type: application/xml' \
    --data-binary @"$xmlfile")" || code="curl-error"
  rm -f "$xmlfile"
  echo "PUT $EGRESS/$ACCOUNT?restype=service&comp=properties -> $code"
  if [ "$code" = "202" ]; then
    ledger PASS "cors-seed" ""
  else
    ledger FAIL "cors-seed" "expected 202, got $code"
    return 1
  fi
}

# step3: compile + full mix test under the host toolchain (1.20.3-otp-28).
step3_compile_test() {
  echo "== step 3: compile + mix test (host toolchain 1.20.3-otp-28) =="
  local otpdir elixirdir
  otpdir="$(ls -d "$HOME"/.asdf/installs/erlang/28* 2>/dev/null | sort -V | tail -1 || true)"
  elixirdir="$HOME/.asdf/installs/elixir/1.20.3-otp-28"
  if [ -z "$otpdir" ] || [ ! -x "$elixirdir/bin/mix" ]; then
    ledger FAIL "compile-test" "host toolchain missing (asdf erlang 28* / elixir 1.20.3-otp-28)"
    return 1
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY   compile-test: PATH=$otpdir/bin:$elixirdir/bin:\$PATH mix compile && mix test (in $DEMO)"
    return 0
  fi
  echo "RUN   compile-test: mix compile && mix test (in $DEMO)"
  local out rc
  out="$(cd "$DEMO" && PATH="$otpdir/bin:$elixirdir/bin:$PATH" mix compile 2>&1 && PATH="$otpdir/bin:$elixirdir/bin:$PATH" mix test 2>&1)" && rc=0 || rc=$?
  echo "$out" > /tmp/witness-all-mix-test.log
  MIX_RESULT_LINE="$(echo "$out" | grep -E '^[0-9]+ (tests|doctests),' | tail -1 || true)"
  if [ "$rc" -ne 0 ]; then
    ledger FAIL "compile-test" "exit $rc (log: /tmp/witness-all-mix-test.log)"
    return 1
  fi
  ledger PASS "compile-test" ""
}

# step4: cook (29.0.6 toolchain) + browser smoke witness.
step4_cook_smoke() {
  echo "== step 4: cook + browser smoke (runtime toolchain 29.0.6) =="
  local otpdir elixirdir
  otpdir="$HOME/.asdf/installs/erlang/29.0.6"
  elixirdir="$HOME/.asdf/installs/elixir/1.20.4-otp-29"
  if [ ! -x "$otpdir/bin/erl" ] || [ ! -x "$elixirdir/bin/mix" ]; then
    ledger FAIL "cook-smoke" "runtime toolchain missing (~/.asdf/installs/erlang/29.0.6 / elixir 1.20.4-otp-29)"
    return 1
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY   cook: PATH=$otpdir/bin:$elixirdir/bin:\$PATH mix popcorn.cook --out-dir public/out (in $DEMO)"
    echo "DRY   smoke: node scripts/browser_smoke.mjs (in $DEMO; SMOKE_RECEIPT + exit embedded)"
    return 0
  fi
  echo "RUN   cook: mix popcorn.cook --out-dir public/out"
  local out rc
  out="$(cd "$DEMO" && PATH="$otpdir/bin:$elixirdir/bin:$PATH" mix popcorn.cook --out-dir public/out 2>&1)" && rc=0 || rc=$?
  echo "$out" > /tmp/witness-all-cook.log
  if [ "$rc" -ne 0 ]; then
    ledger FAIL "cook" "exit $rc (log: /tmp/witness-all-cook.log)"
    return 1
  fi
  ledger PASS "cook" ""

  echo "RUN   smoke: node scripts/browser_smoke.mjs"
  out="$(cd "$DEMO" && node scripts/browser_smoke.mjs 2>&1)" && rc=0 || rc=$?
  echo "$out" > /tmp/witness-all-smoke.log
  SMOKE_LINE="$(echo "$out" | grep '^SMOKE_RECEIPT:' | tail -1 || true)"
  SMOKE_EXIT="$rc"
  if [ "$rc" -eq 0 ]; then
    ledger PASS "smoke" ""
  else
    ledger FAIL "smoke" "exit $rc (log: /tmp/witness-all-smoke.log)"
  fi
  # smoke failure is recorded; later steps (court, index) still run
}

# step5: live-gate non-vacuity court.
step5_live_gate() {
  echo "== step 5: live_gate_court =="
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY   live-gate-court: bash $REPO/scripts/live_gate_court.sh"
    return 0
  fi
  [ -f "$REPO/scripts/live_gate_court.sh" ] || {
    ledger FAIL "live-gate-court" "scripts/live_gate_court.sh missing"
    return 0
  }
  local out rc
  out="$(bash "$REPO/scripts/live_gate_court.sh" 2>&1)" && rc=0 || rc=$?
  echo "$out" > /tmp/witness-all-live-gate.log
  if [ "$rc" -eq 0 ]; then
    ledger PASS "live-gate-court" ""
  else
    ledger FAIL "live-gate-court" "exit $rc (log: /tmp/witness-all-live-gate.log)"
  fi
}

# step6: receipt index check.
step6_receipt_index() {
  echo "== step 6: receipt_index --check =="
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY   receipt-index: python3 $DEMO/scripts/receipt_index.py --check"
    return 0
  fi
  local out rc
  out="$(python3 "$DEMO/scripts/receipt_index.py" --check 2>&1)" && rc=0 || rc=$?
  echo "$out" > /tmp/witness-all-receipt-index.log
  if [ "$rc" -eq 0 ]; then
    ledger PASS "receipt-index" ""
  else
    ledger FAIL "receipt-index" "exit $rc (log: /tmp/witness-all-receipt-index.log)"
  fi
}

# --- receipt writer ---------------------------------------------------------
write_receipt() {
  local standing="$1"
  {
    echo "# witness-all — one-command full witness (popcorn_demo loop)"
    echo
    echo "Standing: $standing"
    echo "Context: full"
    echo "Date: $STAMP"
    echo
    echo "## Fail ledger"
    if [ "${#FAILS[@]}" -eq 0 ]; then
      echo "none — all steps green."
    else
      printf -- "- %s\n" "${FAILS[@]}"
    fi
    echo
    echo "## mix test"
    echo '```'
    echo "${MIX_RESULT_LINE:-<not run>}"
    echo '```'
    echo
    echo "## browser smoke"
    echo '```'
    echo "EXIT=$SMOKE_EXIT"
    echo "${SMOKE_LINE:-<no SMOKE_RECEIPT line>}"
    echo '```'
    echo
    echo "## logs"
    echo "mix-test: /tmp/witness-all-mix-test.log · cook: /tmp/witness-all-cook.log · smoke: /tmp/witness-all-smoke.log · live-gate: /tmp/witness-all-live-gate.log · receipt-index: /tmp/witness-all-receipt-index.log"
  } > "$RECEIPT"
  echo "receipt: $RECEIPT"
}

# --- main -------------------------------------------------------------------
MIX_RESULT_LINE=""
SMOKE_LINE=""
SMOKE_EXIT="n/a"

step1_preflight || true   # failures land in the ledger, never abort the run
step2_cors_seed || true   # failures land in the ledger, never abort the run
step3_compile_test || true   # failures land in the ledger, never abort the run
step4_cook_smoke || true   # failures land in the ledger, never abort the run
step5_live_gate || true   # failures land in the ledger, never abort the run
step6_receipt_index || true   # failures land in the ledger, never abort the run

if [ "$DRY_RUN" -eq 1 ]; then
  echo "-- dry-run: no steps executed, no receipt written"
  exit 0
fi

if [ "${#FAILS[@]}" -eq 0 ]; then
  write_receipt "ALIVE"
  echo "ALL GREEN — witness-all standing ALIVE"
  exit 0
else
  write_receipt "PARTIAL_ALIVE"
  echo "${#FAILS[@]} step(s) failed — standing PARTIAL_ALIVE" >&2
  exit 1
fi
