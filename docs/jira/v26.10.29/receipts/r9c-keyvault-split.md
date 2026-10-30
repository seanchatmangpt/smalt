# r9c-keyvault-split

**Lane**: L11 — KeyVault split (T09 dataplane splits)
**Standing**: PARTIAL_ALIVE
**Date**: 2026-10-29
**Build root**: `MIX_BUILD_ROOT=_build-l11`, Elixir 1.20.4-otp-29 (asdf-pinned
per `.tool-versions`)

## What landed

`Smalt.DataPlane.KeyVaultActions` (2,225 lines) split into faces behind a
byte-faithful delegating facade. Every pre-split public function keeps its
name, arity, defaults and return shapes on `KeyVaultActions` (defdelegate), so
`EgressRouter`, `Smalt.Egress.KvRoutes`, `mcp/router`,
`Smalt.DataPlane.Certificates` (`backup_codec/0` seam) and `store_tables.ex`
are untouched consumers.

Files (all within lane contract):

- `lib/smalt/data_plane/key_vault_actions.ex` (facade, 184 lines) — delegates
  the full pre-split public surface to the faces; keeps `@doc` + `@spec` on
  `api_version/0`, `challenge_mode/0`, `kv_backup_encode/1`,
  `kv_backup_decode/2`.
- `lib/smalt/data_plane/key_vault/keys.ex` (1,601 lines) — the crypto/CRUD
  engine: encrypt/decrypt/sign/verify, wrap/unwrap GCM+OAEP, create, list +
  paged versions, rotation policy, rotate, deleted-keys lifecycle,
  update_key_properties, backup/restore, release-policy gate, key material
  (RSA/oct/oct-HSM/EC), AES-GCM + parameter handling. Extracted by mechanical
  line-slice from the original file; seam rewrites are literal, verified
  in-place:
  - `api_version()` → `Auth.api_version()` (rotation policy id field)
  - `encode_backup/decode_backup` → `Certificates.kv_backup_encode/decode`
  - 9 internals made public `@doc false` (with_key/5, do_encrypt/3,
    do_decrypt/3, b64_field/2-3, b64url_encode/1, bad_request/2,
    purge_protection?/1, real_purge_date/1, + new deleted_table/0 accessor)
    so faces share ONE engine with no duplication.
- `lib/smalt/data_plane/key_vault/secrets.ex` (295 lines) — secret PATCH +
  deleted lifecycle (KD-102/KD-184/KD-185); consumes Keys seams
  (`Keys.deleted_table()`, `Keys.ensure_deleted_table()`,
  `Keys.purge_protection?/1`, `Keys.real_purge_date/1`); one comment line
  now reads `Keys.deleted_table()` where `@deleted_table` stood (comment
  only).
- `lib/smalt/data_plane/key_vault/hsm.ex` (201 lines) — randomnumbers +
  AES-KW (RFC 3394/5649) wrap/unwrap + public aes_kw seam; calls
  `Keys.with_key/5`, `Keys.do_encrypt/3`, `Keys.do_decrypt/3`,
  `Keys.b64_field/2`, `Keys.b64url_encode/1`, `Keys.bad_request/2`.
- `lib/smalt/data_plane/key_vault/certificates.ex` (85 lines) — the ONE
  SMALT-KVB1 envelope codec (magic, encode/decode, checksum); consumes
  `Keys.bad_request/2`.
- `lib/smalt/data_plane/key_vault/auth.ex` (39 lines) — KD-15 posture
  accessors `api_version/0` + `challenge_mode/0` (bodies byte-copies of the
  originals; KD-15 law: tokenless 401 + `WWW-Authenticate: Bearer` resend —
  the enriched challenge itself stays in `Smalt.Auth.Bearer` which reads the
  same config key; the accessors are the named readers).

Extraction was mechanical (sed line-slices of the original at
110-814 / 924-958 / 967-999 / 1016-1096 / 1170-1188 / 1354-1989 /
2118-2161 for Keys; 816-922 / 959-965 / 1190-1352 for Secrets; 1995-2116 /
2163-2224 for HSM; 1014 / 1098-1168 for the codec) — after two hand-written
Write attempts produced transcription garble (both reverted; see incident
log). The wire surface inventory was verified complete against the pre-split
grep of all `KeyVaultActions.<fn>` call sites in lib/ and test/ (34 distinct
functions; all delegated).

## Gate

Command (bounded, no sleeps; courts are the lane-contract KV set):

    MIX_BUILD_ROOT=_build-l11 mix test test/integration/kv_crypto_face_test.exs \
      test/integration/kv_ec_create_test.exs test/integration/kv404_typed_error_test.exs \
      test/integration/bk19_kd10_kv_put_route_test.exs \
      test/internal/kds3_s4_secret_version_history_test.exs \
      test/internal/bkvc_consolidated_court_test.exs \
      test/internal/expl8r_court_test.exs

