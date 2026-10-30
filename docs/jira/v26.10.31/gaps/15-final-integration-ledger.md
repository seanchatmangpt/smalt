# 15 — Final Integration Ledger (Closing Checklist)

Lane 15 of 15, v26.10.31 consolidation. All paths verified on disk 2026-10-30.
SMALT=`/Users/sac/smalt`, COURT=`/Users/sac/cai/courtroom-platform-az`.

On-disk evidence read for this ledger:

- `git status` in both trees (2026-10-30): SMALT ~90 modified + ~250 untracked paths; COURT 6 modified + 6 untracked top-level paths (full expansion below).
- `docs/jira/v26.10.31/gaps/INDEX.md` (SMALT) — M1–M17 table; blocking set M2/M9/M13/M16.
- `docs/jira/posh/v26.10.30/gaps/18-lease-residue.md`, `37-residue-to-green-ledger.md`, `53-integration-prep.md` (SMALT) — the G18/G37/L53 censuses.
- `lsof +D` on all 12 SMALT `_build-*` roots (2026-10-30): the only open ref in every dir is a single `com.apple` metadata-index DIR fd (PID 565) — zero build-process refs. All leases deletable.

---

## 1. Relocation sweep

Verified: no stray `gaps/` dirs in either repo. Canonical homes on disk:

- SMALT `docs/jira/posh/v26.10.30/gaps/` — reports 01–76 + INDEX.md + receipts/.
- SMALT `docs/jira/posh/v26.10.31/gaps/` — reports 01–17 + 69-dod-execution-harness.md.
- SMALT `docs/jira/v26.10.31/gaps/` — INDEX.md, 07-doc-migration-ledger.md, 11-credential-admission-annexes.md, GEMINI-DOSSIER.md. Declared v26.10.31 window home per its own INDEX ("canonical home: `docs/jira/posh/v26.10.31/gaps/`; the v26.10.31 window cross-references it"). KEEP.
- COURT `docs/jira/nextjs-harness/v26.10.30/` (HRN-001..015 + PRD + receipts) — correct COURT home.
- COURT `receipts/gaps/h6-hrn-006-tc-ver.md` — COURT-side receipt, correct home.

One stray found: COURT `posh/var/dx-events.jsonl` (untracked; posh ran with cwd=COURT and left runtime residue in the wrong repo; SMALT keeps its dx-events under `tmp/posh/`). Exact commands:

```bash
mv /Users/sac/cai/courtroom-platform-az/posh/var/dx-events.jsonl \
   /Users/sac/smalt/tmp/posh/archive/dx-events.courtroom-stray.jsonl
rmdir /Users/sac/cai/courtroom-platform-az/posh/var 2>/dev/null || true
rmdir /Users/sac/cai/courtroom-platform-az/posh 2>/dev/null || true
```

(`rmdir` only-if-empty; the COURT `posh/` dir currently contains only `var/`.)

## 2. Lease deletions (per G18/G37/L53)

`lsof +D` live-ref check 2026-10-30: no build-process refs; only a Spotlight/Finder
metadata-index fd per dir. Safe to delete. Measured sizes (`du -sh`):

```
_build-acrver 754M   _build-c4 754M      _build-dod8 381M   _build-f12 381M
_build-f4 373M       _build-f5 754M      _build-f9 754M     _build-final 754M
_build-l44 755M      _build-l53 730M     _build-lane23 381M _build-lane39 755M
```

Build-root subtotal: ~6.69 GB.

Exact commands:

```bash
cd /Users/sac/smalt && rm -rf _build-acrver _build-c4 _build-dod8 _build-f12 \
  _build-f4 _build-f5 _build-f9 _build-final _build-l44 _build-l53 _build-lane23 _build-lane39
```

/tmp leases (verified present via `ls`, sizes via `du -sh`):

```
/tmp/f2-provider 425M    /tmp/f3 728M       /tmp/f3-consumer 728M  /tmp/f3-provider 170M
/tmp/lane30 8.0K         /tmp/posh.test 9.2M  /tmp/posh2.test 9.2M
/tmp/poshvet-lane5 8.6M  /tmp/posh-c11 20K  /tmp/posh-c12-bin 6.7M
/tmp/posh-finalbuild 192K  /tmp/posh-gobuild 192K  /tmp/posh-nopgo 6.6M
/tmp/posh-p2 9.6M        /tmp/posh-pgo 6.7M  /tmp/posh-render2 272K  /tmp/poshrun 12K
```

