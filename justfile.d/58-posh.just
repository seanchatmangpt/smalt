# ============================================================================
# 58-posh.just — POSH orchestration (lane L5, v26.10.30 wave).
#
# DoD verification ladder (posh-court, 7 named stages, refs POSH-006 /
# POSH-008 / docs/jira/posh/v26.10.30/working-backwards.md):
#   pre-stage: prereqs — kind boot/health/build/install (load-bearing,
#              fail-closed, not counted among the 7)
#   stage 1:   vet           (golangci-lint over posh/ + provider dir)
#   stage 2:   alloc-test    (go test -race over posh/)
#   stage 3:   build+static  (posh-build + go vet over provider dir)
#   stage 4:   fence         (go test -race ./internal/egress/... ./internal/config/...)
#   stage 5:   smalt-wire    (STS mint + wire + turnstile asserts)
#   stage 6:   tf apply      (byte-identical example root)
#   stage 7:   zero-drift    (apply -> plan -detailed-exitcode==0 pre-destroy ->
#              destroy -> residue GETs, fail-closed)
#
# Exit contract: 0 green / 1 FAIL / 3 SKIP — typed [POSH-*] lines throughout.
#
# Engineer path:
#   just posh-generate     (ggen pack synthesis; loud SKIP until packs/posh lands)
#   just posh-vet          (stage 1 standalone)
#   just posh-alloc-test   (stage 2 standalone)
#   just posh-build        (make -C posh build + Go provider build)
#   just posh-fence-test   (stage 4 standalone)
#   just posh-smalt-wire   (stage 5 standalone)
#   just posh-install      (transient TF_CLI_CONFIG_FILE rc at tmp/posh/tfrc)
#   just posh-court        (the full 7-stage ladder)
#   just posh-doctor       (Autonomous System Physician — TPS Andon + 5-Whys)
#   just posh-doctor-fix   (Autonomous System Physician with auto-heal --fix)
#   just posh-status       (report-only witness)
#   just posh-clean        (remove tmp/posh, posh/bin, adapters binary)
#
# POSHROOT: for an IMPORTED module, justfile_directory() is already the repo
# root (imports merge into the root namespace); parent_directory would
# resolve outside the repo (KROOT witness: justfile.d/52-kind.just header).
#
# Contract: docs/jira/posh/v26.10.30/working-backwards.md (verification
# ladder) + POSH-006 (courts non-vacuity) + POSH-008 (turnstile ingress).
# House style: justfile.d/52-kind.just (typed [FAIL] exits, [no-cd] shebang
# recipes) and justfile.d/57-tf-provider.just (Elixir spike — do not modify;
# this module builds the Go successor).
# ============================================================================

POSHROOT := justfile_directory()

# Identity (override via env: SMALT_POSH_*).
SMALT_POSH_META      := env_var_or_default("SMALT_POSH_META", "http://127.0.0.1:9443/metadata/endpoints?api-version=2020-01-01")
# Health anchor is the bearer-EXEMPT ARM metadata endpoint: /healthz on the ARM
# face is bearer-gated (401 AuthenticationFailed, live-witnessed) — a 200 on
# /metadata/endpoints-style metadata surface is the lawful readiness signal.
SMALT_POSH_ARM       := env_var_or_default("SMALT_POSH_ARM", "http://127.0.0.1:9443")
SMALT_POSH_TENANT    := env_var_or_default("SMALT_POSH_TENANT", "00000000-0000-0000-0000-000000000000")
SMALT_POSH_SUB       := env_var_or_default("SMALT_POSH_SUB", "00000000-0000-0000-0000-000000000000")
SMALT_POSH_CLIENT    := env_var_or_default("SMALT_POSH_CLIENT", "smalt-sovereign")
SMALT_POSH_SECRET    := env_var_or_default("SMALT_POSH_SECRET", "smalt-sovereign-mock-secret")
SMALT_POSH_PROVIDER  := env_var_or_default("SMALT_POSH_PROVIDER", "adapters/terraform-provider-smalt")
SMALT_POSH_EXAMPLE   := env_var_or_default("SMALT_POSH_EXAMPLE", "examples/basic")
SMALT_POSH_TFRC      := env_var_or_default("SMALT_POSH_TFRC", "tmp/posh/tfrc")
SMALT_POSH_PACK      := env_var_or_default("SMALT_POSH_PACK", "ggen-marketplace/packs/posh")