Embedded real output (tail):

    Result: 26/29 passed
    Failed: 3 tests

Per-file disposition (real runs, same build root):

    kv_crypto_face_test.exs         Result: 4 passed        GREEN
    kv404_typed_error_test.exs      Result: 2 passed        GREEN
    bk19_kd10_kv_put_route_test.exs Result: 1 passed        GREEN
    bkvc_consolidated_court_test.exs Result: 3 passed       GREEN
    expl8r_court_test.exs           Result: 11 passed       GREEN
    kv_ec_create_test.exs           Result: 4/5, 1 FAILED   (pre-existing, router layer)
    kds3_s4_secret_version_history_test.exs Result: 1/3, 2 FAILED (pre-existing, router layer)

The 3 failures are NOT in the split path. Real-probe receipt (mix run,
`_build-l11`): dispatching the exact failing request shapes directly at
`Smalt.Egress.KvRoutes` with zero `KeyVaultActions` frames in the path:

    L11PUT 201 202b
    L11GETV 404 head="<?xml version=\"1.0\" encoding=\"utf-8\"?><Error><Code>SecretNotFound</Code><Message>SecretNotFound</Mes"

The 404 body is BLOB-STYLE XML on a KV route (tests expect the JSON
`SecretNotFound` envelope). Cause: `lib/smalt/egress/KvRoutes.ex` and
`lib/smalt/egress_router.ex` carry 22:38/22:40 mtimes (inside this lane's
window; not edited by L11) and their KV 404/400 arms now render through
`blob_error/2` (the Azure-Storage XML error emitter,
`lib/smalt/data_plane/blob_error.ex:34`). The engine-level contract still
holds through the facade (mix run probe):

    Smalt.DataPlane.KeyVaultActions.create_key("probe-l11", %{"kty" => "EC", "crv" => "P-999"})
    => {:error, 400, %{"error" => %{"code" => "InvalidParameter",
        "message" => "unsupported EC crv P-999"}}}

    Smalt.DataPlane.KeyVaultActions.key_wrap("nope", %{"alg" => "A256KW", "value" => "AAAA"}, nil)
    => {:error, 404, %{"error" => %{"code" => "KeyNotFound"}}}

i.e. the typed JSON envelopes the courts assert are what the engine returns;
the wire layer re-renders them as XML after the engine handoff. L11 did not
edit any router file (lane contract: no cross-lane edits; disclosed, not
fixed here — owner is the KvRoutes/egress lane).

## Verification ladder

- compile: `MIX_BUILD_ROOT=_build-l11 mix compile` exit 0, zero warnings from
  key_vault* files (one unused-alias warning introduced mid-flight was fixed
  before the gate; final state has none).
- direct engine probes (mix run): facade seams correct (above).
- engine courts green: 21/21 across the five fully-green court files.
- wire-level courts: 3 failures classified ABOVE as router-layer,
  pre-existing relative to the L11 diff (failing requests never dispatch into
  any KeyVaultActions frame; reproduced with the engine removed from the
  path).
- wider set (not lane-mandated): acceptance_probe 2 FAIL + mcpt1 2 FAIL —
  same-tree sibling state, outside the lane court set, reported for the
  coordinator.

## Incident log (disclosed)

- Hand-written Write #1/#2 for hsm.ex produced syntax garble; it froze the
  shared compile ~30 min for other lanes (coordinator SLA escalation
  received). Resolution: full revert (dir moved to /tmp), then mechanical
  re-extraction; the landed hsm.ex is slice-verbatim from the original file.
  Re-verified post-fix: no clause was corrupted into wrong-algorithm
  behavior — the landed hsm.ex is the mechanical `sed -n '1995,2116p' +
  '2163,2224p'` slice of the pre-swap original, and the `defp kw_alg` guard
  clauses (original lines 2102-2104) were read back from the landed file and
  compared side-by-side against the pre-split Read of those lines:
  byte-identical.
- Sibling freezes observed and waited out (bounded polls, no unblock edits
  by L11): iac_export/terraform.ex, purview_atlas/glossary.ex,
  messaging/amqp/frame_codec.ex. Zero cross-lane file edits by L11.
- auth.ex was written by hand (39 lines) — post-hoc verified byte-wise
  against the original accessor bodies (lines 93-106 of the pre-split file).

## Falsifier

A KV court failing inside the engine layer (KeyVaultActions/KeyVault.*)
while the same request shape passes through the facade — none exists in this
run. The 3 wire failures reproduce without KeyVaultActions in the dispatch
path (probe above), so they cannot falsify the split.

## See Also

`docs/jira/v26.10.29/tickets/T09-dataplane-splits.md` ·
`docs/jira/v26.10.29/receipts/INDEX.md`
