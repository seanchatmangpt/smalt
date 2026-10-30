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
# SLA runner (GAP09 G1, gaps/31-sla-clocks.md): every stage runs under
# run_with_sla (scripts/posh_sla.sh) — per-gate hard timeout, expiry = kill +
# RED + andon JSONL receipt (tmp/posh/andon.jsonl); unregistered/empty SLA =
# refusal exit 2. Fixture: just posh-court-sla-test.
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
    # Fifth guard: SPARQL invariant gate (G27/G40) — every
    # queries/invariant_*.rq MUST be empty over ontology/posh.ttl +
    # examples/posh_instance.ttl before anything renders. Exit 0 clean /
    # 1 typed violation rows / 2 infra (incl. zero-queries loud vacuity).
    # Runs BEFORE ggen sync run: bad graphs never render. (The prior
    # grep individual-count guard is superseded — ggen sync's render-rows>0
    # non-vacuity check below still covers the zero-A-box case, exit 1.)
    if ! python3 scripts/posh_invariant_gate.py; then
      echo "[POSH-GENERATE-FAIL] invariant gate over {{SMALT_POSH_PACK}} failed (exit $?)" >&2
      exit 1
    fi
    echo "[POSH-GENERATE] running ggen sync run (cwd=pack dir; to: paths resolve from cwd - FM-WRITE-002 forbids .. traversal, so renders land in the pack's generated/ tree)"
    sync_out=$(cd "{{SMALT_POSH_PACK}}" && ggen sync run --format json 2>/dev/null) \
      || { echo "[POSH-GENERATE-FAIL] ggen sync run exited nonzero over {{SMALT_POSH_PACK}}" >&2; exit 1; }
    # Non-vacuity: the sync must actually render rows. written + skipped
    # outputs together are the render-row witness; both empty = 0 rows.
    rows=$(printf '%s' "$sync_out" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d.get("written",[]))+len(d.get("skipped",[])))') \
      || { echo "[POSH-GENERATE-FAIL] could not parse ggen sync JSON" >&2; exit 1; }
    if [ "$rows" -eq 0 ]; then
      echo "[POSH-GENERATE-FAIL] ggen sync rendered 0 rows (written+skipped empty) - KD-POSH-5 regression" >&2
      exit 1
    fi
    echo "[POSH-GENERATE] render rows>0 (written+skipped=$rows) - KD-POSH-5 close condition met"
    # Copy-out integration (KD-POSH-5 CLOSED, F12 lane 2026-10-30): the pack
    # now renders real rows from examples/posh_instance.ttl, so the renders
    # integrate into the repo: pipeline modules to lib/, the Go adapter to
    # posh/internal/adapter/.
    mkdir -p lib/smalt/posh/pipeline posh/internal/adapter
    cp "{{SMALT_POSH_PACK}}/generated/lib/smalt/posh/pipeline/"*.ex lib/smalt/posh/pipeline/ \
      || { echo "[POSH-GENERATE-FAIL] copy-out of pipeline modules failed" >&2; exit 1; }
    rm -f posh/internal/adapter/generated_adapters.go
    cp "{{SMALT_POSH_PACK}}/generated/posh/internal/adapter/"*.go posh/internal/adapter/ \
      || { echo "[POSH-GENERATE-FAIL] copy-out of generated Go adapters failed" >&2; exit 1; }
    echo "[POSH-GENERATE] copy-out complete: lib/smalt/posh/pipeline/*.ex + posh/internal/adapter/*.go"
    # Compile gate: the rendered modules must compile (fix the TEMPLATE,
    # never the output, on failure). Isolated build root per lane law.
    # Pinned toolchain per .tool-versions (elixir 1.20.4-otp-29, erlang 29.1.2);
    # asdf shims are not on the recipe PATH, so prepend the install bins.
    export PATH="$HOME/.asdf/installs/erlang/29.1.2/bin:$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH"
    MIX_BUILD_ROOT=_build-f12 mix compile \
      || { echo "[POSH-GENERATE-FAIL] mix compile failed over rendered pipeline modules - fix the template, not the output" >&2; exit 1; }
    echo "[POSH-GENERATE] synthesis complete"
# Usage: just posh-vet — stage 1; SKIP (exit 3) when the binary or a tree's
# .golangci.yml is missing; FAIL (exit 1) on findings.

# posh-vet — stage 1 lint: golangci-lint over posh/ + provider dir.
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

# Usage: just posh-smalt-wire — stage 5: STS bearer mint + resourcegroup/
# containerApps wire asserts + turnstile assert (an authenticated ARM GET with
# `curl -D -` must present the X-Smalt-Receipt-Turnstile response header,
# fail-closed if absent). SKIP (exit 3) when the substrate is down; FAIL
# (exit 1) on any assert.

# posh-smalt-wire — stage 5 wire court: STS mint + wire asserts + turnstile.
[no-cd]
posh-smalt-wire: _check_posh_tools
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{POSHROOT}}
    if ! curl -fsS --max-time 2 "{{SMALT_POSH_META}}" >/dev/null 2>&1; then
      echo "[POSH-SMALT-WIRE-SKIP] substrate not answering {{SMALT_POSH_META}} — boot with: just kind-up && just kind-images && just kind-deploy; loud skip" >&2
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
    # Turnstile asserts (G26 close, lane 39): (1) header presence on an
    # authenticated ARM GET; (2) the FENCE: an unreceipted mutating delta
    # (non-object JSON body) is refused with a typed 400 AdmissionRefused
    # that still carries the stamped header. Fail-closed on either.
    hdr=$(curl -fsS -D - -o /dev/null --max-time 5 -H "Authorization: Bearer $tok" \
      "$arm/subscriptions/$sub/resourcegroups?api-version=2021-04-01") \
      || { echo "[POSH-SMALT-WIRE-FAIL] header-dump GET resourcegroups" >&2; exit 1; }
    echo "$hdr" | grep -qi '^x-smalt-receipt-turnstile:' \
      || { echo "[POSH-SMALT-WIRE-FAIL] X-Smalt-Receipt-Turnstile header absent on authenticated ARM GET — turnstile stamp missing; fail-closed" >&2; exit 1; }
    fence_code=$(curl -sS -o /tmp/posh-fence-body.json -w '%{http_code}' --max-time 5 \
      -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d '[]' \
      "$arm/subscriptions/$sub/resourcegroups/rg-fence-probe?api-version=2021-04-01") \
      || { echo "[POSH-SMALT-WIRE-FAIL] fence-probe POST resourcegroups" >&2; exit 1; }
    [ "$fence_code" = "400" ] \
      || { echo "[POSH-SMALT-WIRE-FAIL] unreceipted mutating delta NOT refused (got $fence_code, want 400) — turnstile fence not enforced; fail-closed" >&2; exit 1; }
    grep -q 'AdmissionRefused' /tmp/posh-fence-body.json \
      || { echo "[POSH-SMALT-WIRE-FAIL] fence 400 body is not a typed AdmissionRefused envelope; fail-closed" >&2; exit 1; }
    echo "[POSH-SMALT-WIRE] PASS mint -> wire asserts -> turnstile stamp + fence refusal"