# ---------------------------------------------------------------------------
# Fail-closed tool check — typed error naming the install command, exit 3.
# go/terraform/kubectl/curl are the POSH ladder prerequisites.
# ---------------------------------------------------------------------------
_check_posh_tools:
    @for t in go terraform kubectl curl; do \
        command -v "$t" >/dev/null 2>&1 || { \
          echo "[POSH-PREREQ-FAIL] tool not on PATH: $t — install: brew install $t" >&2; \
          exit 3; }; \
      done; echo "[POSH-PREREQ] go/terraform/kubectl/curl present"

# posh-generate — ggen pack synthesis; loud typed SKIP (exit 3) until packs/posh lands.
[no-cd]
posh-generate: _check_posh_tools
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{POSHROOT}}
    if [ ! -f "{{SMALT_POSH_PACK}}/ontology/posh.ttl" ]; then
      echo "[POSH-GENERATE-SKIP] {{SMALT_POSH_PACK}}/ontology/posh.ttl missing — pack not landed (POSH-002 pending); loud skip" >&2
      exit 3
    fi
    # Pack manifest is pack.toml (L3 format, mirrors packs/smalt-k8s-pack);
    # ggen.toml accepted as a forward-compatible alternative.
    if [ ! -f "{{SMALT_POSH_PACK}}/pack.toml" ] && [ ! -f "{{SMALT_POSH_PACK}}/ggen.toml" ]; then
      echo "[POSH-GENERATE-SKIP] {{SMALT_POSH_PACK}} pack manifest (pack.toml|ggen.toml) missing — synthesis not wired; loud skip" >&2
      exit 3
    fi
    command -v ggen >/dev/null 2>&1 || { echo "[POSH-GENERATE-FAIL] ggen not on PATH — install per ggen-marketplace README" >&2; exit 1; }
    if ! grep -q "packs/posh" ggen.toml 2>/dev/null; then
      echo "[POSH-GENERATE-SKIP] pack not registered under repo ggen.toml [packs] — registration is coordinator-integration; loud skip" >&2
      exit 3
    fi
    # Fifth guard: zero individuals in the pack ontology means the projection
    # would be vacuous — loud skip, never a fake synthesis (KD-POSH-5).
    if [ "$(grep -c 'a posh:IngressRoute' "{{SMALT_POSH_PACK}}/ontology/posh.ttl" 2>/dev/null || true)" -eq 0 ]; then
      echo "[POSH-GENERATE-SKIP] ontology has zero individuals — projection would be vacuous (KD-POSH-5)" >&2
      exit 3
    fi
    echo "[POSH-GENERATE] running ggen sync run (cwd=pack dir; to: paths resolve from cwd — FM-WRITE-002 forbids .. traversal, so renders land in the pack's generated/ tree)"
    (cd "{{SMALT_POSH_PACK}}" && ggen sync run) \
      || { echo "[POSH-GENERATE-FAIL] ggen sync run exited nonzero over {{SMALT_POSH_PACK}}" >&2; exit 1; }
    # Copy-out integration: DISABLED until KD-POSH-5 closes. ggen's manifest
    # schema has no output-root key (FM-CONFIG-101) and no [inference] section,
    # so sync currently renders 0 rows and generated/ holds stale output
    # (witnessed: C11 2026-10-30 — written: [] twice, stale mtimes). Copying
    # that tree into the repo would break mix compile (GenStage dep absent,
    # TurnstileArm module mangling). Close condition: real render rows >
    # 0 byte-identical, rendered deps land, THEN copy-out returns here.
    echo "[POSH-GENERATE-SKIP] copy-out disabled — KD-POSH-5 open (sync renders 0 rows; generated/ is stale). Witness: C11 2026-10-30" >&2
    exit 3
    echo "[POSH-GENERATE] synthesis complete"

