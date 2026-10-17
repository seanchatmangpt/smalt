# smalt trust shim (v2)

Zero-touch darwin TLS trust for loopback smalt dev certs. A minimal C dylib
(`smalt_trust_shim.dylib`, gitignored; source committed) injected via
`DYLD_INSERT_LIBRARIES` interposes FOUR Security.framework surfaces:

- **v1 (enforcement)**: `SecTrustEvaluateWithError` (modern) and
  `SecTrustEvaluate` (legacy) — the verdict functions. The full
  leaf-pin + loopback gate lives here.
- **v2 (anchor enumeration)**: `SecTrustCopyAnchorCertificates` and
  `SecTrustSettingsCopyCertificates` (user/admin/system domains). These carry
  NO trust-object argument, so the leaf/loopback gates cannot be evaluated
  there; instead the gate is the launcher env CONTRACT (BOTH `SMALT_CA_FILE`
  and a leaf pin present). When allowed, the pinned CA is appended (+1) to
  the returned array — allocated `CFMutableArray` copy, append retains the
  cert, balanced by the process-lifetime CA cache (no leak, no over-release,
  per-handshake safe).

**Which symbols Go actually reads (witnessed, go1.23.4 darwin/arm64,
`$(go env GOROOT)/src/crypto/x509/root_darwin.go`)**: Go's `systemVerify`
calls `SecCertificateCreateWithData` -> `SecTrustCreateWithCertificates` ->
`SecTrustSetVerifyDate` -> **`SecTrustEvaluateWithError`** ->
`SecTrustGetCertificateCount/Index`. Go does NOT call
`SecTrustCopyAnchorCertificates` or `SecTrustSettingsCopyCertificates`.
So for Go binaries the v1 evaluate interpose IS the enforcement surface
(`-sysroot` legs prove it on the real `crypto/tls` `RootCAs=nil` dial);
the v2 anchor interposes are the honest-coverage surface for clients that
enumerate anchors. The v1 `SecTrustEvaluateWithError` interpose remains for
cgo clients (probe leg 2).

**Anchor-append does not grant trust by itself** (negative leg 8): a process
with only `SMALT_CA_FILE` exported still fails system verification — trust
still requires the leaf pin + loopback gate at the evaluate interposes.

Trust is granted ONLY when ALL hold:

1. **Loopback only**: decided from the leaf SAN set — `localhost`,
   `127.0.0.1`, `::1`. The trust object does not expose the policy hostname
   via public API, so the leaf SAN is the channel; a readable SAN set
   without a loopback entry REFUSES (falls through to the real function,
   normal x509 failure). Unreachable -> fall through. Non-loopback: always
   fall through. (Witnessed: a cert with only `evil.example`/`portal.azure.com`
   SANs still fails with the shim active and the pin matching.)
2. **EXACT-LEAF pin (H1 fix, 2026-10-16)**: certificate [0] of the PRESENTED
   chain must byte-match (SHA-256) the pinned fingerprint — `SMALT_LEAF_SHA256`
   (preferred) or `SMALT_CA_SHA256` (back-compat env read; launchers now set
   both to the leaf fp). Colons/case ignored. Mismatch -> real function ->
   normal x509 failure. Not a blanket bypass.

   **Why leaf, not CA (H1)**: the previous rule trusted on PRESENTED-chain
   MEMBERSHIP — an attacker minting a self-signed leaf with SAN localhost and
   appending the PUBLIC smalt CA cert passed both gates with NO private key
   (every shim-injected process trusted the attacker chain). Membership
   scanning is removed; matching cert[0] requires presenting the exact leaf,
   which only the smalt dev CA private key can produce. The loopback-SAN gate
   is kept as defense-in-depth.

**Pin the leaf** (the smalt dev cert the server actually presents):

```bash
openssl x509 -in .smalt/tls/dev-cert.pem -noout -fingerprint -sha256 | cut -d= -f2
```

## Build

```bash
scripts/trust_shim/build.sh    # -> scripts/trust_shim/smalt_trust_shim.dylib
```

## Use

```bash
LEAF_FP=$(openssl x509 -in .smalt/tls/dev-cert.pem -noout -fingerprint -sha256 | cut -d= -f2)
DYLD_INSERT_LIBRARIES=$PWD/scripts/trust_shim/smalt_trust_shim.dylib \
SMALT_LEAF_SHA256="$LEAF_FP" \
  <ad-hoc / non-hardened binary>
```

## Codesigning constraint

`DYLD_INSERT_LIBRARIES` is ignored for hardened-runtime binaries. Go
release binaries are ad-hoc signed and non-hardened — they qualify.
Verify (witnessed: `flags=0x20002(adhoc,linker-signed)`, no `runtime`):

```bash
codesign -dv --verbose=2 <binary> | grep -i flags
# "runtime" flag present => hardened => shim will NOT inject
```

