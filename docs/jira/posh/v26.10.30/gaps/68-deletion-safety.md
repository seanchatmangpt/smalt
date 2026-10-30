# Deletion-Safety Audit of Operator-Facing Destructive Surfaces

Lane 15/16. Subject: repo `courtroom-platform-az` @ `31c58e9` (audit + fixes on top, uncommitted).
Method: read each named surface; where the named surface does not exist here, report it as
loudly-MISSING rather than a silent skip. Receipts: `bash scripts/guard_local_apply_test.sh`
→ 10/10 PASS exit 0 (run this session, after the fix below).

## Audit results

### 1. posh-clean (`58-posh.just`) — loudly-MISSING in this repo
No `58-posh.just`, no `posh/` directory, no posh clean recipe anywhere (grep over repo: only
doc references in `README.md`, `justfile`, `scripts/receipts_index.sh`). The posh estate
(58-posh.just, posh/Makefile, posh/var durability) lives in the smalt repo, not here.
Nothing to audit → nothing can touch `posh/var` here. **No footgun, no fix.**

### 2. `make -C posh clean` — loudly-MISSING (same finding as 1)
No posh Makefile in this checkout. **No footgun, no fix.**

### 3. kind-down / teardown — loudly-MISSING as a recipe; residue footguns registered
No `kind-down`, `kind delete cluster` or teardown recipe exists in justfile/scripts/workflows
(grep receipts cited in audit trail). kind clusters are referenced by name only
(`smalt-control-plane` in `scripts/posh_doctor.sh:69`). Registering the F2-class footguns so
they gate any future recipe:

- **D68-1 (MEDIUM)**: a future `kind-down` that deletes a shared cluster (`smalt-control-plane`
  is a shared-subscription-analog: doctor DOCTOR-5/6 depend on it) deletes other lanes' work.
  Fix when introduced: per-owner cluster names (`kind-${USER}-<lane>` or explicit name arg,
  required, no default). Registered, not implemented — no recipe exists to fence.
- **D68-2 (MEDIUM)**: concurrent terraform courts destroying each other's resource groups.
  Current state: **no `terraform destroy` anywhere in CI** — `.github/workflows/infra-dev.yml`
  runs `plan` → guard → `apply tfplan` only (apply job, lines ~111-115); guard sits between
  plan and apply at `infra-dev.yml:113`. If a destroy workflow is ever added, it MUST scope to
  the court-owned prefix `rg-courtroom-*` (names in `infra/environments/dev/platform/main.tf:28`
  and `infra/environments/dev/access/main.tf:70,74`) and refuse otherwise — same pattern as
  F2's RG-prefix scoping. Registered.

### 4. guard_local_apply — ALREADY FENCED (cited), one footgun found and FIXED this session
- Existing fence: `scripts/guard_local_apply.sh:51` (apply/destroy gate),
  `:78` (stripped-backend refusal, `.terraform/terraform.tfstate` check), SMALT_LOCAL=1 hatch
  at `:59`. CI enforcement: `infra-dev.yml:58-59` (non-vacuity court) and `:113` (guard before
  apply); backend-strip diff gate at `:66`. Court: `scripts/guard_local_apply_test.sh` —
  7 cases pre-session, 10 post-fix.
- **D68-3 (HIGH) — FIXED this session**: `terraform destroy -auto-approve` on an initialized
  backend root passed the guard with zero friction (only bare `apply`/`destroy` from a stripped
  root were fenced). An unattended destroy of real Azure resources needs zero interaction.
  Fix implemented in `scripts/guard_local_apply.sh` (new `(b2)` check, block after the
  SMALT_LOCAL hatch): `destroy` carrying `-auto-approve`/`-auto-approve=true` → exit 1 with
  typed `[GUARD-LOCAL-APPLY-REFUSE]`; interactive destroy still passes (tf prompts); the
  SMALT_LOCAL=1 hatch is evaluated first and still bypasses. Non-vacuity: 3 new court cases
  in `scripts/guard_local_apply_test.sh` (refused / interactive passes / hatch bypass), all
  PASS; the court's own cleanup trap (`rm -rf $TMP` on a `mktemp -d`, `test.sh:19`) is scoped
  to its own fixture dir.
- Residual (registered, D68-4 LOW): guard accepts `destroy` with any *other* passthrough flags
  (e.g. `-refresh=false`); terraform's own interactive prompt remains the only fence. Acceptable
  because terraform's typed prompt is a real fence.

### 5. lane-clean (`06-lane-cleanup`) — loudly-MIXED
No `06-lane-cleanup` doc or `lane-clean` recipe exists in this repo. The only `rm -rf` in
`scripts/` is the court's own `mktemp -d` cleanup trap (`guard_local_apply_test.sh:19`), which
is correctly scoped to a per-run temp dir. **No footgun here.** (The rule from
[[same-checkout-fanout]] cleanup law — coordinator deletes lane build roots at integration —
has no mechanical surface here because there are no lane build roots; registered as N/A.)

## Summary table

| id | surface | severity | disposition |
|---|---|---|---|
| D68-1 | future kind-down shared-cluster deletion | MEDIUM | REGISTERED (fix pattern stated) |
| D68-2 | concurrent-court destroy RG collision | MEDIUM | REGISTERED (prefix `rg-courtroom-*`) |
| D68-3 | destroy -auto-approve unfenced | HIGH | **FIXED** (guard b2) + court cases |
| D68-4 | destroy with other passthrough flags | LOW | REGISTERED (tf interactive prompt fences) |

## Standing

ALIVE: audit complete over every named surface; 1 HIGH footgun fixed with non-vacuity receipt
(10/10 court PASS exit 0, run this session on `scripts/guard_local_apply_test.sh`); 3
registered divergences with fix patterns. Absent surfaces (posh-clean, make -C posh clean,
kind-down, lane-clean) are loudly-MISSING, never silent skips.