# posh-vet — stage 1: golangci-lint over posh/ + provider dir. SKIP (exit 3)
# when the binary or a tree's .golangci.yml is missing; FAIL (exit 1) on findings.
[no-cd]
posh-vet:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{POSHROOT}}
    if ! command -v golangci-lint >/dev/null 2>&1; then
      echo "[POSH-VET-SKIP] golangci-lint not on PATH — install: brew install golangci-lint; loud skip" >&2
      exit 3
    fi
    for d in posh "{{SMALT_POSH_PROVIDER}}"; do
      if [ ! -f "$d/.golangci.yml" ]; then
        echo "[POSH-VET-SKIP] $d/.golangci.yml missing — lint config not landed; loud skip" >&2
        exit 3
      fi
    done
    echo "[POSH-VET] golangci-lint run over posh/ + {{SMALT_POSH_PROVIDER}}"
    for d in posh "{{SMALT_POSH_PROVIDER}}"; do
      (cd "$d" && golangci-lint run ./...) \
        || { echo "[POSH-VET-FAIL] golangci-lint exited nonzero in $d" >&2; exit 1; }
      echo "[POSH-VET] PASS golangci-lint over $d"
    done

# posh-alloc-test — stage 2: go test -race over posh/.
[no-cd]
posh-alloc-test: _check_posh_tools
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{POSHROOT}}
    [ -d posh ] || { echo "[POSH-ALLOC-TEST-FAIL] posh/ tree missing — land POSH-001 first" >&2; exit 1; }
    echo "[POSH-ALLOC-TEST] go test -race ./... over posh/"
    (cd posh && go test -race ./...) \
      || { echo "[POSH-ALLOC-TEST-FAIL] go test -race exited nonzero over posh/" >&2; exit 1; }
    echo "[POSH-ALLOC-TEST] PASS go test -race ./... (posh/)"

# posh-build — make -C posh build + Go provider build; fail-closed typed errors.
[no-cd]
posh-build: _check_posh_tools
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{POSHROOT}}
    [ -d posh ] || { echo "[POSH-BUILD-FAIL] posh/ tree missing — land POSH-001 first" >&2; exit 1; }
    [ -f posh/Makefile ] || { echo "[POSH-BUILD-FAIL] posh/Makefile missing — land POSH-001 build entrypoint first" >&2; exit 1; }
    make -C posh build \
      || { echo "[POSH-BUILD-FAIL] make -C posh build exited nonzero" >&2; exit 1; }
    echo "[POSH-BUILD] posh core built"
    [ -d "{{SMALT_POSH_PROVIDER}}" ] || { echo "[POSH-BUILD-FAIL] {{SMALT_POSH_PROVIDER}}/ tree missing — land POSH-004 first" >&2; exit 1; }
    [ -f "{{SMALT_POSH_PROVIDER}}/main.go" ] || { echo "[POSH-BUILD-FAIL] {{SMALT_POSH_PROVIDER}}/main.go missing — land POSH-004 first" >&2; exit 1; }
    (cd "{{SMALT_POSH_PROVIDER}}" && go build -o terraform-provider-azurerm .) \
      || { echo "[POSH-BUILD-FAIL] go build exited nonzero in {{SMALT_POSH_PROVIDER}}" >&2; exit 1; }
    echo "[POSH-BUILD] Go provider built: {{SMALT_POSH_PROVIDER}}/terraform-provider-azurerm"

# posh-fence-test — stage 4: go test -race over the egress+config fence packages.
[no-cd]
posh-fence-test: _check_posh_tools
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{POSHROOT}}
    [ -d posh/internal/egress ] && [ -d posh/internal/config ] \
      || { echo "[POSH-FENCE-TEST-FAIL] posh/internal/{egress,config} missing — land POSH-001 first" >&2; exit 1; }
    echo "[POSH-FENCE-TEST] go test -race over egress+config fence packages"
    (cd posh && go test -race ./internal/egress/... ./internal/config/...) \
      || { echo "[POSH-FENCE-TEST-FAIL] go test -race exited nonzero over egress+config fence packages" >&2; exit 1; }
    echo "[POSH-FENCE-TEST] PASS egress+config fence packages"

