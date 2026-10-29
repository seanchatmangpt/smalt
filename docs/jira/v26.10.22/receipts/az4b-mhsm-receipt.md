# AZ-4b — MHSM release-policy face: finish-and-relay court receipt (×2)

**Standing**: ALIVE (policy face) / **UNSUPPORTED** (FIPS-level hardware isolation — no HSM silicon at loopback; falsifier: a real MHSM pool cannot be provisioned on this machine)

**Context**: solo

**Date**: 2026-10-22

## What this receipt adds

AZ-4's MHSM release-policy face was already materially landed and receipted
(`receipts/az4-mhsm-policies.md`, KD-167 CLOSED-WITH-EVIDENCE in
`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:347`, `# KD-COVERS: KD-167` shim at
`lib/smalt/data_plane/skr.ex:75`). This is the finish-and-relay receipt: the
face re-audited from disk and the court proven green TWICE at HEAD under the
current tree.

## Surface (audited from disk)

- `lib/smalt/data_plane/mhsm.ex` — `Smalt.DataPlane.MHSM.evaluate_policy/2`:
  `anyOf` OR over assertion groups; `allOf`/`assertions` AND; `equals`/`contains`
  condition verbs; top-level claim precedence with fallback to the nested MAA
  `x-ms-isolation-tee` object; unknown conditions, unresolvable claims, and
  degenerate empty constraint sets (`anyOf: []`, `allOf: []`, `assertions: []`)
  all REFUSE (fail-closed, never an allow-all); ops-only policy (`allowed_operations`,
  no claim assertions) → `:ok`; `nil` policy → 403 `KeyReleasePolicyViolation`
  (policy-required face).
- `lib/smalt/data_plane/skr.ex:75` — RELEASE evaluates the stored policy BEFORE
  any material derivation or counter burn (`# KD-COVERS: KD-167`); violating
  release = typed **403 KeyReleasePolicyViolation**, key row untouched (no
  keyMaterialVersion burn); policy-less key = typed **400 KeyNotExportable**.
- Keys carry `release_policy` {`exportable: "never"`, `dataExecution: "never"`,
  `anyOf` assertions}; GET `/keys/{name}` echoes it verbatim (R111 face).

## Court — green ×2 at HEAD

`test/internal/az4_mhsm_release_policy_court_test.exs` — 4 legs over the real
TLS twin wire (curl) with a real RS256 signer (`Smalt.Security.ReceiptSigner`),
no mocks:

1. create `rsa-HSM` with restrictive policy → 200; policy stored + GET-echoed
   verbatim; `attributes.exportable=true`
2. in-policy release → 200 `status: "Released"`, `release_policy_applied: true`,
   `keyMaterialVersion: 1`; wrong-assertion release → **403
   KeyReleasePolicyViolation**; next compliant release → `keyMaterialVersion: 2`
   (the violating attempt burned NO version); policy intact on GET
3. policy-less `oct-HSM` key → release → **400 KeyNotExportable**
   (policy-required typed refusal)
4. evaluator negative fixtures: empty `anyOf` → 403; unknown condition verb →
   403; `contains` over unresolvable claim → 403; nested `x-ms-isolation-tee`
   claim resolves; ops-only policy → `:ok`; nil policy → 403

Negative fixtures are REFUSED, not skipped.

Run 1 (verbatim):

```
$ PATH=$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$HOME/.asdf/installs/erlang/29.1.2/bin:$PATH \
  MIX_BUILD_ROOT=_build-lane-az4b mix test test/internal/az4_mhsm_release_policy_court_test.exs
Finished in 0.3 seconds (0.00s async, 0.3s sync)

Result: 4 passed
```

Run 2 (verbatim):

```
$ PATH=$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$HOME/.asdf/installs/erlang/29.1.2/bin:$PATH \
  MIX_BUILD_ROOT=_build-lane-az4b mix test test/internal/az4_mhsm_release_policy_court_test.exs
Finished in 0.3 seconds (0.00s async, 0.3s sync)

Result: 4 passed
```

exit 0 both runs.

Compile (verbatim):

```
$ PATH=... MIX_BUILD_ROOT=_build-lane-az4b mix compile
Generated smalt app
```

exit 0. (Plain `mix compile` green; `--warnings-as-errors` not clean tree-wide
from other concurrent lanes' in-flight files — pre-existing, disclosed not
owned.)

## Typed limits

- **FIPS-level hardware isolation: UNSUPPORTED** — no HSM silicon at loopback;
  a real MHSM pool cannot be provisioned on this machine (falsifier named).
  The emulator serves the protocol-real POLICY face only. `exportable: never` /
  `dataExecution: never` are stored/echoed verbatim; enforcement here is the
  assertion-evaluation + policy-required RELEASE gate, not hardware custody.
- MAA evidence MINTING on release remains typed-UNSUPPORTED (KD-106 face,
  unchanged).

## GAP(kv-pqc-keyface) — SHARPENED, not closed

The release-POLICY half of the defense KV face is CLOSED (KD-167, this face);
the PQC key-type half remains GAP — no ML-DSA/ML-KEM `kty` on the create/sign
wire face (`lib/smalt/egress/kv_routes.ex`; PQC exists only off-wire:
`tls.ex`, `trust_profile.ex`, `hw/frame.ex`). Register row:
`docs/jira/v26.10.22/azure-industry-matrix.md:193`.

## Register note (disclosed, other lane's row)

`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` carries TWO rows under id KD-167
(line 347 AZ-4 MHSM policy face, CLOSED-WITH-EVIDENCE; line 348 AZ-2 MAA
measurement cross-binding, OPEN, also `# KD-COVERS: KD-167` in
`lib/smalt/attestation/maa.ex:289`). Duplicate register id — owned by the
AZ-2 row / kd-registrar, disclosed here not fixed by this lane.

## Falsifier

`MIX_BUILD_ROOT=<lane> mix test test/internal/az4_mhsm_release_policy_court_test.exs`
— red, or any policy-violating release returning 200, reopens KD-167.
