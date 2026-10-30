# M16 — Byte-Identity Guard first run (v26.10.31, lane 16)

- **Date**: 2026-10-30
- **Subject**: `/Users/sac/smalt/scripts/tf_cleanroom.sh`, `/Users/sac/cai/courtroom-platform-az/apps/web` harness suites, `/Users/sac/cai/courtroom-platform-az/infra/environments/dev/platform` TF plan, pinned smalt wire files
- **Standing**: **PARTIAL** — leg 1 ALIVE (exit 0, 8/8); leg 2 BLOCKED (exit 1, backend reinit required, outside lane lease); leg 3 typed SKIP (exit 3, loud, missing required file — guard-spec premise rot)
- **Context**: solo
- **Receipt chain**: `/Users/sac/smalt/docs/jira/posh/v26.10.31/gaps/16-migration-sequencing.md` → this file (guard run witness). Contract: `docs/jira/posh/v26.10.31/gaps/16-migration-sequencing.md` "Byte-Identity Guard (runs at EVERY phase)"

## Guard leg 1 — harness gates (consumer side): ALIVE

Ran from `apps/web` (the guard text names the repo root; `vitest.harness.config.ts` lives at
`apps/web/vitest.harness.config.ts`, so the gaps/16 command as written does not run from root —
spec drift, recorded as a guard correction below).

```
$ cd /Users/sac/cai/courtroom-platform-az/apps/web && npx vitest run --config vitest.harness.config.ts test/harness/tenant test/harness/version
 RUN  v5.0.5 /Users/sac/cai/courtroom-platform-az/apps/web
 ✓ test/harness/tenant/tenant.test.ts (3 tests) 50ms
 ✓ test/harness/version/version.test.ts (5 tests) 1550ms
 Test Files  2 passed (2)
      Tests  8 passed (8)
      Duration  1.71s
EXIT=0
```

## Guard leg 2 — Terraform 0-drift plan: BLOCKED (exit 1)

```
$ cd /Users/sac/cai/courtroom-platform-az && terraform -chdir=infra/environments/dev/platform plan -detailed-exitcode -lock=false -var-file=next
TF_EXIT=1
```
(with `-var-file=dev.tfvars`; full log `/tmp/m16-tfplan.log`)

Typed reason: backend configuration drift — terraform refuses to plan until
`terraform init -reconfigure` (or `-migrate-state`) runs in the consumer repo. That is a
state-touching operation in a repo outside this lane's write lease → **coordinator action**.
Note: an earlier pipe-swallowed reading showed `TF_EXIT=0` because `$?` captured `tail`, not
terraform; the exit 1 above is terraform's real code with output redirected to a file. No drift
verdict is possible this session; leg 2 is BLOCKED, never rounded to PASS.

## Guard leg 3 — tf_cleanroom STS legs: typed SKIP (exit 3, loud)

```
$ bash /Users/sac/smalt/scripts/tf_cleanroom.sh
[SKIP-LOUD] preflight — required file missing: /Users/sac/smalt/test/smalt_ets_baseline_identity_test.exs
============== T5 CLEAN-ROOM RECEIPT ==============
-- stages (monotonic elapsed) --
preflight: terraform binary              PASS                     32ms
-- family rows --
preflight          SKIP-LOUD  required file missing: /Users/sac/smalt/test/smalt_ets_baseline_identity_test.exs
==================================================
[CLEANUP] lane ports free: 39390 39391 39392 39393 39394 39395
CLEANROOM_EXIT=3
```

Typed SKIP per exit contract (3 = harness-skip, loud, never a fake pass). Root cause: the
cleanroom preflight requires `test/smalt_test/smalt_ets_baseline_identity_test.exs`, which does
not exist in the tree (deleted with the v26.10.19 reset at 64f6099 per repo CLAUDE.md) — guard-spec
premise rot, not a substrate fault. The STS POST legs named by gaps/16 (tf_cleanroom.sh lines 291
and 527 — zero-state token leg and real-client token leg, both `POST /{tenant}/oauth2/v2.0/token`)
are present at exactly those lines today; they never executed because preflight SKIP'd first.