# Usage: just posh-court — the full DoD ladder (~10-20 min typical). Exit
# contract: 0 green / 1 FAIL / 3 SKIP. Pre-stage (load-bearing, uncounted):
# kind boot/health/build/install.

# posh-court — DoD 7-stage verification ladder (vet .. zero-drift).
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
    source "{{POSHROOT}}/scripts/posh_sla.sh"

    stage() { echo "[POSH-COURT-$1] $2"; }
    tally() {
      echo "[POSH-COURT] result: $pass/9 PASS, $skip SKIP, $fail FAIL"
    }

    # ---- Andon wiring (G28 §4, lane 41) ----------------------------------
    # subject_sha captured ONCE at court start: every emitted row in one
    # invocation carries the same value (the latch binds RED to that SHA).
    # emit-once law (G28 §2): each gate name is emitted at most once per
    # court invocation — stage retries must re-invoke the court, never
    # re-emit into the same batch.
    subject_sha="$(git rev-parse HEAD)"
    results="tmp/posh/gate-results.jsonl"
    mkdir -p tmp/posh
    : > "$results"

    # emit <gate> <pass|fail> <reason> — append one gate-result row
    # (driver stdin shape, cmd/andon gateInput). SKIPped stages emit
    # NOTHING for their gate: a fabricated pass would print GREEN the
    # stage never earned; the typed [POSH-COURT-n] SKIP console line is
    # the skip witness. (Once the explicit-outcome feed lands in the
    # recipe, skip may be emitted as {"outcome":"skip"} — a HOLD, not a
    # pass.)
    emit() {
      local g="$1" o="$2" r="$3"
      GATE_EMIT_GATE="$g" GATE_EMIT_OUTCOME="$o" GATE_EMIT_SHA="$subject_sha" GATE_EMIT_REASON="$r" python3 -c 'import json,os; print(json.dumps({"gate":os.environ["GATE_EMIT_GATE"],"pass":os.environ["GATE_EMIT_OUTCOME"]!="fail","sla_met":os.environ["GATE_EMIT_OUTCOME"]!="timeout","subject_sha":os.environ["GATE_EMIT_SHA"],"reason":os.environ["GATE_EMIT_REASON"]}))' >> "$results" \
        || echo "[POSH-COURT] WARN emit failed for gate $g (row lost)" >&2
    }

    # finish <court_rc> — pipe gate results through the REAL andon driver
    # and exit. Court rc ANDs with the andon composite: andon RED (1) or
    # BLOCKED (2) demotes the court to 1; andon GREEN never upgrades a
    # failing court (AND, not OR).
    finish() {
      local court_rc="$1" arc=0
      if [ -s "$results" ]; then
        (cd posh && go run ./cmd/andon -receipts var/andon.jsonl < "../$results")
        arc=$?
        if [ "$arc" = 1 ]; then
          echo "[POSH-COURT] ANDON RED — line halted (latched on $subject_sha)"
          court_rc=1
        elif [ "$arc" = 2 ]; then
          echo "[POSH-COURT] ANDON BLOCKED (driver/infra error rc=2)"
          court_rc=1
        fi
      fi
      exit "$court_rc"
    }

    # ---- Pre-stage: kind boot + cluster + images + swarm deploy ------------
    # The hand-written manifest pins image smalt:local — 52-kind's default
    # BACKEND_IMG is smalt:hermetic, so pin the tag the deployable expects
    # (witnessed: ErrImageNeverPull smalt-backend-0 with default env).
    export SMALT_KIND_BACKEND_IMG=smalt:local
    if run_with_sla infra just kind-up kind-images kind-deploy; then
      echo "[POSH-COURT-PRE] PASS kind ladder (kind-up/kind-images/kind-deploy)"
    else
      rc=$?
      fail=1
      tally
      echo "[POSH-COURT-PRE] FAIL kind ladder exited $rc — witness: just kind-status" >&2
      emit preflight fail "kind ladder exited $rc — witness: just kind-status"
      finish 1
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
      emit preflight fail "metadata anchor never answered 200 within 60s"
      finish 1
    fi
    emit preflight pass "kind ladder + metadata anchor 200"

    # ---- Pre-stage: build + install (transient dev_overrides rc) -----------
    if run_with_sla build just posh-build; then
      echo "[POSH-COURT-PRE] PASS posh-build"
    else
      fail=1; tally; echo "[POSH-COURT-PRE] FAIL posh-build exited nonzero" >&2
      emit build fail "posh-build exited nonzero"; finish 1
    fi
    mkdir -p tmp/posh
    if just posh-install >tmp/posh/install.out 2>&1; then
      echo "[POSH-COURT-PRE] PASS posh-install (rc at {{SMALT_POSH_TFRC}})"
    else
      cat tmp/posh/install.out >&2 || true
      fail=1; tally; echo "[POSH-COURT-PRE] FAIL posh-install exited nonzero" >&2
      emit build fail "posh-install exited nonzero"; finish 1
    fi
    emit build pass "posh-build + posh-install"
    export TF_CLI_CONFIG_FILE="$tfrc"

    # ---- Stage 0: invariant — SPARQL invariants over the pack graph ---------
    if SMALT_POSH_PACK="{{SMALT_POSH_PACK}}" python3 scripts/posh_invariant_gate.py; then
      pass=$((pass+1)); stage 0 "PASS invariant ({{SMALT_POSH_PACK}} queries/invariant_*.rq all empty)"; emit invariant pass "invariant_*.rq all empty"
    else
      rc=$?
      if [ "$rc" = 3 ]; then
        skip=$((skip+1)); stage 0 "SKIP pack graph or queries not landed"
      else
        fail=$((fail+1)); stage 0 "FAIL invariant gate exited $rc (1=violation rows / 2=infra or vacuous)"; tally
        emit invariant fail "invariant gate exited $rc"; finish 1
      fi
    fi

    # ---- Stage 1: vet -------------------------------------------------------
    if run_with_sla vet just posh-vet; then
      pass=$((pass+1)); stage 1 "PASS vet (golangci-lint posh/ + provider)"; emit vet pass "golangci-lint posh/ + provider"
    else
      rc=$?
      if [ "$rc" = 3 ]; then
        skip=$((skip+1)); stage 1 "SKIP golangci-lint or .golangci.yml not landed"
      else
        fail=$((fail+1)); stage 1 "FAIL vet exited $rc"; tally
        emit vet fail "vet exited $rc"; finish 1
      fi
    fi

    # ---- Stage 2: alloc-test ------------------------------------------------
    if run_with_sla alloc-test just posh-alloc-test; then
      pass=$((pass+1)); stage 2 "PASS alloc-test (go test -race posh/)"; emit alloc-test pass "go test -race posh/"
    else
      fail=$((fail+1)); stage 2 "FAIL alloc-test exited nonzero"; tally
      emit alloc-test fail "alloc-test exited nonzero"; finish 1
    fi

    # ---- Stage 3: static (go vet over provider dir; build done pre-stage) ---
    if run_with_sla static bash -c 'cd "{{SMALT_POSH_PROVIDER}}" && go vet ./...'; then
      pass=$((pass+1)); stage 3 "PASS static (go vet over {{SMALT_POSH_PROVIDER}})"; emit static pass "go vet over {{SMALT_POSH_PROVIDER}}"
    else
      fail=$((fail+1)); stage 3 "FAIL go vet exited nonzero over {{SMALT_POSH_PROVIDER}}"; tally
      emit static fail "go vet exited nonzero over {{SMALT_POSH_PROVIDER}}"; finish 1
    fi

    # ---- Stage 4: fence -----------------------------------------------------
    if run_with_sla fence just posh-fence-test; then
      pass=$((pass+1)); stage 4 "PASS fence (egress+config -race)"; emit fence pass "egress+config -race"
    else
      fail=$((fail+1)); stage 4 "FAIL fence exited nonzero"; tally
      emit fence fail "fence exited nonzero"; finish 1
    fi

    # ---- Stage 5: smalt-wire ------------------------------------------------
    if run_with_sla wire just posh-smalt-wire; then
      pass=$((pass+1)); stage 5 "PASS smalt-wire (mint + wire + turnstile)"; emit smalt-wire pass "mint + wire + turnstile"
    else
      rc=$?
      if [ "$rc" = 3 ]; then
        skip=$((skip+1)); stage 5 "SKIP substrate not answering"
      else
        fail=$((fail+1)); stage 5 "FAIL smalt-wire exited $rc (wire or turnstile assert)"; tally
        emit smalt-wire fail "smalt-wire exited $rc"; finish 1
      fi
    fi

    # ---- Stage 6: terraform apply of the byte-identical example root --------
    if [ ! -d "$example" ]; then
      skip=$((skip+2))
      stage 6 "SKIP example root $example not landed — byte-identical HCL pending; stage 7 depends on it"
      # Local-apply fence (GAP6(b), disclosed single block): before any apply
      # of a tf root, the guard refuses backend-stripped applies/destroys
      # (backend block present + empty local state) that would CREATE against
      # real Azure resource names. Mirror of
      # courtroom-platform-az:scripts/guard_local_apply.sh; its court
      # (scripts/guard_local_apply_test.sh) is the non-vacuity witness — the
      # example root has NO backend block, so the guard passes here by design.
    fi
    if ! bash scripts/guard_local_apply.sh "$example" apply; then
      fail=$((fail+1)); stage 6 "FAIL guard_local_apply refused backend-stripped apply in $example"; tally
      emit terraform-apply fail "guard_local_apply refused backend-stripped apply"; finish 1
    fi
    echo "[POSH-COURT-6] guard_local_apply PASS (no backend block in $example — apply permitted)"
    if run_with_sla e2e bash -c 'cd "$1" \
      && terraform init -input=false \
      && terraform apply -auto-approve -input=false' _ "$example"; then
      pass=$((pass+1)); stage 6 "PASS terraform apply"; emit terraform-apply pass "terraform apply of $example"
    else
      fail=$((fail+1)); stage 6 "FAIL terraform apply exited nonzero in $example"; tally
      emit terraform-apply fail "terraform apply exited nonzero"; finish 1
    fi

    # ---- Stage 7: zero-drift — ordered plan(detailed-exitcode==0, pre-destroy)
    #      -> destroy -> residue GETs, all fail-closed -------------------------
    pex=0
    run_with_sla e2e bash -c 'cd "$1" && terraform plan -detailed-exitcode -input=false >/dev/null' _ "$example" || pex=$?
    if [ "$pex" != 0 ]; then
      fail=$((fail+1)); stage 7 "FAIL plan -detailed-exitcode=$pex (0 required — drift or error)"; tally
      emit zero-drift fail "plan -detailed-exitcode=$pex"; finish 1
    fi
    stage 7 "plan -detailed-exitcode 0 pre-destroy — no drift"
    if ! run_with_sla e2e bash -c 'cd "$1" && terraform destroy -auto-approve -input=false' _ "$example"; then
      fail=$((fail+1)); stage 7 "FAIL terraform destroy exited nonzero"; tally
      emit zero-drift fail "terraform destroy exited nonzero"; finish 1
    fi
    tok=$(curl -fsS --max-time 5 -X POST "{{SMALT_POSH_ARM}}/smalt/oauth2/v2.0/token" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode 'grant_type=client_credentials' \
      --data-urlencode 'client_id={{SMALT_POSH_CLIENT}}' \
      --data-urlencode 'client_secret={{SMALT_POSH_SECRET}}' \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])') \
      || { fail=$((fail+1)); stage 7 "FAIL residue STS mint failed"; tally
           emit zero-drift fail "residue STS mint failed"; finish 1; }
    rg2=$(curl -fsS --max-time 5 -H "Authorization: Bearer $tok" \
      "{{SMALT_POSH_ARM}}/subscriptions/{{SMALT_POSH_SUB}}/resourcegroups?api-version=2021-04-01") \
      || { fail=$((fail+1)); stage 7 "FAIL residue GET failed — cannot prove zero residue"; tally
           emit zero-drift fail "residue resourcegroups GET failed"; finish 1; }
    ca2=$(curl -fsS --max-time 5 -H "Authorization: Bearer $tok" \
      "{{SMALT_POSH_ARM}}/subscriptions/{{SMALT_POSH_SUB}}/providers/Microsoft.App/containerApps?api-version=2024-03-01") \
      || { fail=$((fail+1)); stage 7 "FAIL residue GET failed — cannot prove zero residue"; tally
           emit zero-drift fail "residue containerApps GET failed"; finish 1; }
    echo "$rg2" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert not d.get("value"), d["value"]' \
      || { fail=$((fail+1)); stage 7 "FAIL residue: resourcegroups non-empty after destroy"; tally
           emit zero-drift fail "resourcegroups non-empty after destroy"; finish 1; }
    echo "$ca2" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert not d.get("value"), d["value"]' \
      || { fail=$((fail+1)); stage 7 "FAIL residue: containerApps non-empty after destroy"; tally
           emit zero-drift fail "containerApps non-empty after destroy"; finish 1; }
    pass=$((pass+1))
    stage 7 "PASS zero-drift (plan 0 pre-destroy -> destroy -> zero residue)"
    emit zero-drift pass "plan 0 pre-destroy -> destroy -> zero residue"

    # ---- Stage 8: mutation non-vacuity — the court must be able to flip ------
    # Runs the real tamper-reject legs: a 1-bit payload flip must fail
    # VerifyTurnstile, and the HTTP envelope test must verify the receipt for
    # real. If verification regresses to rubber-stamp, these tests fail and
    # the court goes RED — the flip IS the proof the court is not vacuous.
    if run_with_sla mutation bash -c 'cd posh && go test -race -count=1 \
      -run "TestHTTPEnvelopeOverTCPListener|TestVerifyTurnstile" \
      ./internal/server/ ./internal/receipt/'; then
      pass=$((pass+1)); stage 8 "PASS mutation non-vacuity (tamper-reject legs green)"; emit mutation-nonvacuity pass "tamper-reject legs green"
    else
      fail=$((fail+1)); stage 8 "FAIL mutation legs failed — receipt verification regressed"; tally
      emit mutation-nonvacuity fail "mutation legs failed — receipt verification regressed"; finish 1
    fi

    tally
    echo "[POSH-COURT] ALIVE"
    finish 0

