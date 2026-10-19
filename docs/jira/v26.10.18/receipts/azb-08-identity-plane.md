# AZB-08 — Identity plane profile (KeyVault + Entra STS) — RECEIPT

- **Ticket**: AZB-08 (docs/jira/v26.10.18/azsim-burn/TICKETS.md)
- **Lane**: planes · **Standing**: PASS (disclosures below)
- **Date**: 2026-10-18
- **Subject**: HEAD `6cb7397` (`6cb73975c5341f4147c405c3b49f5b74dfee63a9`) — clean tree at receipt time; the coordinator folded the lane's in-flight edits into commits `be81187` (planes wave), `a932816` (AZB-09), `2a82b29`, `6f17c6e`, `bcd1e3c`
- **Scope note**: `config/env/az_prod_identity.exs` was seeded by AZB-04 (exact AZB-08 spec values already present: `api_version: "7.4"`, `challenge_mode: :strict_bearer`, `token_ttl_seconds: 3600`, `pki_envelope: :pqc_hybrid`) — this ticket wired the read sites; the profile file itself is unchanged. `git check-ignore` shows `config/env/` is gitignored (`env/`, .gitignore:53) — the profile files live untracked by the AZB-04 arrangement.

## Diffs (all within ticket scope + disclosed extensions)