# posh-install — transient dev_overrides rc at tmp/posh/tfrc; NEVER touches ~/.terraformrc.
[no-cd]
posh-install: _check_posh_tools
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{POSHROOT}}
    bin="{{SMALT_POSH_PROVIDER}}/terraform-provider-azurerm"
    [ -x "$bin" ] || { echo "[POSH-INSTALL-FAIL] $bin not built — run: just posh-build" >&2; exit 1; }
    mkdir -p tmp/posh
    # NOTE: printf not heredoc — just ends the recipe at an unbalanced `{`
    # line (witnessed: heredoc form failed just parse at the brace).
    printf '%s\n' \
      'provider_installation {' \
      '  dev_overrides {' \
      '    "hashicorp/azurerm" = "{{POSHROOT}}/{{SMALT_POSH_PROVIDER}}"' \
      '  }' \
      '  direct {' \
      '    exclude = ["hashicorp/azurerm"]' \
      '  }' \
      '}' > "{{SMALT_POSH_TFRC}}"
    echo "[POSH-INSTALL] transient rc written: {{SMALT_POSH_TFRC}} (~/.terraformrc untouched)"
    echo "export TF_CLI_CONFIG_FILE=\"{{POSHROOT}}/{{SMALT_POSH_TFRC}}\""

# posh-smalt-wire — stage 5: STS bearer mint + resourcegroup/containerApps wire
# asserts + turnstile assert: an authenticated ARM GET with `curl -D -` must
# present the X-Smalt-Receipt-Turnstile response header, fail-closed if absent.
# SKIP (exit 3) when the substrate is down; FAIL (exit 1) on any assert.
[no-cd]
posh-smalt-wire: _check_posh_tools
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{POSHROOT}}
    if ! curl -fsS --max-time 2 "{{SMALT_POSH_META}}" >/dev/null 2>&1; then
      echo "[POSH-SMALT-WIRE-SKIP] substrate not answering {{SMALT_POSH_META}} — boot with: just substrate-up; loud skip" >&2
      exit 3
    fi
    arm="{{SMALT_POSH_ARM}}"
    sub="{{SMALT_POSH_SUB}}"
    tok=$(curl -fsS --max-time 5 -X POST "$arm/smalt/oauth2/v2.0/token" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode 'grant_type=client_credentials' \
      --data-urlencode 'client_id={{SMALT_POSH_CLIENT}}' \
      --data-urlencode 'client_secret={{SMALT_POSH_SECRET}}' \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])') \
      || { echo "[POSH-SMALT-WIRE-FAIL] STS bearer mint at $arm/smalt/oauth2/v2.0/token" >&2; exit 1; }
    [ -n "$tok" ] || { echo "[POSH-SMALT-WIRE-FAIL] STS returned empty access_token" >&2; exit 1; }
    rg=$(curl -fsS --max-time 5 -H "Authorization: Bearer $tok" \
      "$arm/subscriptions/$sub/resourcegroups?api-version=2021-04-01") \
      || { echo "[POSH-SMALT-WIRE-FAIL] GET resourcegroups" >&2; exit 1; }
    ca=$(curl -fsS --max-time 5 -H "Authorization: Bearer $tok" \
      "$arm/subscriptions/$sub/providers/Microsoft.App/containerApps?api-version=2024-03-01") \
      || { echo "[POSH-SMALT-WIRE-FAIL] GET containerApps" >&2; exit 1; }
    echo "$rg" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("value"), "no resourcegroups"' \
      || { echo "[POSH-SMALT-WIRE-FAIL] resourcegroups empty — wire did not materialize" >&2; exit 1; }
    echo "$ca" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("value"), "no containerApps"' \
      || { echo "[POSH-SMALT-WIRE-FAIL] containerApps empty — wire did not materialize" >&2; exit 1; }
    # Turnstile assert: header dump (-D -) of an authenticated ARM GET must
    # carry X-Smalt-Receipt-Turnstile (POSH-008); fail-closed when absent.
    hdr=$(curl -fsS -D - -o /dev/null --max-time 5 -H "Authorization: Bearer $tok" \
      "$arm/subscriptions/$sub/resourcegroups?api-version=2021-04-01") \
      || { echo "[POSH-SMALT-WIRE-FAIL] header-dump GET resourcegroups" >&2; exit 1; }
    echo "$hdr" | grep -qi '^x-smalt-receipt-turnstile:' \
      || { echo "[POSH-SMALT-WIRE-FAIL] X-Smalt-Receipt-Turnstile header absent on authenticated ARM GET — turnstile ingress (POSH-008) not enforced; fail-closed" >&2; exit 1; }
    echo "[POSH-SMALT-WIRE] PASS mint -> wire asserts -> turnstile header present"