Subtotal: ~2.16 GB. Grand total reclaimed: ~8.85 GB.

```bash
rm -rf /tmp/f2-provider /tmp/f3 /tmp/f3-consumer /tmp/f3-provider /tmp/lane30 \
       /tmp/posh.test /tmp/posh2.test /tmp/poshrun /tmp/poshvet-lane5 \
       /tmp/posh-c11 /tmp/posh-c12-bin /tmp/posh-finalbuild /tmp/posh-gobuild \
       /tmp/posh-nopgo /tmp/posh-p2 /tmp/posh-pgo /tmp/posh-render2
```

KEEP (verified on disk):

- `/Users/sac/smalt/tmp/posh/` and `tmp/posh/archive/` — live runtime (`andon.jsonl`, `dod-latest.json`, `gate-results.jsonl`, court logs). KEEP per dispatch.
- `/tmp/posh_client.py`, `/tmp/posh_court_body.sh` — active harness scripts. KEEP.
- Optional sweep of plain-text court scratch (`/tmp/posh-*.log`, `/tmp/posh-*.sha`, `/tmp/posh-*.pgo`, `/tmp/posh-*.txt`, `/tmp/posh*.bak`, `/tmp/posh-dry.*`, `/tmp/posh-real*`, `/tmp/posh-q*.log`, `/tmp/posh-flip*`, `/tmp/posh-var-before.sha`, `/tmp/posh-ggen-head.toml`, `/tmp/posh-main_restored.go`, `/tmp/posh-tail.just`, `/tmp/posh_gate_out.txt`, `/tmp/posh_green.txt`, `/tmp/posh_ttl_restore.bak`) — coordinator's judgment at close; not lease-class.

## 3. Gate reruns per changed surface

Run before any commit; append exit codes to this file (§3-receipts) after running.

| # | Surface | Command | Notes |
|---|---|---|---|
| 3.1 | posh Go | `cd /Users/sac/smalt/posh && go vet ./... && go test ./...` | ~90 posh files changed |
| 3.2 | provider | `cd /Users/sac/smalt/adapters/terraform-provider-smalt && go vet ./... && go test ./...` | hermetic suite |
| 3.3 | provider live | same cwd, `TFPOSHT_LIVE=1 go test ./internal/provider/ -run TestLive -count=1` | skip-if-uncredentialed must be loud, not silent |
| 3.4 | smalt BEAM targeted | `cd /Users/sac/smalt && MIX_BUILD_ROOT=_build-final2 mix test test/smalt/posh test/integration/acr_test.exs test/integration/rbac_role_definitions_test.exs` | covers changed lib/smalt + new pipeline modules |
| 3.5 | python gates | `cd /Users/sac/smalt && python3 scripts/dod_check.py && python3 scripts/posh_invariant_gate.py && python3 scripts/verify_smalt_core_ontology.py && python3 scripts/compat_pin_check.py` | `compat_pin_check.py` because `compat-pin.ttl` is new |
| 3.6 | just parse SMALT | `cd /Users/sac/smalt && just --evaluate` | validates justfile.d/57–60 edits |
| 3.7 | just parse COURT | `cd /Users/sac/cai/courtroom-platform-az && just --evaluate` | new root justfile |
| 3.8 | COURT harness | `cd /Users/sac/cai/courtroom-platform-az && just harness-court && just harness-dod` | recipes verified in new justfile |
| 3.9 | COURT web harness | `cd /Users/sac/cai/courtroom-platform-az/apps/web && npx vitest run -c vitest.harness.config.ts` | new vitest.harness.config.ts + test/harness/ |

## 4. Atomic commit plan

### SMALT (`/Users/sac/smalt`) — 6 commits, in order