## Pin set (computed this session)

| File | sha256 |
|---|---|
| `lib/smalt/arm_gateway/plug/oidc_sts.ex` | `20867639168e334c927ac04d8622c0d8fd93f9156cbee145c265ec714e9e2ae6` |
| `lib/smalt/identity/oidc_idp.ex` | `8fc6ad22565a27e9d25899d98b1191cfbffe10288844c5934c7e67ed0b54e953` |

Guard-spec drift correction: gaps/16 names `lib/smalt/arm_gateway/plug/oidc_idp.ex` — that path
does not exist; the real file is `lib/smalt/identity/oidc_idp.ex` (pinned above). The P0 baseline
set also names the Go provider binary + `~/.terraformrc` dev_overrides; those are consumer-repo
artifacts and were not pinned this session (P0 exit gate not claimed).

## Falsifier — guard non-vacuity (scratch-copy tamper probe)

Copied `oidc_sts.ex` to `/tmp/m16-tamper/` (repo untouched), flipped one byte at offset 100:

```
BEFORE=20867639168e334c927ac04d8622c0d8fd93f9156cbee145c265ec714e9e2ae6
AFTER=a0eacfc384687a0ee214066d4146fc2e81f1e856541225977e51c1b88118d925
PIN-CHECK: FAIL (guard can go red) — tamper detected
```

The guard CAN go red; a pin check that passes on a tampered copy would be vacuous. Repo file
untouched (byte flip was on the scratch copy only).

## Phase verdicts

- **P0**: PARTIAL — leg 1 PASS; leg 2 BLOCKED (backend reinit, coordinator); leg 3 typed SKIP
  (missing required file; re-run blocked until the file is re-authored or the preflight pin is
  updated). P0 exit gate ("all three guard legs pass") NOT met.
- **P1–P3**: UNVERIFIED (input lanes open).
- **P4**: UNSUPPORTED (no admitted work order; deferred by decision record).

## Guard-runnability findings (for the next phase)

1. Leg 1 command must run from `apps/web`, not the repo root (config path in gaps/16 is wrong).
2. Leg 3 preflight pins a file that no longer exists (`test/smalt_ets_baseline_identity_test.exs`);
   either re-author the test or update the preflight to a file that exists — otherwise every
   guard run SKIPs loudly at preflight and the STS legs are unreachable.
3. Pin path correction: `plug/oidc_idp.ex` → `identity/oidc_idp.ex`.
4. Leg 2 requires `terraform init -reconfigure` in the consumer repo before any 0-drift verdict is
   possible.

---

# M16 — Byte-Identity Guard second run (2026-10-30, wave-2 gap lane: preflight re-pin + rerun)

- **Standing**: **PARTIAL** — leg 1 ALIVE (exit 0, 8/8); leg 2 still BLOCKED (unchanged, terraform-init decision pending — NOT run, per lease); leg 3 **preflight SKIP removed, typed FAIL at stage 3** (pre-existing class, see below)
- **Context**: solo

## Fixes landed this run

1. `scripts/tf_cleanroom.sh` preflight re-pinned: the deleted
   `test/smalt_ets_baseline_identity_test.exs` (removed with the v26.10.19 reset, 64f6099; it was
   stress-tier with no successor) is replaced by a direct STS-face pin —
   `lib/smalt/arm_gateway/plug/oidc_sts.ex` + `lib/smalt/identity/oidc_idp.ex`. Preflight requires
   both files and records their sha256s; stage 8b re-checks them within the run (mid-run tamper
   FAILs the run). Stage-8 `ets-identity` row is now `sts-face-pin`; comments updated.
   No equivalent baseline-identity test exists to re-pin instead (verified against `test/`).
2. gaps/16 leg-1 command fixed to run from `apps/web` (config path drift).
3. gaps/16 pin-path correction folded into the guard text: `plug/oidc_idp.ex` →
   `lib/smalt/identity/oidc_idp.ex`.

## Guard leg 1 — ALIVE (rerun)