# Usage: just posh-invariant-court — non-vacuity shim-court for the SPARQL
# invariant gate (G27/G40): injects an orphan route individual into a temp
# COPY of the pack's instance TTL, expects the gate to flip to exit 1 naming
# the injected route, then proves the on-disk instance byte-exact unchanged
# (sha256). A court that cannot flip is FAIL.

# posh-invariant-court — SPARQL invariant-gate non-vacuity shim-court.
[no-cd]
posh-invariant-court:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{POSHROOT}}
    pack="{{SMALT_POSH_PACK}}"
    inst="$pack/examples/posh_instance.ttl"
    if [ ! -f "$inst" ]; then
      echo "[POSH-INV-COURT-SKIP] $inst missing — pack not landed; loud skip" >&2
      exit 3
    fi
    before=$(shasum -a 256 "$inst" | awk '{print $1}')
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    cp -R "$pack" "$tmp/pack"
    printf '\nposh:routeOrphanInjected a posh:IngressRoute .\n' >> "$tmp/pack/examples/posh_instance.ttl"
    rc=0
    SMALT_POSH_PACK="$tmp/pack" python3 scripts/posh_invariant_gate.py 2>"$tmp/violations.out" || rc=$?
    if [ "$rc" != 1 ]; then
      echo "[POSH-INV-COURT-FAIL] gate did not flip on injected orphan (rc=$rc, expected 1) — VACUOUS court" >&2
      cat "$tmp/violations.out" >&2 || true
      exit 1
    fi
    grep -q 'invariant_orphan_route.rq' "$tmp/violations.out" \
      || { echo "[POSH-INV-COURT-FAIL] flip did not name invariant_orphan_route.rq" >&2; exit 1; }
    grep -q 'routeOrphanInjected' "$tmp/violations.out" \
      || { echo "[POSH-INV-COURT-FAIL] flip did not name the injected route" >&2; exit 1; }
    after=$(shasum -a 256 "$inst" | awk '{print $1}')
    if [ "$before" != "$after" ]; then
      echo "[POSH-INV-COURT-FAIL] instance TTL changed on disk ($before -> $after) — restore violated" >&2
      exit 1
    fi
    echo "[POSH-INV-COURT] PASS gate flipped exit 1 naming invariant_orphan_route.rq / routeOrphanInjected; instance sha256 unchanged ($before)"

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