| File | Change |
|---|---|
| `lib/smalt/auth/bearer.ex` | AZB-08 read sites: `kv_challenge_mode/0` (profile key `:keyvault, challenge_mode`, default `:strict_bearer`) + injected verify clock `clock_now/0` (`:smalt, :sts_clock` integer-seconds override; default wall clock, prod never sets it — clock MOVED, never slept) |
| `lib/smalt/egress_router.ex` | `kv_challenge_guard/2` consults `Smalt.Auth.Bearer.kv_challenge_mode() == :strict_bearer` (default byte-identical boot); `check_akv_api_version/1` refusal message now names the configured `api_version` (single source) |
| `lib/smalt/data_plane/key_vault_actions.ex` | Profile read sites `api_version/0` + `challenge_mode/0` over `Smalt.Config.keyvault()` (ontology-projected accessor — no hand-written config source) |
| `lib/smalt/arm_gateway/router.ex` | `issue_token/2` honors `:sts, token_ttl_seconds` (default 3600 — pinned STS mint contract exp-iat==3600 kept byte-identical on `:all` boot); `expires_in`/`ext_expires_in` echo the configured ttl. DISCLOSED scope extension: read site lives in arm_gateway (not in the ticket's file list) because the TTL is mint-side; +7 lines |
| `lib/smalt/application.ex` | TLS-twin egress prefixes gained `"/secrets"`, `"/kv"` (additive; the lane-345 secrets surface postdated the twin prefix list — /secrets 404'd on 9444 before, so the real-SDK acceptance leg was unreachable over TLS). DISCLOSED scope extension (1 file, 2 lines); preserved through the AZB-09 rewrite of this file. ARM top-level prefixes unaffected |
| `test/azsim/identity_plane_test.exs` | NEW: 12 tests — profile-file pins, accessor defaults byte-identical, guard-vs-Bearer refusal-class distinction, KD-15 byte-equal challenge both modes + grammar + origin echo + no `authorization_uri`, STS TTL honored (1234) and default 3600 pinion, injected-clock expiry (admit at now+30 / refuse TokenExpired at exp+1), rotation (new version, old version still decrypts, GET latest), versions listing, api_version refusal-message read site |
| `test/sdk-full/secrets.probe.mjs` | NEW: real `@azure/keyvault-secrets` (`^4.9`, npm-installed) set/get round-trip through the challenge-based handshake |
| `test/sdk-full/package.json`/`package-lock.json` | `@azure/keyvault-secrets` dependency (npm, 2 packages) |
| `test/support/lifecycle.ex` | SLA unblock fix (DISCLOSED, another lane's in-flight file): doc-comment interpolation referenced an unbound `prefix` variable — compile-aborted the whole test tree; replaced `\#{prefix}` with a literal `<prefix>-...` in the @doc. Text-only, no code semantics |

## Ontology / smalt.gen

`ck-keyvault` / `ck-sts` ConfigKey rows already in the pack ontology (AZB-04). Replay-identity witnessed this session:

```
$ sha256sum lib/smalt/config.ex && mix smalt.gen && sha256sum -c /tmp/azb8-config-before.sha
67baae56366dc71df788cdd1e15821b51fba1cc34f70a953de3396d4833947dc  lib/smalt/config.ex
lib/smalt/config.ex: OK
```

(byte-identical regen; no hand-edit; `git status` clean on all six projected artifacts after regen)

## Accept — real output

### 1. Identity plane court (exit 0, three consecutive clean-tree runs; final at HEAD)

```
$ MIX_BUILD_ROOT=_build-ft-azb8c scripts/fast_test.sh test/azsim/identity_plane_test.exs
...
12 tests, 0 failures
EXIT=0
```

Faces: profile pins + port-single-source refute; accessor defaults byte-identical
(profile absent → same values); `challenge_mode: :relaxed` steps the mode-blind
guard aside (Bearer answers `MalformedBearerHeader`, guard's
`MissingBearerToken` absent) — the profile key is a REAL read site, not a
no-op; byte-equal challenge across `:enforce`/`:anonymous` + KD-15 grammar
(`error="invalid_token"`, `error_description="MissingBearerToken"`,
`^Bearer authorization="..."`, `resource=` echoing origin, no
`authorization_uri`); TTL 1234 honored (exp-iat, expires_in, ext_expires_in)
and default-3600 pinion; injected-clock admit@now+30 / refuse-TokenExpired@exp+1
(zero Process.sleep); rotation: v1 kid != v2 kid, v1 ciphertext decrypts under
`/keys/{name}/{v1}/decrypt`, GET `/keys/{name}` kid == v2 kid; versions listing
carries both kids.

### 2. Real @azure/keyvault-secrets SDK set/get round-trip — PASS

```
$ cd test/sdk-full && npm install @azure/keyvault-secrets@^4.9.0
added 2 packages in 3s
$ NODE_TLS_REJECT_UNAUTHORIZED=0 node secrets.probe.mjs
[set] azb8-sdk-1792372566811 ok
[get] name=azb8-sdk-1792372566811 value-match=true
PASS azb8-sdk-secrets-roundtrip
EXIT=0
```

- Real SDK, challenge-based handshake (no injected Authorization header; the
  substrate's KD-15 enriched challenge drives the SDK's own token attach).
- Substrate via `scripts/substrate.sh up` (exit 0; 9443/9444/5672/5673 UP).
- Honest note: `NODE_EXTRA_CA_CERTS` did NOT establish trust on Node 26
  (loopback-IP vs hostname-SAN mismatch) — the run uses the loopback TLS
  bypass (`NODE_TLS_REJECT_UNAUTHORIZED=0`), same class as the existing
  probes' `allowInsecureConnection`/`disableChallengeResourceVerification`.
  Recorded, not hidden.

### 3. Neighbor surfaces at HEAD (my changed surfaces, isolated runs)

```
$ MIX_BUILD_ROOT=_build-ft-azb8 scripts/fast_test.sh test/auth_enforce_test.exs
128 tests, 0 failures     (bearer sub-code table + STS mint pinions — green, pinions intact)
$ MIX_BUILD_ROOT=_build-ft-azb8b scripts/fast_test.sh test/egress_dispatch_test.exs
107 tests, 0 failures     (KD-15 challenge + InvalidQueryParameterValue pinions — green)
```

## Falsifier + Anti-vacuity — WITNESSED (real shim courts)

### SHIM A — anti-vacuity: short-circuit challenge in :anonymous

```
BASELINE sha256(lib/smalt/egress_router.ex) = f985675a27d76506ca96591f2d0b205799e2c9b3300963d4d244024d3d5b80ec
SHIM (marker `# SHIM-COURT AZB-08` in kv_challenge_guard):
  anon_short_circuit? = Application.get_env(:smalt, :auth_mode, :enforce) == :anonymous
  ... and not anon_short_circuit?
$ mix test test/azsim/identity_plane_test.exs
12 tests, 2 failures
  1) "challenge guard consults the challenge_mode profile key"
     code: assert res.status == 401   left: 200
  2) "tokenless /keys challenge is byte-equal in :enforce and :anonymous"
     "mode anonymous: expected 401, got 200"
RESTORE sha256sum -c → lib/smalt/egress_router.ex: OK
```

### SHIM B — falsifier: expired token admitted

```
BASELINE sha256(lib/smalt/auth/bearer.ex) = eae3eded2da4fb16915a1cae1c7f585a59eed0c5ee85ae727f59b37b6c23496e
SHIM (marker `# SHIM-COURT AZB-08` in Bearer):
  # SHIM-COURT AZB-08: expired tokens admitted (exp check elided)
  defp expired?(_exp, _now), do: false
$ mix test test/azims/identity_plane_test.exs →
12 tests, 1 failure
  "expired token refused TokenExpired ...": assert res_expired.status == 401; left: 200
RESTORE sha256sum -c → lib/smalt/auth/bearer.ex: OK
```

Both courts FLIP (a court that cannot flip is FAIL); skips: none.

## Full-suite classification (disclosure, not a green claim)

`mix test` (private build root) at time of receipt: `1 doctest, 7 properties,
2686 tests, 25 failures (90 excluded)`, exit 2 — ALL 25 failures sit in
OTHER lanes' in-flight surfaces (enclave lifecycle, pplan durability, TLS,
LRO, McpWire/doctor, StressTierCensus, AZB-05 profile-file test, AZB-10
cross-plane test, AZB-07 integration-plane detach test); ZERO failures in
auth / kv / egress / identity surfaces. Full suite was run under machine
load 230-340 with AZB-05/06/07/09/10 lanes landing concurrently; the full
green ×2 gate belongs to the coordinator's integration wave, not this lane.

## Constraints check

- **`:plane` unset = today's child list**: untouched — `:all` default boot
  byte-identical (default `challenge_mode`/`api_version`/ttl values preserve
  all pinned behavior; falsifier face of AZB-04 stands).
- **Existing config keys one-source**: no new flat keys; profile keys
  (`:keyvault`, `:sts`) read through the ontology-projected
  `Smalt.Config.keyvault()/sts()` accessors; `:sts_authority_url`/`:arm_port`
  untouched; ports stay in flat keys only (test refutes port keys in profile).
- **Ontology + smalt.gen regen**: replay byte-identical (sha256 OK above).
- **test.exs untouched**: `config/test.exs` not modified by this lane
  (`git log` clean; suite-neutral injected clock lives behind
  `Application.get_env(:smalt, :sts_clock)` — unset in every boot).
- **Zero Process.sleep**: clock moved, never slept — no `Process.sleep`
  anywhere in the new test or lib diffs.
- **Pinions verbatim**: bearer sub-code table (auth_enforce 128/0), KD-15
  challenge grammar (byte-equal + grammar asserts green; egress_dispatch
  107/0), STS mint contract (default TTL 3600 pinion test green; claim-set
  untouched).

## Standing

PASS — every Accept face executed with real output; both courts flip and
restore byte-exact; pinions intact at HEAD `6cb7397`.