```
$ cd /Users/sac/cai/courtroom-platform-az/apps/web && npx vitest run --config vitest.harness.config.ts test/harness/tenant test/harness/version
 Test Files  2 passed (2)
      Tests  8 passed (8)
EXIT=0
```

## Guard leg 3 — preflight green, typed FAIL at stage 3 (rerun, 2 boots)

```
$ PATH="$HOME/.asdf/shims:$PATH" bash scripts/tf_cleanroom.sh    # log /tmp/m16-leg3-rerun2.log
[SKIP-LOUD] GONE — preflight now emits:
[cleanroom] sts-face pins: oidc_sts.ex=20867639168e334c927ac04d8622c0d8fd93f9156cbee145c265ec714e9e2ae6 oidc_idp.ex=8fc6ad22565a27e9d25899d98b1191cfbffe10288844c5934c7e67ed0b54e953
preflight: fixture + sts-face pins + mix.exs PASS
stage1: fresh substrate up (ARM 39390, zero state) PASS   102212ms
stage2: trust-shim probe gate PASS
stage3: tf init (offline mirror) PASS
FAULT: terraform plan failed: ... tls: failed to verify certificate:
  x509: certificate signed by unknown authority
  (provider azurerm dialing https://127.0.0.1:9444 — the SHARED twin, not the lane twin 39391)
LEG3_EXIT=1
```

First rerun attempt also exposed a second, unrelated blocker: bare `mix` on PATH is Homebrew
Elixir 1.19.5 vs the pinned 1.20.4-otp-29 (substrate boot refused, typed FAIL) — the ladder
needs the asdf shims on PATH (`PATH="$HOME/.asdf/shims:$PATH"`), matching the repo toolchain
pin in CLAUDE.md.

**Typed-FAIL class is PRE-EXISTING, not introduced by this lane**: the same stage-3
provider-TLS trust failure is on record in
`docs/jira/v26.10.16/receipts/t5-cleanroom-validation.md` ("SUSPECT — FAIL (typed),
BLOCKED-TRUST, reproducible at stage 3 apply"), carried PENDING in v26.10.17 FINAL. The Go
provider on darwin does not honor `SSL_CERT_FILE` (system verifier), so the ladder's
SSL_CERT_FILE wiring cannot authenticate the twin; stage 2's trust-shim probe passes without
installing the lane CA system-wide. Out of this lane's lease (guard-runnability fixes only);
STANDING BLOCKER for a leg-3 PASS verdict.

**STS legs witness (substitute, real transport)**: the STS POST legs the ladder guards
(now at `tf_cleanroom.sh` lines 300 and 536, `POST /{tenant}/oauth2/v2.0/token`) were exercised
directly against the pinned face on the shared substrate:

```
$ curl -sS -X POST http://localhost:9443/00000000-...-0000/oauth2/v2.0/token \
    -d grant_type=client_credentials -d client_id=... -d client_secret=... \
    -d resource=https://management.azure.com
HTTP=200  token_type=Bearer  expires_in=3600  has_access_token=True
```

## Falsifier — non-vacuity re-proven this run

Tamper probe (scratch copy, byte 100 flipped, repo untouched):

```
BEFORE=20867639168e334c927ac04d8622c0d8fd93f9156cbee145c265ec714e9e2ae6
AFTER=b1e01b733b0f0a57727a1d354c67ff926612a1869b0fdf6fffe6b863808d9a41
PIN-CHECK: FAIL (tamper detected — guard can go red)
```

## Phase verdicts (after this run)

- **P0**: PARTIAL — leg 1 PASS; leg 2 BLOCKED (unchanged, coordinator); leg 3 preflight-green,
  typed FAIL at stage 3 on the pre-existing darwin provider-trust blocker. Exit gate NOT met.
- **Falsifier / non-vacuity**: ALIVE (fresh probe this run).

## Guard-runnability findings (remaining)

1. Leg 3 PASS requires resolving the darwin Go provider x509 trust chain (trust-shim must
   actually install the lane CA, or the mirror must carry a provider build that honors
   SSL_CERT_FILE) — coordinator action, pre-existing since v26.10.16.
2. Leg 2 unchanged: `terraform init -reconfigure` decision pending.