## Launchers (integrated zero-touch path, 2026-10-16)

The tf tooling never requires keychain trust. Integration contract per the
operator ruling:

- `scripts/smalt-tf` — builds the shim if missing (calls `build.sh`), exports
  `DYLD_INSERT_LIBRARIES` + `SMALT_LEAF_SHA256` (sha256 of
  `.smalt/tls/dev-cert.pem`; `SMALT_CA_SHA256` kept as back-compat alias)
  around terraform. Keychain add-trusted-cert is
  FALLBACK ONLY when the shim is unavailable on darwin (opt-in persistent
  trust, never a gate). Non-darwin: loud skip (SSL_CERT_FILE carries the CA).
- `scripts/bootstrap_env.sh` stage 3 — gate = shim probe PASS
  (`go run test/trust_shim_probe/main.go -want=pass` under the shim env).
  Keychain trust shown as an optional persistent alternative; never a blocker.
- `scripts/tf_smoke.sh` / `tf_plan_check.sh` / `tf_enclave_loop.sh` /
  `tf_cleanroom.sh` — SMALT_CA_SHA256 + DYLD env exported for terraform
  stages; keychain status informational.
- `scripts/gen_dev_cert.sh` mints SKI+AKI on CA and leaf — REQUIRED: Apple's
  strict evaluator drops a SKI-less chain at the leaf ("certificate is not
  standards compliant"), which made the CA-fingerprint pin unmatchable.

## Proof harness — 12 legs, all exit 0 when green

`test/trust_shim_probe/` (Go + cgo). v1 verdict legs use a REAL
Security.framework evaluation (`SecTrustEvaluateWithError` via cgo) over the
presented chain with a fresh per-run EXCLUSIVE poison anchor
(`SecTrustSetAnchorCertificatesOnly`) — hermetic baseline, keychain state
cannot fake the flip. v2 adds the real Go system-verification dial
(`-sysroot`: `crypto/tls`, `RootCAs=nil`, no cgo orchestration) and direct
witnesses for the two anchor-enumeration interposes.

Server chain modes: `real` (smalt dev leaf + CA), `forge` (SELF-MADE leaf
with SAN localhost + the PUBLIC smalt CA — the H1 attacker chain), `evil`
(non-loopback SANs only).

```bash
T=$PWD/.smalt/tls
P=$(cd test/trust_shim_probe && go build -o /tmp/trust_shim_probe . && echo /tmp/trust_shim_probe)
LEAF_FP=$(openssl x509 -in $T/dev-cert.pem -noout -fingerprint -sha256 | cut -d= -f2)
S=$PWD/scripts/trust_shim/smalt_trust_shim.dylib

# 1. BEFORE, no shim: Security.framework rejects the smalt dev chain
$P -want=fail -tls-dir $T
# 2. AFTER, shim + correct LEAF pin: accepted  <- the non-vacuity flip
DYLD_INSERT_LIBRARIES=$S SMALT_LEAF_SHA256="$LEAF_FP" $P -want=pass -tls-dir $T
# 3. NEGATIVE, shim + wrong pin: rejected (pin is not vacuous)
DYLD_INSERT_LIBRARIES=$S \
SMALT_LEAF_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
$P -want=fail -tls-dir $T
# 4. NON-LOOPBACK SAN, shim + correct pin: rejected (loopback gate)
DYLD_INSERT_LIBRARIES=$S SMALT_LEAF_SHA256="$LEAF_FP" $P -want=fail -mode evil -tls-dir $T
# 5. FORGE (the H1 attack), shim + correct pin: REJECTED (exact-leaf pin)
DYLD_INSERT_LIBRARIES=$S SMALT_LEAF_SHA256="$LEAF_FP" $P -want=fail -mode forge -tls-dir $T
# 6. SYSROOT, no shim: real Go system verification rejects
$P -want=fail -sysroot -tls-dir $T
# 7. SYSROOT, shim: real Go dial (RootCAs=nil) PASSES where v1 failed
DYLD_INSERT_LIBRARIES=$S SMALT_LEAF_SHA256="$LEAF_FP" SMALT_CA_FILE=$T/ca-cert.pem \
$P -want=pass -sysroot -tls-dir $T
# 8. SYSROOT, anchor env WITHOUT pin: still rejected (anchor append alone
#    grants nothing — enforcement stays at the evaluate interposes)
DYLD_INSERT_LIBRARIES=$S SMALT_CA_FILE=$T/ca-cert.pem $P -want=fail -sysroot -tls-dir $T
# 9. ANCHORS, no shim env contract: pinned CA absent (n=158)
SMALT_CA_FILE=$T/ca-cert.pem $P -want=fail -anchor-probe
# 10. ANCHORS, shim: pinned CA PRESENT (n=159)  <- the v2 anchor flip
DYLD_INSERT_LIBRARIES=$S SMALT_LEAF_SHA256="$LEAF_FP" SMALT_CA_FILE=$T/ca-cert.pem \
$P -want=pass -anchor-probe
# 11. SETTINGS, no shim env contract: pinned CA absent from all domains
SMALT_CA_FILE=$T/ca-cert.pem $P -want=fail -settings-probe
# 12. SETTINGS, shim: pinned CA present (user 3->4, system 155->156)
DYLD_INSERT_LIBRARIES=$S SMALT_LEAF_SHA256="$LEAF_FP" SMALT_CA_FILE=$T/ca-cert.pem \
$P -want=pass -settings-probe
```

Exit 0 = leg matched its `-want`; 1 = mismatch; 2 = transport/setup failure.
The AFTER legs (2, 7, 10, 12) are the non-vacuity flips; legs 3-6, 8, 9, 11
prove every gate refuses (LEG 5 is the H1 regression gate: under the old
chain-membership rule this leg PASSED the attacker chain — witnessed).

## Hardened-runtime delivery (corrected per shim-v2-verification.md, 2026-10-16)

The previous version of this section was WRONG in both directions. The
corrected, witnessed boundary (evidence of record:
`docs/jira/v26.10.16/sdk-results/shim-v2-verification.md` section 2):

- **Hardened binaries DO load the shim when launched directly.** homebrew
  `terraform` v1.14.6 (`/opt/homebrew/bin/terraform`) and the mirror azurerm
  provider `terraform-provider-azurerm_v4.54.0_x5` are BOTH
  `flags=0x10000(runtime)` (hardened, TeamIdentifier D38WU7D763 — the
  terraform CLI is NOT ad-hoc, the earlier "ad-hoc CLI" claim was false on
  this host). Yet with `DYLD_PRINT_LIBRARIES=1`, dyld reports
  `has interposing tuples so cannot be delayed: smalt_trust_shim.dylib` for
  both when launched DIRECTLY with the env set — hardened-runtime does not
  strip `DYLD_INSERT_LIBRARIES` injection on this host (darwin 25.2.0).
- **The real boundary is one exec-level deeper**: dyld consumes and REMOVES
  `DYLD_INSERT_LIBRARIES` from the child environment after applying it
  (`env DYLD_INSERT_LIBRARIES=$S /bin/sh -c 'echo $DYLD_INSERT_LIBRARIES'`
  → empty, witnessed). So the shim covers only DIRECTLY-LAUNCHED LEAF
  processes. `terraform` spawns the provider as a child; the child inherits
  NO shim env, evaluates with real Security.framework, and refuses the dev
  chain. This is why the zero-touch terraform path fails end-to-end.
- Ad-hoc Go binaries built locally (the probe) are
  `0x20002(adhoc, linker-signed)` and all flips above are witnessed there.
- The ad-hoc re-sign workaround still works mechanically
  (`codesign --remove-signature` + `codesign -s -` → `flags=0x2(adhoc)`) but
  breaks the provider dependency-lock checksums (witnessed rc=1: "does not
  match any of the checksums recorded in the dependency lock file") —
  diagnostic-only, not a zero-touch path.
- For the terraform→provider hop the zero-touch path remains the keychain
  opt-in fallback (`scripts/tf_trust_setup.sh trust`); KD candidate filed by
  the verification lane (leaf-only dyld env-strip boundary).

## Witnessed receipts (2026-10-16, darwin 25.2.0, go1.23.4, v2)

```
LEG 1  (no shim, real):            fail ... LEG OK: want=fail got=fail    exit=0
LEG 2  (shim, correct leaf):       pass ... LEG OK: want=pass got=pass    exit=0
LEG 2b (SMALT_CA_SHA256 env):      pass ... LEG OK: want=pass got=pass    exit=0  back-compat
LEG 3  (shim, wrong pin):          fail ... LEG OK: want=fail got=fail    exit=0
LEG 4  (shim, evil SAN):           fail ... LEG OK: want=fail got=fail    exit=0
LEG 5  (shim, forge/H1):           fail ... LEG OK: want=fail got=fail    exit=0
LEG 6  (sysroot, no shim):         fail ... LEG OK: want=fail got=fail    exit=0
LEG 7  (sysroot, shim):            pass ... LEG OK: want=pass got=pass    exit=0  <- v2 flip
LEG 8  (sysroot, anchor env only): fail ... LEG OK: want=fail got=fail    exit=0  negative
LEG 9  (anchors, no contract):     fail ... LEG OK: want=fail got=fail    exit=0
LEG 10 (anchors, shim):            pass ... LEG OK: want=pass got=pass    exit=0  <- v2 flip
LEG 11 (settings, no contract):    fail ... LEG OK: want=fail got=fail    exit=0
LEG 12 (settings, shim):           pass ... LEG OK: want=pass got=pass    exit=0  <- v2 flip
```
