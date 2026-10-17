# Shim v2 verification (independent audit lane, 2026-10-16)

- Date: 2026-10-16
- Lane: validation (Agent 10, Ring 4), MIX_BUILD_ROOT=_build-lane508
- Subject: `/Users/sac/smalt` v26.10.16 working tree — `scripts/trust_shim/`
  (dylib rebuilt this run, sha256 `e62ae8c2f743c708f631cc81713745c94d221f93499e818d013840bd5c275171`)
- Probe: `test/trust_shim_probe` (go build → /tmp/trust_shim_probe, go1.23.4 darwin/arm64)
- Leaf pinned: on-disk `.smalt/tls/dev-cert.pem` fp
  `F4:C3:2F:2D:80:8C:0F:AF:9F:63:E4:AE:D6:AE:6B:95:0A:48:CE:BC:D2:5D:7D:64:8F:3A:AE:67:E4:18:BC:12`
  (byte-matched the leaf served by the running substrate on 9444 — verified via `openssl s_client`).

## Verdict

- **12-leg probe harness: 13/13 GREEN on the current tree** (12 legs + back-compat
  LEG 2b). The v2 lane's promised `-anchor-probe` / `-settings-probe` coverage is
  genuinely implemented in `test/trust_shim_probe/main.go` (flags `-anchor-probe`
  line 61, `-settings-probe` line 63, `-sysroot` line 59, forge/evil modes line 331)
  — not just promised. All flips witnessed live this run.
- **Hardened-runtime boundary: the README's boundary statement is WRONG in both
  directions** (detailed below).
- **Zero-touch terraform path: DOES NOT WORK end-to-end.** The existing
  `tf-plan.md` receipt's six DIVERGENCE rows are not ARM-shape divergences —
  all six are the same x509 refusal (`tls: failed to verify certificate: x509:
  "127.0.0.1" certificate is not standards compliant`). The shim never reaches
  the provider. Standing of the zero-touch terraform delivery path: **FAIL**.
- Verification receipt standing: **PASS** (executed, live output; negatives witnessed).

## 1. Leg matrix (executed 2026-10-16, current tree)

| Leg | Surface | Want | Got | rc |
|---|---|---|---|---|
| 1 | no shim, real Security eval | fail | fail | 0 |
| 2 | shim + exact-leaf pin | pass | pass | 0 |
| 2b | shim + `SMALT_CA_SHA256` back-compat env | pass | pass | 0 |
| 3 | shim + wrong pin | fail | fail | 0 |
| 4 | shim + non-loopback (`evil`) SAN | fail | fail | 0 |
| 5 | shim + forge/H1 attacker chain | fail | fail | 0 |
| 6 | `-sysroot`, no shim | fail | fail | 0 |
| 7 | `-sysroot`, shim | pass | pass | 0 |
| 8 | `-sysroot`, anchor env w/o pin | fail | fail | 0 |
| 9 | `-anchor-probe`, no env contract | fail | fail |  implemented + green |
| 10 | `-anchor-probe`, shim (n 157→158) | pass | pass | 0 |
| 11 | `-settings-probe`, no env contract | fail | fail |  implemented + green |
| 12 | `-settings-probe`, shim (settings map 0:2→, n=157→158 anchors) | pass | pass | 0 |

Audit note (honest): in my FIRST batch run, LEG 9/11 mismatched
(want=fail got=pass); with explicit `DYLD_INSERT_LIBRARIES=` hygiene the same
legs are green in a single shell and in fresh shells. Not reproducible after
env hygiene; the correct contract result is the green matrix above.

## 2. Hardened-runtime boundary — corrected statement

Empirical, darwin 25.2.0:

1. `terraform` v1.14.6 CLI (`/opt/homebrew/bin/terraform`):
   `flags=0x10000(runtime)`, TeamIdentifier D38WU7D763 — **hardened, NOT ad-hoc**
   (the task's "CLI is ad-hoc?" premise is false on this host; witnessed).
2. Mirror azurerm provider `terraform-provider-azurerm_v4.54.0_x5`:
   `flags=0x10000(runtime)`, TeamIdentifier D38WU7D763 — **hardened**.
3. **Injection is NOT stripped** on these hardened binaries as the README
   claims: with `DYLD_PRINT_LIBRARIES=1`, dyld reports
   `has interposing tuples so cannot be delayed: smalt_trust_shim.dylib` for
   BOTH the hardened terraform CLI and the hardened provider when they are
   launched DIRECTLY with the env. The README's "shim does NOT inject" claim is
   refuted on this host.
4. **The real boundary is one exec-level deeper**: dyld consumes and REMOVES
   `DYLD_INSERT_LIBRARIES` from the child environment after applying it
   (`env DYLD_INSERT_LIBRARIES=$S /bin/sh -c 'echo $DYLD_INSERT_LIBRARIES'` →
   empty, witnessed). So the shim covers only directly-launched LEAF processes.
   `terraform` spawns the provider as a child; the child inherits NO shim env,
   evaluates with real Security.framework, and refuses the dev chain. This is
   the actual reason the zero-touch terraform path fails.
5. `SMALT_SHIM_DEBUG=1` under a full plan run: zero `[shim]` lines from the
   provider (consistent with 3-4).

## 3. Ad-hoc re-sign workaround — honest, with lock-checksum consequence

- `codesign --remove-signature` + `codesign -s -` on the provider:
  `flags=0x2(adhoc)`, and direct-launch injection then witnesses
  (`DYLD_PRINT_LIBRARIES` shows the shim load; binary sha256 changes
  `37fa817e…` → `14b7cb72…`).
- **Lock checksum consequence (witnessed)**: with the re-signed plugin cached in
  `.terraform/providers`, `terraform plan` exits **rc=1**:
  `the cached package … does not match any of the checksums recorded in the
  dependency lock file`. Diagnostic-only; every re-sign breaks the lock and
  forces a lock refresh / re-fetch. Zero-touch it is not.
- The mirror at `test/terraform_fixture` was NOT mutated (work done on a
  /tmp copy; mirror provider sha256 still `37fa817e…`).

## 4. Real terraform metadata/STS surface under the shim — negative

Full `terraform plan` against the live main substrate (ARM 9443 / TLS twin 9444,
auth `:enforce`, provider pins matching the served leaf) with the full shim env
exported around `terraform`:

- rc=1, `Error: retrieving metadata from endpoint "https://127.0.0.1:9444":
  performing request: Get "https://127.0.0.1:9444/metadata/endpoints?api-version=2022-09-01":
  tls: failed to verify certificate: x509: “localhost” certificate is not trusted`
- Served leaf fp == pinned fp (verified before/after), so this is not a pin
  mismatch — the provider evaluated with REAL Security.framework (the shim
  never reached it).
- Cross-check: the committed `tf-plan.md` receipt (lane 332) shows the same
  failure class on all six per-resource fixtures
  (`x509: "127.0.0.1" certificate is not standards compliant`), mislabeled as
  TYPED DIVERGENCE. Those rows are transport (trust-delivery) refusals, not
  ARM-shape divergences. Recommend re-classifying that receipt and filing a KD
  row for the dyld env-strip boundary.
- Note: `SSL_CERT_FILE` does not help here — go1.23.4 `crypto/x509` on darwin
  loads roots via Security.framework and ignores it (consistent with root_darwin.go).

## 5. Tier matrix (which surface requires what)

| Surface | Tier required | Zero-touch? |
|---|---|---|
| Probe harness (ad-hoc Go binaries), 13 legs | leaf-process DYLD | yes |
| `scripts/smalt-tf` / tf launchers around `terraform` | leaf-only DYLD — does NOT reach the provider | **no** |
| Hardened binaries launched directly | DYLD honored on this host (README wrong) | yes |
| terraform → provider (the real path) | keychain opt-in trust (`scripts/tf_trust_setup.sh trust`) or lock-breaking re-sign | **no** zero-touch path exists |
| `terraform init` lock check | original signed provider | n/a |

## KD candidates (for registrar, not filed by this lane)

- dyld strips `DYLD_INSERT_LIBRARIES` at the first exec boundary → shim covers
  leaf processes only; terraform→provider delivery is structurally impossible
  via launcher env export. (Close condition: keychain opt-in trust path
  e2e-witnessed green, or per-child injection mechanism.)
- `tf-plan.md` DIVERGENCE rows are x509 transport refusals, not ARM divergences.