# posh-court — DoD 7-stage ladder. Exit contract: 0 green / 1 FAIL / 3 SKIP.
# Pre-stage (load-bearing, uncounted): kind boot/health/build/install.
[no-cd]
posh-court: _check_posh_tools
    #!/usr/bin/env bash
    set -uo pipefail
    cd {{POSHROOT}}
    pass=0
    skip=0
    fail=0
    example="{{SMALT_POSH_PROVIDER}}/{{SMALT_POSH_EXAMPLE}}"
    tfrc="{{POSHROOT}}/{{SMALT_POSH_TFRC}}"

    stage() { echo "[POSH-COURT-$1] $2"; }
    tally() {
      echo "[POSH-COURT] result: $pass/8 PASS, $skip SKIP, $fail FAIL"
    }

    # ---- Pre-stage: kind boot + cluster + images + swarm deploy ------------
    # The hand-written manifest pins image smalt:local — 52-kind's default
    # BACKEND_IMG is smalt:hermetic, so pin the tag the deployable expects
    # (witnessed: ErrImageNeverPull smalt-backend-0 with default env).
    export SMALT_KIND_BACKEND_IMG=smalt:local
    if just kind-up kind-images kind-deploy; then
      echo "[POSH-COURT-PRE] PASS kind ladder (kind-up/kind-images/kind-deploy)"
    else
      rc=$?
      fail=1
      tally
      echo "[POSH-COURT-PRE] FAIL kind ladder exited $rc — witness: just kind-status" >&2
      exit 1
    fi

    # ---- Pre-stage: health assert — bounded poll 60x1s on metadata anchor --
    echo "[POSH-COURT-PRE] polling metadata anchor {{SMALT_POSH_META}} (bounded 60x1s; /healthz is bearer-gated 401)"
    ok=0
    for i in $(seq 1 60); do
      if curl -fsS --max-time 2 "{{SMALT_POSH_META}}" >/dev/null 2>&1; then
        ok=1; echo "[POSH-COURT-PRE] PASS metadata anchor 200 after ${i} poll(s)"; break
      fi
      sleep 1
    done
    if [ "$ok" != 1 ]; then
      fail=1
      tally
      echo "[POSH-COURT-PRE] FAIL metadata anchor never answered 200 within 60s — witness: just kind-status" >&2
      exit 1
    fi

    # ---- Pre-stage: build + install (transient dev_overrides rc) -----------
    if just posh-build; then
      echo "[POSH-COURT-PRE] PASS posh-build"
    else
      fail=1; tally; echo "[POSH-COURT-PRE] FAIL posh-build exited nonzero" >&2; exit 1
    fi
    mkdir -p tmp/posh
    if just posh-install >tmp/posh/install.out 2>&1; then
      echo "[POSH-COURT-PRE] PASS posh-install (rc at {{SMALT_POSH_TFRC}})"
    else
      cat tmp/posh/install.out >&2 || true
      fail=1; tally; echo "[POSH-COURT-PRE] FAIL posh-install exited nonzero" >&2; exit 1
    fi
    export TF_CLI_CONFIG_FILE="$tfrc"

    # ---- Stage 1: vet -------------------------------------------------------
    if just posh-vet; then
      pass=$((pass+1)); stage 1 "PASS vet (golangci-lint posh/ + provider)"
    else
      rc=$?
      if [ "$rc" = 3 ]; then
        skip=$((skip+1)); stage 1 "SKIP golangci-lint or .golangci.yml not landed"
      else
        fail=$((fail+1)); stage 1 "FAIL vet exited $rc"; tally; exit 1
      fi
    fi

    # ---- Stage 2: alloc-test ------------------------------------------------
    if just posh-alloc-test; then
      pass=$((pass+1)); stage 2 "PASS alloc-test (go test -race posh/)"
    else
      fail=$((fail+1)); stage 2 "FAIL alloc-test exited nonzero"; tally; exit 1
    fi

    # ---- Stage 3: static (go vet over provider dir; build done pre-stage) ---
    if (cd "{{SMALT_POSH_PROVIDER}}" && go vet ./...); then
      pass=$((pass+1)); stage 3 "PASS static (go vet over {{SMALT_POSH_PROVIDER}})"
    else
      fail=$((fail+1)); stage 3 "FAIL go vet exited nonzero over {{SMALT_POSH_PROVIDER}}"; tally; exit 1
    fi

    # ---- Stage 4: fence -----------------------------------------------------
    if just posh-fence-test; then
      pass=$((pass+1)); stage 4 "PASS fence (egress+config -race)"
    else
      fail=$((fail+1)); stage 4 "FAIL fence exited nonzero"; tally; exit 1
    fi

    # ---- Stage 5: smalt-wire ------------------------------------------------
    if just posh-smalt-wire; then
      pass=$((pass+1)); stage 5 "PASS smalt-wire (mint + wire + turnstile)"
    else
      rc=$?
      if [ "$rc" = 3 ]; then
        skip=$((skip+1)); stage 5 "SKIP substrate not answering"
      else
        fail=$((fail+1)); stage 5 "FAIL smalt-wire exited $rc (wire or turnstile assert)"; tally; exit 1
      fi
    fi

    # ---- Stage 6: terraform apply of the byte-identical example root --------
    if [ ! -d "$example" ]; then
      skip=$((skip+2))
      stage 6 "SKIP example root $example not landed — byte-identical HCL pending; stage 7 depends on it"
      stage 7 "SKIP (depends on stage 6)"
      tally
      exit 3
    fi
    if (cd "$example" \
      && terraform init -input=false \
      && terraform apply -auto-approve -input=false); then
      pass=$((pass+1)); stage 6 "PASS terraform apply"
    else
      fail=$((fail+1)); stage 6 "FAIL terraform apply exited nonzero in $example"; tally; exit 1
    fi

    # ---- Stage 7: zero-drift — ordered plan(detailed-exitcode==0, pre-destroy)
    #      -> destroy -> residue GETs, all fail-closed -------------------------
    pex=0
    (cd "$example" && terraform plan -detailed-exitcode -input=false >/dev/null) || pex=$?
    if [ "$pex" != 0 ]; then
      fail=$((fail+1)); stage 7 "FAIL plan -detailed-exitcode=$pex (0 required — drift or error)"; tally; exit 1
    fi
    stage 7 "plan -detailed-exitcode 0 pre-destroy — no drift"
    if ! (cd "$example" && terraform destroy -auto-approve -input=false); then
      fail=$((fail+1)); stage 7 "FAIL terraform destroy exited nonzero"; tally; exit 1
    fi
    tok=$(curl -fsS --max-time 5 -X POST "{{SMALT_POSH_ARM}}/smalt/oauth2/v2.0/token" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode 'grant_type=client_credentials' \
      --data-urlencode 'client_id={{SMALT_POSH_CLIENT}}' \
      --data-urlencode 'client_secret={{SMALT_POSH_SECRET}}' \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])') \
      || { fail=$((fail+1)); stage 7 "FAIL residue STS mint failed"; tally; exit 1; }
    rg2=$(curl -fsS --max-time 5 -H "Authorization: Bearer $tok" \
      "{{SMALT_POSH_ARM}}/subscriptions/{{SMALT_POSH_SUB}}/resourcegroups?api-version=2021-04-01") \
      || { fail=$((fail+1)); stage 7 "FAIL residue GET failed — cannot prove zero residue"; tally; exit 1; }
    ca2=$(curl -fsS --max-time 5 -H "Authorization: Bearer $tok" \
      "{{SMALT_POSH_ARM}}/subscriptions/{{SMALT_POSH_SUB}}/providers/Microsoft.App/containerApps?api-version=2024-03-01") \
      || { fail=$((fail+1)); stage 7 "FAIL residue GET failed — cannot prove zero residue"; tally; exit 1; }
    echo "$rg2" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert not d.get("value"), d["value"]' \
      || { fail=$((fail+1)); stage 7 "FAIL residue: resourcegroups non-empty after destroy"; tally; exit 1; }
    echo "$ca2" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert not d.get("value"), d["value"]' \
      || { fail=$((fail+1)); stage 7 "FAIL residue: containerApps non-empty after destroy"; tally; exit 1; }
    pass=$((pass+1))
    stage 7 "PASS zero-drift (plan 0 pre-destroy -> destroy -> zero residue)"

    # ---- Stage 8: mutation non-vacuity — the court must be able to flip ------
    # Runs the real tamper-reject legs: a 1-bit payload flip must fail
    # VerifyTurnstile, and the HTTP envelope test must verify the receipt for
    # real. If verification regresses to rubber-stamp, these tests fail and
    # the court goes RED — the flip IS the proof the court is not vacuous.
    if (cd posh && go test -race -count=1 \
      -run 'TestHTTPEnvelopeOverTCPListener|TestVerifyTurnstile' \
      ./internal/server/ ./internal/receipt/); then
      pass=$((pass+1)); stage 8 "PASS mutation non-vacuity (tamper-reject legs green)"
    else
      fail=$((fail+1)); stage 8 "FAIL mutation legs failed — receipt verification regressed"; tally; exit 1
    fi

    tally
    echo "[POSH-COURT] ALIVE"
    exit 0