# Usage: just posh-status — GAP60 operator's single glance: typed sections
# (PLANE/PODS/ENDPOINTS/PROVIDER/GATES/LAST COURT/LAST ANDON), each
# OK/WARN/FAIL/SKIP(reason); exit 0 green / 2 RED. Body in
# scripts/posh_status.sh; this recipe is the thin wire.

# posh-status — one-glance typed status witness (exit 0 green / 2 RED).
[no-cd]
posh-status:
    #!/usr/bin/env bash
    set -uo pipefail
    cd {{POSHROOT}}
    exec bash scripts/posh_status.sh

# posh-image — build minimal static container image smalt/posh:latest.
[no-cd]
posh-image:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{POSHROOT}}
    docker build -t smalt/posh:latest -t smalt/posh-membrane:v26.10.30 -t posh:sidecar -f docker/Dockerfile.posh .
    echo "[POSH-IMAGE] built smalt/posh:latest, smalt/posh-membrane:v26.10.30, posh:sidecar"

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

# Usage: just posh-court-sla-test — SLA-clock non-vacuity fixture (GAP09 G1
# close leg; gaps/31-sla-clocks.md §5/§6), ~7s: control leg (true under a 5s
# clock must pass) + mutation leg (sleep 999 must be killed RED with a typed
# outcome:"timeout" andon receipt). Also proves the fail-closed refusal: an
# unregistered/empty-SLA gate exits 2, child not run.