1. **posh-core** — all of `posh/` (cmd/ andon [incl. main_test.go, main_outcome_test.go], cmd/posh, cmd/poshvet, cmd/pgo-merge, internal/** new dirs: adapter/generated_*, andon/hooks.go, api, auth, bootstrap, chaos, completion, court, dev, diag, doctor/*, ingress, membrane, messaging, metrics, mock, mutation, pgo, poshvet, receipt, replay, server/*_test, storage, swissmap, telemetry/**, tui, uniqueintern, wasm; tests/chicago/case_study_platform_test.go; completions/, config/egress_allowlist.generated.yaml, docs/*, Makefile, Dockerfile, go.mod/go.sum, .gitignore, KNOWN_DIVERGENCES.md, README.md).
   **DO NOT COMMIT**: `posh/tmp/posh/tfrc` (credential file — tfrc = terraform credentials; delete or add `posh/tmp/` to `posh/.gitignore`).
2. **provider** — `adapters/terraform-provider-smalt/` (README, examples, internal/provider/*.go incl. new honesty_law_test.go, import_state.go, import_state_test.go, live_f4_test.go, scripts/import_roundtrip_court.sh, scripts/receipts/c2-honesty-law-2026-10-30.md). Includes deletion of stale duplicate `terraform-provider-smalt/README.md` (D in status).
3. **pack+pin** — `ggen-marketplace/packs/posh/` (generated lib+adapter, templates, ontology/routes.ttl, shapes, ggen.toml, .ggen-v2 receipts), `compat-pin.ttl`, `priv/ontologies/smalt-core.ttl`, `docs/jira/posh/v26.10.31/smalt-core.ttl`, `scripts/compat_pin_check.py`, `scripts/verify_smalt_core_ontology.py`.
4. **smalt-lib** — `lib/smalt/**` (arm/rbac.ex, arm_gateway/*, ash_gen/registry.ex, posh/ingress/*, posh/port.ex, posh/pipeline/* new modules, registry.ex), `test/smalt/posh/*`, `test/integration/*`.
5. **recipes+CI** — `justfile.d/57,58,59,60-dod.just`, `Justfile`, `dod.yaml`, `.github/workflows/posh-go.yml`, `.github/workflows/kind-swarm.yml`, `.github/workflows/posh-continuous-chaos.yml`, `k8s/*`, `docker/Dockerfile*`, `.github/dependabot.yml`, remaining `scripts/` (court_plane_discriminator.sh, dod_check.py, dx_report.py, dx_telemetry.sh, egress_plane_discriminator.sh, guard_local_apply*.sh, posh_*.sh/py, receipt-related), `scripts/posh_invariant_gate.py`.
6. **docs/gaps/receipts** — `docs/jira/posh/v26.10.30/**` (gaps 01–76, receipts, glossary, charter docs), `docs/jira/posh/v26.10.31/**`, `docs/jira/v26.10.31/**` (this ledger included), `docs/jira/posh/v26.10.30` modified files, `.ggen_igniter/*`, `README.md`, `examples/README.md`, `.ggen_igniter/receipts/2026-10-30.jsonl`.

### COURT (`/Users/sac/cai/courtroom-platform-az`) — 1 atomic commit (or split scripts/docs if preferred)

Modified: `.github/workflows/deploy-dev.yml`, `.github/workflows/infra-dev.yml`, `.gitignore`, `README.md`, `apps/web/package.json`, `infra/environments/dev/platform/.terraform.lock.hcl`.
Untracked (commit): `apps/web/test/` (24 harness files), `apps/web/vitest.harness.config.ts`, `docs/` (nextjs-harness v26.10.30: HRN-001..015, PRD, receipts, charter), `infra/modules/tenant-apps/.terraform.lock.hcl`, `justfile`, `scripts/` (convention_gates.sh, flake_loop.sh, guard_local_apply*.sh, harness_*.sh/py, hrn004 receipt, INDEX).
Untracked (DO NOT COMMIT / delete):

- `privkey.pem` — 0-byte but PEM-class; gitignored (`*.pem` line 12) so safe from accidental add, still delete it.
- `erl_crash.dump` (repo root, from a stray BEAM run) — delete.
- `infra/environments/dev/platform/secrets.tf` — REVIEW before committing: contains a `random_password` resource and sensitive variable scaffolding but no literal secret values; the `idp_certs` map is `sensitive = true` and supplied out-of-band. Commit only if the team's policy allows Terraform secret scaffolding in-repo; otherwise add to `.gitignore` and track via a `.secrets.tf.example`. Flagged, decision to coordinator.
- `scripts/__pycache__/` — delete / gitignore.
- `receipts/` — commit (generated INDEX + gaps receipt; regenerated by `scripts/receipts_index.sh`).
- `posh/var/dx-events.jsonl` — removed in §1 relocation, so gone before commit.

## 5. Push sequence

1. Run §1 relocation + §2 deletions first (clean tree of residue).
2. Run §3 gates; record exits in §3-receipts below. Any gate exit != 0 → fix forward (no reset), rerun, then proceed.
3. COURT commit first (smaller blast radius; its CI is independent), then push COURT and watch its workflow.
4. SMALT commits 1→6 in order (posh-core first so CI compiles the largest surface early; docs last), push after all 6 land locally.
5. Both pushes from `main`; no rebase, no force-push; merge only via PR per repo policy.
6. Post-push: confirm CI green on both remotes; then final `just --evaluate` + gap-register sync (`justfile.d/10-gap-register-sync.just`) and close G37's "residue-to-green" ledger row with the push SHAs.

## 3-receipts

(appended after coordinator runs gates — exit codes per §3 row)

---

# 6. Lane-20 acceptance-arm runbook (wave-2 gap lane 15, pre-populated 2026-10-30)

Pre-populated by the wave-2 gap lane so lane 20 can execute top-to-bottom without
re-deriving anything. Subject: smalt @ f0e0a125 (working tree, uncommitted wave).
Cheap read-only arms were RUN by this lane; results recorded inline. Every other
command was syntax-verified (`bash -n` / recipe grep) but not executed — L20 owns
execution. `SMALT=/Users/sac/smalt`, `COURT=/Users/sac/cai/courtroom-platform-az`.

## 6.0 Cheap read-only pre-verifications (RUN this lane, 2026-10-30)

| probe | command | result |
|---|---|---|
| purge grep (COURT stray) | `ls /Users/sac/cai/courtroom-platform-az/posh/var/` | **1 stray present**: `dx-events.jsonl` — §1 relocation NOT yet run |
| purge grep (GAP tokens) | `grep -rn "GAP(" docs/WIRE_PARITY.md docs/jira/v26.10.31` | **5 open GAP( tokens** (must be 0 at close, or each receipt-gated) |
| ttl shape count | `grep -c "a sh:NodeShape" $SMALT/priv/ontologies/public-cloud-core.ttl` | **9 sh:NodeShape blocks** (343 lines; `smalt-core.ttl` NOT yet landed at `priv/ontologies/` — CC-3/M13 input missing) |
| BLAKE3 in-repo suite | `cd $SMALT/posh && go test ./internal/receipt/ -run 'TestVerifyTurnstile\|TestTurnstileReceiptDeterminismAndSensitivity' -count=1` | **PASS exit 0** (0.384s) |
| BLAKE3 scratch tamper | scratch module at `/tmp/l15-tamper` (blake3.go+verify.go only, own go.mod): flip ts_ns 42→43, flip body `hello`→`hellO`, bad hex `zz` | **ALL REFUSED, PASS exit 0** — ts flip → `ok=false`, body flip → `ok=false`, bad hex → `ErrBadTurnstileHex` |
| CC-2 sha witness (M1′) | `shasum $SMALT/lib/smalt/arm_gateway/plug/oidc_sts.ex $SMALT/lib/smalt/identity/oidc_idp.ex` | `oidc_sts.ex c6622b05b3e7bff03c255952897cabf7afc1654a`, `oidc_idp.ex f78fd3aefb360ade57f51947eac2b3c1e8c068db` — **byte-match gap-01's recorded values** |
| CC-4 raw grep (M1′) | `grep -rn "func.*[Ss]ign\|jwt.NewWithClaims\|rsa.GenerateKey\|StsKey" $SMALT/posh/internal --include='*.go' \| grep -v _test` | 7 raw hits, all comment/table rows in `dialect/azure/sts.go` + unrelated `checkAssignStmt` (contains "sign" as substring) — **zero mint-capable code; use the typed court below, not this raw grep** |

## 6.1 Acceptance arms

### Arm 1 — purge grep (residue sweep)
```bash
ls /Users/sac/cai/courtroom-platform-az/posh/var/ 2>/dev/null | wc -l   # expect 0 after §1
grep -rn "GAP(" /Users/sac/smalt/docs/WIRE_PARITY.md /Users/sac/smalt/docs/jira/v26.10.31 | wc -l   # expect 0
```
Current: 1 stray + 5 GAP tokens. Blocking deps: ledger §1 (relocation) must run
first. Red-before-green witness: §6.0 row 1–2 (this lane's counts are the RED
baseline; close = both counts 0).

### Arm 2 — provider court (unmodified working tree)
```bash
cd /Users/sac/smalt/adapters/terraform-provider-smalt
git status --porcelain . > /tmp/l20-provider-before.txt
bash scripts/provider_court.sh   # 8 stages; exit 0 only if all pass; never touches ~/.terraformrc
git status --porcelain . > /tmp/l20-provider-after.txt
diff /tmp/l20-provider-before.txt /tmp/l20-provider-after.txt && echo UNMODIFIED
```
Current pre-verification: `bash -n scripts/provider_court.sh` PASS (this lane).
Blocking deps: provider lanes' in-flight files landed (honesty_law_test.go,
import_state.go, live_f4_test.go are untracked as of f0e0a125). Red-before-green
witness: `scripts/receipts/` prior court receipts.

### Arm 3 — wire-court byte-diff (subject re-specified; see RISK R1)
```bash
cd /Users/sac/smalt
MIX_BUILD_ROOT=_build-l20 mix test test/integration/amqp10_adversary_court_test.exs \
  test/integration/amqp10_crash_only_court_test.exs test/integration/apim_wire_test.exs \
  test/integration/arm_receipt_turnstile_test.exs 2>&1 | tee /tmp/l20-wire-run1.txt
sha256 /tmp/l20-wire-run1.txt   # pins the pre-migration baseline
# after migration diffs land, re-run identically and byte-diff run2 vs run1
```
Current pre-verification: the named files exist on disk (verified). The legacy
wire tier is gone: `mix test --include amqp_wire` runs ZERO tests (tag exists in
`mix.exs:51-52` but no test file carries it; `test/compliance_test.exs`, the
170-test compliance wire court, was deleted at 64f6099). Blocking deps:
smalt-lib commit (§4 commit 4) landed; substrate booted for integration legs.
Red-before-green witness: run1 hash pinned by L20 at first execution (this lane
does not run the suite — not cheap).

### Arm 4 — M1 / M1′ probe
```bash
cd /Users/sac/smalt && just posh-smalt-wire        # exit 0 = wire face intact; exit 3 = loud skip (substrate down)
shasum lib/smalt/arm_gateway/plug/oidc_sts.ex lib/smalt/identity/oidc_idp.ex   # must equal the §6.0 hashes
cd posh && go test ./internal/dialect/azure/ -run STS -count=1   # CC-4 typed court (sts_test.go)
```
M1 = live STS mint + resourcegroups round-trip (`just posh-smalt-wire`).
M1′ = byte-identity + sovereignty residue legs: the sha witness (§6.0, byte-match
CONFIRMED this lane) + CC-4 court. Blocking deps: dialect lanes' in-flight
`lro.go`/`family_translate.go` compile blockers resolved (gap-01 wave-2 note:
azure package did not compile as of that lane's run — `splitPath` redeclared,
`NormalizeARMID` undefined). Red-before-green witness: gap-01 §Close-conditions
(cc-2 sha values) + its CC-4 PASS note (2026-10-30).

### Arm 5 — api-version 2099 refusal
```bash
cd /Users/sac/smalt && MIX_BUILD_ROOT=_build-l20 mix test test/internal/api_version_admission_fence_test.exs
```
Witness: `test/internal/api_version_admission_fence_test.exs:101-103` — version
`2099-01-01` (newer than latest) → 400 `InvalidApiVersionParameter` naming
`Registry.latest_version` (KD-78 monotonic admission: only a FUTURE version
refuses; a past one is admitted). Blocking deps: smalt-lib commit landed
(`lib/smalt/egress/KvRoutes.ex` admission fence). Red-before-green witness:
prior court runs in v26.10.25 KD register (`kds3_s4`/`kdlith_w2` rows,
CLOSED-WITH-EVIDENCE).

### Arm 6 — BLAKE3 tamper (RUN this lane — done, §6.0)
```bash
cd /Users/sac/smalt/posh && go test ./internal/receipt/ -count=1
```
Plus the scratch tamper probe (recipe preserved at `/tmp/l15-tamper/` for L20 to
re-run; copy blake3.go + verify.go to a scratch module). Red-before-green
witness: `blake3_test.go:140 TestVerifyTurnstile` (official-vector + tamper
sensitivity in-repo). **L20 trap, witnessed this lane**: `VerifyTurnstile`
returns `ok=false, err=nil` on a digest mismatch — err != nil ONLY for malformed
hex (`ErrBadTurnstileHex`). A red-leg that asserts `err != nil` on mismatch will
false-FAIL; assert `ok == false`.

### Arm 7 — kds3_s4 + kdlith_w2 courts
```bash
cd /Users/sac/smalt && MIX_BUILD_ROOT=_build-l20 mix test \
  test/internal/kds3_s4_secret_version_history_test.exs \
  test/internal/kdlith_w2_versions_list_test.exs
```
Witness: `docs/jira/v26.10.25/KNOWN_DIVERGENCES.md` — both courts named GREEN /
CLOSED-WITH-EVIDENCE (2026-10-25). Blocking deps: kv-lane files still on disk
single-owner (`KvRoutes.ex`, `key_vault_actions.ex`) — land smalt-lib first.
Red-before-green witness: the KD-184/185/186 receipts in the same register.

### Arm 8 — blob-worm gate
```bash
cd /Users/sac/smalt && just invariant-gates   # python3 scripts/invariant_gates.py; blob-worm = gates/blob_worm_gate.py
```
Non-vacuity: a gate exits 0 only if the positive capture passes AND every
negative fixture is refused (gates/common.py:9-13). Receipts to
`tmp/invariant-gates/<gate>-receipt.json` (written fresh). Blocking deps: none
(self-boots substrate on private ports). Red-before-green witness: the gate's
own negative fixtures — a blob-worm gate that admits a new-blob write into a
locked container must exit 1 (see also testing-chicago-style KD register:
enclave WORM finding inverted — real Azure PERMITS new-blob writes into locked
containers; check the pinned behavior before filing a parity defect).

### Arm 9 — mutation court
```bash
cd /Users/sac/smalt && just mutation-court   # python3 scripts/mutation_court.py
```
Blocking deps: posh tree compiles (go gates green). Red-before-green witness:
POSH-008-turnstile-flip row of the 09-dod-consolidated table (PASS,
tmp/posh/dod-first-run.json).

### Arm 10 — court-x2
```bash
cd /Users/sac/smalt && just quiet-check   # precondition: machine settled
just court-x2                             # justfile.d/07-court-x2.just
```
Red-before-green witnesses: `docs/jira/v26.10.17/receipts/r241-court-x2-attempt3-typed-red.md`
(typed red) + `docs/jira/v26.10.19/receipts/v261019-12-court-x2-close.md` (close).
Blocking deps: all arms 1–9 green; §2 lease deletions done; quiesce per
`justfile.d/24-quiesce.just`.
**FLAG R2 (pre-existing, L20 must know)**: `justfile.d/12-docs-dod.just:110`
`check docs/jira/v26.10.25/receipts/court-x2-2026-10-25.md` — that file does NOT
exist on disk, so `just docs-dod-check` exits 1 until the receipt is restored or
the row re-pointed at the real close receipt. Not introduced by this lane.

## 6.2 Risks

- **R1 — wire-court subject retired**: the arm was dispatched as "wire-court
  byte-diff" but the compliance wire court (170 tests) was deleted at 64f6099
  and no test carries the `amqp_wire` tag today. This lane re-specified the arm
  onto the live wire face (amqp10 courts + apim_wire + arm_receipt_turnstile).
  If the dispatch intended a different subject, L20 must confirm before run1.
- **R2 — docs-dod-check red**: missing court-x2 receipt citation
  (`justfile.d/12-docs-dod.just:110`) exits 1; pre-existing.
- **R3 — smalt-core.ttl absent**: `priv/ontologies/smalt-core.ttl` (CC-3/M13
  input, ledger §4 commit 3) is not on disk at the committed path — commit 3 and
  Arm 4 CC-3 leg are BLOCKED on its authoring lane.
- **R4 — CC-4 raw grep is not the court**: 7 raw hits are comments/substrings;
  the typed `sts_test.go` court is the witness. Do not file a CC-4 violation
  from the raw grep.
- **R5 — VerifyTurnstile ok/err contract**: mismatch is `ok=false, err=nil`;
  only bad hex errors. Red-legs must assert ok==false (witnessed false-FAIL in
  this lane's own first scratch probe).

## 6.3 Falsifier status

Every command above was either RUN (§6.0 rows) or syntax-verified (bash -n on
provider_court.sh and shim scripts; recipe existence greps in Justfile/
justfile.d/58-posh.just, 07-court-x2.just). Dependency rows name real lanes and
real receipts (all paths verified by ls/cat this lane). Close = L20 runs arms
1–10 in order and appends exits to §3-receipts.