# posh-doctor — Autonomous System Physician (TPS Andon + 5-Whys diagnostics).
[no-cd]
posh-doctor:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{POSHROOT}}
    if [ ! -x posh/bin/posh ]; then
      make -C posh build
    fi
    ./posh/bin/posh doctor -config posh/posh.yaml -repo-root "{{POSHROOT}}"

# posh-doctor-fix — Autonomous System Physician with Jidoka auto-heal (--fix).
[no-cd]
posh-doctor-fix:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{POSHROOT}}
    if [ ! -x posh/bin/posh ]; then
      make -C posh build
    fi
    ./posh/bin/posh doctor -config posh/posh.yaml -repo-root "{{POSHROOT}}" -fix

# posh-status — report-only witness, exit 0 always.
[no-cd]
posh-status:
    #!/usr/bin/env bash
    set -uo pipefail
    cd {{POSHROOT}}
    echo "[POSH-STATUS] posh core:"
    [ -f posh/Makefile ] && echo "  Makefile present" || echo "  posh/Makefile absent — POSH-001 pending"
    [ -d posh/bin ] && ls posh/bin 2>/dev/null | sed 's/^/  bin\//' || true
    echo "[POSH-STATUS] Go provider:"
    bin="{{SMALT_POSH_PROVIDER}}/terraform-provider-azurerm"
    [ -x "$bin" ] && echo "  built: $bin ($(du -h "$bin" | cut -f1))" \
      || echo "  not built — run: just posh-build"
    [ -f "{{SMALT_POSH_TFRC}}" ] && echo "[POSH-STATUS] transient rc: {{SMALT_POSH_TFRC}}" \
      || echo "[POSH-STATUS] transient rc absent — run: just posh-install"
    [ -d "{{SMALT_POSH_PROVIDER}}/{{SMALT_POSH_EXAMPLE}}" ] \
      && echo "[POSH-STATUS] example root present: {{SMALT_POSH_PROVIDER}}/{{SMALT_POSH_EXAMPLE}}" \
      || echo "[POSH-STATUS] example root absent — posh-court stages 6-7 will loud-skip"
    curl -fsS --max-time 2 "{{SMALT_POSH_META}}" 2>/dev/null \
      && echo "[POSH-STATUS] metadata anchor OK ({{SMALT_POSH_META}})" \
      || echo "[POSH-STATUS] metadata anchor not answering / bearer-gated ({{SMALT_POSH_META}})"

# posh-image — build minimal static container image smalt/posh:latest.
[no-cd]
posh-image:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{POSHROOT}}
    docker build -t smalt/posh:latest -f docker/Dockerfile.posh .
    echo "[POSH-IMAGE] built smalt/posh:latest"

# posh-mutation-court — POSH-006 non-vacuity mutation court.
[no-cd]
posh-mutation-court:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{POSHROOT}}
    python3 scripts/posh_mutation_court.py

# posh-coverage — POSH-009 surface coverage compiler and divergence checker.
[no-cd]
posh-coverage:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{POSHROOT}}
    python3 scripts/posh_coverage.py

# posh-clean — remove tmp/posh, posh/bin, adapters binary; idempotent.
[no-cd]
posh-clean:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{POSHROOT}}
    rm -rf tmp/posh posh/bin "{{SMALT_POSH_PROVIDER}}/terraform-provider-azurerm"
    echo "[POSH-CLEAN] removed tmp/posh, posh/bin, {{SMALT_POSH_PROVIDER}}/terraform-provider-azurerm"

# posh-andon — run the POSH andon driver help (F8 lane addition).
[no-cd]
posh-andon:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{POSHROOT}}/posh
    go run ./cmd/andon -help