# posh-court-sla-test — SLA-clock non-vacuity fixture, ~7s (control + kill legs).
[no-cd]
posh-court-sla-test:
    #!/usr/bin/env bash
    set -uo pipefail
    cd {{POSHROOT}}
    source "{{POSHROOT}}/scripts/posh_sla.sh"
    mkdir -p tmp/posh
    # Refusal leg: empty SLA -> exit 2, child never spawned.
    rcout=0
    run_with_sla ghost-stage "" true || rcout=$?
    if [ "$rcout" != 2 ]; then
      echo "[SLA-TEST-FAIL] empty-SLA gate exited $rcout, expected refusal exit 2" >&2
      exit 1
    fi
    echo "[SLA-TEST] PASS refusal leg (empty SLA -> exit 2, child not spawned)"
    # Control (GREEN) leg: true under a 5s clock must pass with a receipt row.
    if ! run_with_sla sla-fixture 5 true; then
      echo "[SLA-TEST-FAIL] control leg exited nonzero" >&2
      exit 1
    fi
    grep -q '"gate":"sla-fixture","outcome":"pass"' tmp/posh/andon.jsonl \
      || { echo "[SLA-TEST-FAIL] control leg green but no pass receipt row" >&2; exit 1; }
    echo "[SLA-TEST] PASS control leg (true under 5s clock, pass receipt)"
    # Mutation (RED) leg: sleep 999 must be killed at ~5s, exit 1, receipt
    # outcome:"timeout" with elapsed_ms in the 4000-12000ms band (scheduler
    # slack + -k 2 grace; still three orders below 999s).
    if run_with_sla sla-fixture-sleep 5 sleep 999; then
      echo "[SLA-TEST-FAIL] sleep(999) PASSED under a 5s clock — SLA clock inert, court vacuous" >&2
      exit 1
    fi
    row=$(grep '"gate":"sla-fixture-sleep","outcome":"timeout"' tmp/posh/andon.jsonl | tail -1)
    if [ -z "$row" ]; then
      echo "[SLA-TEST-FAIL] no timeout receipt row — clock killed but did not receipt" >&2
      exit 1
    fi
    ms=$(printf '%s' "$row" | python3 -c 'import sys,json; print(json.load(sys.stdin)["elapsed_ms"])')
    if [ "$ms" -lt 4000 ] || [ "$ms" -gt 12000 ]; then
      echo "[SLA-TEST-FAIL] timeout receipt elapsed_ms=${ms} outside the 4000-12000 band" >&2
      exit 1
    fi
    echo "[SLA-TEST] PASS mutation leg (sleep 999 RED at ${ms}ms, timeout receipt)"
    echo "[SLA-TEST] PASS: refusal + control green + sleep(999) RED + timeout receipt — SLA clock non-vacuous"

# ---------------------------------------------------------------------------
# compat-pin SPLIT gate (G33/G45 pin, split per
# docs/jira/posh/v26.10.31/gaps/12-compat-pin-split.md, v26.10.31 wave) —
# single disclosed block. Two pins, each travels with the artifact it pins:
#   compat-pin-core.ttl (smalt root)       substrate-owned facts
#   adapters/terraform-provider-smalt/compat-pin.ttl   azurerm-dialect facts
# Machine-diffed against CURRENT truth by scripts/compat_pin_check.py
# (--core-pin / --dialect-pin; exit 0 clean / 1 FAIL / 3 SKIP).
# Non-vacuity: `just compat-court` runs BOTH legs on temp copies —
#   core leg:     surfaceCount 12 -> 13 MUST flip to exit 1
#   dialect leg:  acrAPIVersion 2023-06-01 -> 2023-07-01 MUST flip to exit 1
#                 (fallback: registryTop row mutation)
#   loud-skip:    missing dialect-pin path MUST exit 3, never 0
# A court that flips only one leg is vacuous for the other; a gate that
# accepts a mutated pin or a missing pin is a VACUOUS GATE.
# ---------------------------------------------------------------------------
# compat-check — run both pin passes, typed exit ladder (0/1/3).
[no-cd]
compat-check:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{POSHROOT}}
    python3 scripts/compat_pin_check.py

# compat-court — split compat-pin mutation court (each leg MUST flip; sha256
# restore check on BOTH pins; loud-skip probe must exit 3). Exit 0 = flip
# witnessed on both legs; any leg that cannot flip is FAIL.
[no-cd]
compat-court:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{POSHROOT}}
    core_pin="compat-pin-core.ttl"
    dialect_pin="adapters/terraform-provider-smalt/compat-pin.ttl"
    mkdir -p tmp
    cb=$(shasum -a 256 "$core_pin" | awk '{print $1}')
    db=$(shasum -a 256 "$dialect_pin" | awk '{print $1}')

    # ---- leg 1: CORE mutation (resourceSurfaceCount 12 -> 13) must exit 1 --
    ct="tmp/compat-pin-core.mutated.ttl"
    sed -e 's|smalt:resourceSurfaceCount 12|smalt:resourceSurfaceCount 13|' "$core_pin" > "$ct"
    grep -q 'resourceSurfaceCount 13' "$ct" || { echo "[COMPAT-COURT-FAIL] core mutation did not apply" >&2; exit 1; }
    rc=0
    python3 scripts/compat_pin_check.py --core-pin "$ct" >/dev/null 2>&1 || rc=$?
    rm -f "$ct"
    if [ "$rc" != 1 ]; then
      echo "[COMPAT-COURT-FAIL] core leg: gate exited $rc on mutated core pin (expected 1) — VACUOUS" >&2
      exit 1
    fi
    echo "[COMPAT-COURT] core leg PASS: surfaceCount 13 mutation flipped gate to exit 1"

    # ---- leg 2: DIALECT mutation (acrAPIVersion) must exit 1 ----------------
    dt="tmp/compat-pin-dialect.mutated.ttl"
    sed -e 's|"Microsoft.ContainerRegistry/registries" ;            smalt:version "2023-06-01"|"Microsoft.ContainerRegistry/registries" ;            smalt:version "2023-07-01"|' "$dialect_pin" > "$dt"
    if ! grep -q '"2023-07-01"' "$dt" || ! grep -q 'Microsoft.ContainerRegistry/registries.*2023-07-01' "$dt"; then
      # fallback per gap plan: mutate a plain registryTop row instead
      sed -e 's|"Microsoft.KeyVault/vaults" ;                         smalt:version "2023-07-01"|"Microsoft.KeyVault/vaults" ;                         smalt:version "2023-08-01"|' "$dialect_pin" > "$dt"
    fi
    rc=0
    python3 scripts/compat_pin_check.py --dialect-pin "$dt" >/dev/null 2>&1 || rc=$?
    rm -f "$dt"
    if [ "$rc" != 1 ]; then
      echo "[COMPAT-COURT-FAIL] dialect leg: gate exited $rc on mutated dialect pin (expected 1) — VACUOUS" >&2
      exit 1
    fi
    echo "[COMPAT-COURT] dialect leg PASS: acr API-version mutation flipped gate to exit 1"

    # ---- leg 3: loud-skip probe (missing dialect pin) MUST exit 3 -----------
    rc=0
    python3 scripts/compat_pin_check.py --dialect-pin tmp/does-not-exist.ttl >/dev/null 2>&1 || rc=$?
    if [ "$rc" != 3 ]; then
      echo "[COMPAT-COURT-FAIL] loud-skip probe: gate exited $rc on missing dialect pin (expected 3 COMPAT-PIN-SKIP)" >&2
      exit 1
    fi
    echo "[COMPAT-COURT] loud-skip leg PASS: missing dialect pin exited 3 (COMPAT-PIN-SKIP)"

    # ---- restore check (sha256, fail-closed, both pins) ---------------------
    ca=$(shasum -a 256 "$core_pin" | awk '{print $1}')
    da=$(shasum -a 256 "$dialect_pin" | awk '{print $1}')
    [ "$cb" = "$ca" ] || { echo "[COMPAT-COURT-FAIL] core pin mutated during court (sha256 drift)" >&2; exit 1; }
    [ "$db" = "$da" ] || { echo "[COMPAT-COURT-FAIL] dialect pin mutated during court (sha256 drift)" >&2; exit 1; }
    echo "[COMPAT-COURT] PASS: core+dialect legs flipped to exit 1, loud-skip exited 3; both pins byte-identical ($cb / $db)"
    exit 0

# Usage: just posh-regen-check — GAP-29 lane 42 (2026-10-30): regen -> row
# non-vacuity -> gofmt normalize BOTH trees -> byte-compare generated vs
# committed -> exit 1 on drift; only then run the ceiling merge law
# (scripts/posh_merge_allowlist.sh). Fail-closed: vacuous render, any drift,
# or ceiling violation all exit 1. gofmt normalization is mandatory (G29
# witnessed live gofmt-only drift between generated/ and committed adapter
# files — without the normalize pass the gate is a formatting gate, not a
# content gate).

# posh-regen-check — regen -> gofmt-normalize -> byte-compare -> ceiling merge.
[no-cd]
posh-regen-check: _check_posh_tools
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{POSHROOT}}
    PACK={{SMALT_POSH_PACK}}
    fail() { echo "[REGEN-CHECK-FAIL] $1" >&2; exit 1; }

    # 1. Regenerate into the pack tree (same pipeline the court uses).
    sync_out=$(cd "$PACK" && ggen sync run --format json 2>/dev/null) \
      || fail "ggen sync run failed over $PACK"
    rows=$(printf '%s' "$sync_out" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d.get("written",[]))+len(d.get("skipped",[])))') \
      || fail "could not parse ggen sync JSON"
    [ "$rows" -gt 0 ] || fail "ggen sync rendered 0 rows (vacuous render, KD-POSH-5)"
    echo "[REGEN-CHECK] sync rows>0 ($rows)"

    # 2. Canonical normalization on BOTH trees before byte-compare
    #    (witnessed drift class: gofmt-only).
    command -v gofmt >/dev/null 2>&1 || fail "gofmt not on PATH"
    gofmt -w "$PACK"/generated/posh/internal/adapter/*.go
    mkdir -p posh/internal/adapter
    gofmt -w posh/internal/adapter/*.go

    # 3. Byte-compare generated vs committed, BEFORE any copy-out. Drift is
    #    exit 1 naming every drifted file.
    drift=0
    for f in "$PACK"/generated/posh/internal/adapter/*.go; do
      b=$(basename "$f")
      diff -q "$f" "posh/internal/adapter/$b" >/dev/null 2>&1 \
        || { echo "[REGEN-CHECK-FAIL] adapter drift: generated/$b != posh/internal/adapter/$b" >&2; drift=1; }
    done
    for f in "$PACK"/generated/lib/smalt/posh/pipeline/*.ex; do
      b=$(basename "$f")
      diff -q "$f" "lib/smalt/posh/pipeline/$b" >/dev/null 2>&1 \
        || { echo "[REGEN-CHECK-FAIL] pipeline drift: generated/$b != lib/smalt/posh/pipeline/$b" >&2; drift=1; }
    done
    FRAG_GEN="$PACK/generated/posh/config/egress_allowlist.generated.yaml"
    FRAG_REF=posh/config/egress_allowlist.generated.yaml
    [ -f "$FRAG_GEN" ] || fail "fragment missing after regen: $FRAG_GEN"
    if [ ! -f "$FRAG_REF" ]; then
      mkdir -p posh/config
      cp "$FRAG_GEN" "$FRAG_REF"
      echo "[REGEN-CHECK] first-run seed: fragment reference seeded at $FRAG_REF"
    fi
    diff -q "$FRAG_GEN" "$FRAG_REF" >/dev/null 2>&1 \
      || { echo "[REGEN-CHECK-FAIL] egress fragment drift: regenerated fragment differs from committed $FRAG_REF (graph topology changed without re-landing the fragment)" >&2; diff "$FRAG_GEN" "$FRAG_REF" >&2 || true; drift=1; }

    [ "$drift" -eq 0 ] || fail "regen drift (see [REGEN-CHECK-FAIL] rows above)"

    # 4. Gate passed -> ceiling merge law (posh.yaml ⊆ graph-projected set).
    #    The reference copy in posh/config/ is intentionally NOT overwritten
    #    on a drift (fail-closed: the flip must be re-landed by a human/lane).
    bash scripts/posh_merge_allowlist.sh \
      --fragment "$FRAG_GEN" --config posh/posh.yaml \
      || fail "ceiling merge law violated"
    echo "[REGEN-CHECK] PASS: generated == committed (gofmt-normalized), allowlist within graph ceiling"

# ============================================================================
# posh-bootstrap — clone-to-green staged recipe (lane 3/16, GAP-56,
# v26.10.30 wave). Resumable clone-to-green: every stage checks its own goal
# state first and SKIPs itself when that state already holds, so rerunning
# never redoes work and an aborted run resumes at the first unmet stage.
# ============================================================================
#
#   S1 tools     - delegate the blocking checks to `posh doctor` when the
#                  core binary is built (typed PATH loop otherwise)
#   S2 deps      - posh + provider `go mod download`; smalt `mix deps.get`
#                  ONLY under POSH_BOOTSTRAP_BEAM=1 (loud SKIP otherwise)
#   S3 kind      - kind-up/kind-images/kind-deploy; SKIP when cluster
#                  {{SMALT_KIND_CLUSTER}} exists with all nodes Ready
#   S4 images    - SKIP when smalt:local is already loaded in the node
#                  (crictl imgi inside the node container; docker images
#                  fallback when the node container is unreachable)
#   S5 deploy    - SKIP when pod smalt-backend-0 is Ready
#   S6 health    - bounded poll 60x1s on the ARM metadata anchor (the
#                  bearer-EXEMPT, discriminator-correct plane; /healthz is
#                  bearer-gated 401 and would false-negative forever)
#   S7 provider  - build + install (transient dev_overrides rc); SKIP when
#                  the provider binary is fresh (newer than every .go /
#                  go.mod / go.sum source)
#   S8 example   - OPTIONAL apply+destroy of the example root under
#                  POSH_BOOTSTRAP_APPLY=1 only, behind guard_local_apply;
#                  loud SKIP otherwise
#
# Stage selection: POSH_BOOTSTRAP_STAGES (default "all"; a comma/space list
# of S1..S8 selects a subset — the witness run below uses S1,S2,S7, the
# host-side stages, while lane 38 holds the substrate mid-court).
# Each stage echoes [BOOTSTRAP-n] PASS / SKIP(reason); any FAIL exits 1.
# ============================================================================

# posh-bootstrap — resumable clone-to-green, stages S1..S8 (POSH_BOOTSTRAP_STAGES).
[no-cd]
posh-bootstrap: _check_posh_tools
    #!/usr/bin/env bash
    set -uo pipefail
    cd {{POSHROOT}}
    stages="${POSH_BOOTSTRAP_STAGES:-all}"
    want() { case " $(printf '%s' "$stages" | tr ',' ' ') " in *" all "*|*" S$1 "*) return 0;; *) return 1;; esac; }
    rc_total=0
    provider="{{SMALT_POSH_PROVIDER}}"

    # ---- S1: tools (doctor delegation) ------------------------------------
    if want 1; then
      if [ -x posh/bin/posh ]; then
        if ./posh/bin/posh doctor -config posh/posh.yaml -repo-root "{{POSHROOT}}" >/tmp/posh-bootstrap-doctor.log 2>&1; then
          echo "[BOOTSTRAP-1] PASS tools (posh doctor blocking checks green)"
        else
          rc=$?
          echo "[BOOTSTRAP-1] FAIL posh doctor exited $rc — see /tmp/posh-bootstrap-doctor.log" >&2
          rc_total=1
        fi
      else
        for t in go terraform kubectl curl; do
          command -v "$t" >/dev/null 2>&1 || { echo "[BOOTSTRAP-1] FAIL tool not on PATH: $t — install: brew install $t" >&2; rc_total=1; }
        done
        if [ "$rc_total" -eq 0 ]; then
          echo "[BOOTSTRAP-1] PASS tools (posh/bin/posh absent — PATH loop: go/terraform/kubectl/curl)"
        fi
      fi
    else
      echo "[BOOTSTRAP-1] SKIP(stage filtered: not in POSH_BOOTSTRAP_STAGES=$stages)"
    fi

    # ---- S2: deps -----------------------------------------------------------
    if want 2; then
      for d in posh "$provider"; do
        if [ ! -f "$d/go.mod" ]; then
          echo "[BOOTSTRAP-2] FAIL $d/go.mod missing" >&2
          rc_total=1
          continue
        fi
        if (cd "$d" && go mod download); then
          echo "[BOOTSTRAP-2] PASS go mod download ($d)"
        else
          echo "[BOOTSTRAP-2] FAIL go mod download exited nonzero ($d)" >&2
          rc_total=1
        fi
      done
      if [ "${POSH_BOOTSTRAP_BEAM:-0}" = "1" ] && [ "$rc_total" -eq 0 ]; then
        export PATH="$HOME/.asdf/installs/erlang/29.1.2/bin:$HOME/.asdf/installs/elixir/1.20.4-otp-29:$PATH"
        if mix deps.get; then
          echo "[BOOTSTRAP-2] PASS mix deps.get (POSH_BOOTSTRAP_BEAM=1)"
        else
          echo "[BOOTSTRAP-2] FAIL mix deps.get exited nonzero" >&2
          rc_total=1
        fi
      elif [ "${POSH_BOOTSTRAP_BEAM:-0}" != "1" ]; then
        echo "[BOOTSTRAP-2] SKIP mix deps.get (POSH_BOOTSTRAP_BEAM unset — BEAM tests not requested)"
      fi
    else
      echo "[BOOTSTRAP-2] SKIP(stage filtered: not in POSH_BOOTSTRAP_STAGES=$stages)"
    fi

    # ---- S3: kind ladder ------------------------------------------------------
    if want 3; then
      if kind get clusters 2>/dev/null | grep -qx "{{SMALT_KIND_CLUSTER}}" \
        && [ -z "$(kubectl get nodes --no-headers 2>/dev/null | grep -v ' Ready')" ]; then
        echo "[BOOTSTRAP-3] SKIP cluster {{SMALT_KIND_CLUSTER}} exists with all nodes Ready"
      else
        export SMALT_KIND_BACKEND_IMG=smalt:local
        if just kind-up kind-images kind-deploy; then
          echo "[BOOTSTRAP-3] PASS kind ladder (kind-up/kind-images/kind-deploy)"
        else
          rc=$?
          echo "[BOOTSTRAP-3] FAIL kind ladder exited $rc — witness: just kind-status" >&2
          rc_total=1
        fi
        unset SMALT_KIND_BACKEND_IMG
      fi
    else
      echo "[BOOTSTRAP-3] SKIP(observed-by-lane-38: substrate held mid-court; stage filtered)"
    fi

    # ---- S4: images -----------------------------------------------------------
    if want 4; then
      node="smalt-control-plane"
      if docker exec "$node" crictl -r unix:///run/containerd/containerd.sock imgi 2>/dev/null | grep -q 'smalt:local'; then
        echo "[BOOTSTRAP-4] SKIP smalt:local already loaded in node $node (crictl imgi)"
      elif docker images smalt:local 2>/dev/null | grep -q '^smalt'; then
        echo "[BOOTSTRAP-4] SKIP smalt:local present in local docker (node containerd unreachable — docker images fallback)"
      else
        echo "[BOOTSTRAP-4] FAIL smalt:local absent from node containerd and docker — run: just kind-images" >&2
        rc_total=1
      fi
    else
      echo "[BOOTSTRAP-4] SKIP(observed-by-lane-38: stage filtered)"
    fi

    # ---- S5: deploy -------------------------------------------------------------
    if want 5; then
      if kubectl get pod smalt-backend-0 -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null | grep -q '^true'; then
        echo "[BOOTSTRAP-5] SKIP smalt-backend-0 already Ready"
      else
        export SMALT_KIND_BACKEND_IMG=smalt:local
        if just kind-deploy; then
          echo "[BOOTSTRAP-5] PASS kind-deploy"
        else
          rc=$?
          echo "[BOOTSTRAP-5] FAIL kind-deploy exited $rc — witness: just kind-status" >&2
          rc_total=1
        fi
        unset SMALT_KIND_BACKEND_IMG
      fi
    else
      echo "[BOOTSTRAP-5] SKIP(observed-by-lane-38: stage filtered)"
    fi

    # ---- S6: health poll ----------------------------------------------------------
    if want 6; then
      echo "[BOOTSTRAP-6] polling metadata anchor {{SMALT_POSH_META}} (bounded 60x1s)"
      ok=0
      for i in $(seq 1 60); do
        if curl -fsS --max-time 2 "{{SMALT_POSH_META}}" >/dev/null 2>&1; then
          ok=1
          echo "[BOOTSTRAP-6] PASS metadata anchor 200 after ${i} poll(s)"
          break
        fi
        sleep 1
      done
      if [ "$ok" != 1 ]; then
        echo "[BOOTSTRAP-6] FAIL metadata anchor never answered 200 within 60s — witness: just kind-status" >&2
        rc_total=1
      fi
    else
      echo "[BOOTSTRAP-6] SKIP(observed-by-lane-38: stage filtered)"
    fi

    # ---- S7: provider build + install (fresh-binary skip) --------------------------
    if want 7; then
      bin="$provider/terraform-provider-azurerm"
      fresh=0
      if [ -x "$bin" ]; then
        fresh=1
        for f in $(find "$provider" -name '*.go' -o -name 'go.mod' -o -name 'go.sum' 2>/dev/null); do
          if [ "$f" -nt "$bin" ]; then
            fresh=0
            echo "[BOOTSTRAP-7] stale: $f newer than binary"
            break
          fi
        done
      fi
      if [ "$fresh" = 1 ]; then
        echo "[BOOTSTRAP-7] SKIP provider binary fresh ($bin newer than all Go sources)"
      else
        if just posh-build && just posh-install >/dev/null; then
          echo "[BOOTSTRAP-7] PASS provider build + install (rc at {{SMALT_POSH_TFRC}})"
        else
          rc=$?
          echo "[BOOTSTRAP-7] FAIL provider build/install exited $rc" >&2
          rc_total=1
        fi      fi
    else
      echo "[BOOTSTRAP-7] SKIP(observed-by-lane-38: stage filtered)"
    fi

    # ---- S8: example apply+destroy (OPTIONAL, POSH_BOOTSTRAP_APPLY=1) ---------------
    if want 8; then
      example="$provider/{{SMALT_POSH_EXAMPLE}}"
      if [ "${POSH_BOOTSTRAP_APPLY:-0}" != "1" ]; then
        echo "[BOOTSTRAP-8] SKIP example apply+destroy (POSH_BOOTSTRAP_APPLY unset — optional destructive stage)"
      elif [ ! -d "$example" ]; then
        echo "[BOOTSTRAP-8] SKIP example root $example not landed"
      else
        if ! bash scripts/guard_local_apply.sh "$example" apply; then
          echo "[BOOTSTRAP-8] FAIL guard_local_apply refused apply in $example" >&2
          rc_total=1
        elif ! (cd "$example" && TF_CLI_CONFIG_FILE="{{POSHROOT}}/{{SMALT_POSH_TFRC}}" terraform apply -auto-approve -input=false); then
          echo "[BOOTSTRAP-8] FAIL terraform apply exited nonzero in $example" >&2
          rc_total=1
        elif ! (cd "$example" && TF_CLI_CONFIG_FILE="{{POSHROOT}}/{{SMALT_POSH_TFRC}}" terraform destroy -auto-approve -input=false); then
          echo "[BOOTSTRAP-8] FAIL terraform destroy exited nonzero in $example" >&2
          rc_total=1
        else
          echo "[BOOTSTRAP-8] PASS example apply+destroy under guard_local_apply ($example)"
        fi
      fi
    else
      echo "[BOOTSTRAP-8] SKIP(stage filtered: not in POSH_BOOTSTRAP_STAGES=$stages)"
    fi

    if [ "$rc_total" -eq 0 ]; then
      echo "[BOOTSTRAP] result: stages=[$stages] green"
      exit 0
    fi
    echo "[BOOTSTRAP] result: stages=[$stages] FAIL"
    exit 1

# ---------------------------------------------------------------------------
# posh-help — annotated help for the posh/provider family (gaps/64, lane
# 11/16, single disclosed block). Body in scripts/posh_help.sh: recipe ->
# summary -> usage example -> typical duration, plus a drift guard (exit 2
# when a help row has no matching `just --list` recipe). Optional bash
# completion: posh/completions/posh.bash (documented there, default-off).
# ---------------------------------------------------------------------------
# Per-recipe detail: bash scripts/posh_help.sh <recipe> (just eats extra
# args as recipes, so the wire passes none).

# posh-help — annotated posh/provider help (summary, usage, duration).
[no-cd]
posh-help:
    #!/usr/bin/env bash
    set -euo pipefail
    exec bash "{{POSHROOT}}/scripts/posh_help.sh"
