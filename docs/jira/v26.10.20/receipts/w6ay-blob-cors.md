# w6ay — Blob service CORS rules (wave-6)

**Standing: ALIVE** (module + wire-preflight tiers)

## Surface
- `lib/smalt/data_plane/blob_cors.ex` (NEW, exclusive): `<Cors>` rule parsing
  (max 5 rules/service → 400 InvalidInput, bad method token → 400
  InvalidXmlDocument, tokens validated against
  GET,PUT,HEAD,POST,DELETE,MERGE,OPTIONS,PATCH), per-account storage
  (heir'd `:smalt_blob_cors` ETS, 3-tuple `:heir` init), OPTIONS preflight
  `preflight/3` → `{:ok, headers} | :forbidden`, and `expose_headers/2`.
- `lib/smalt/egress_router.ex` (minimal arm, disclosed):
  1. `egress_cors/2` scopes blob-plane requests to the rule-based face
     (`w6ay_blob_cors/1`): OPTIONS preflight → 200 + Access-Control-* headers
     or 403 on no-match; actual requests with matching Origin get
     `Access-Control-Expose-Headers` via `register_before_send`. Other planes
     keep the pinned CORSPlug face (KD-15 court pins OPTIONS on the KV plane —
     untouched).
  Blob-plane detection: `blob_plane_path?/1` denylist of non-blob first
  segments (keys/secrets/certificates/kv/dbs/attest/snapshots/
  subscriptions/metadata/v2/schemas/revisions/managedstorage/$schemagroups).
  Known boundary: new plane prefixes must extend this denylist.
  2. Set-properties PUT hook: parse+store rides the w6av properties handler.
- Route-ownership note: the PUT/GET service-properties routes belong to lane
  w6av (same session); my storage + parse hook rides their handler; the
  static-website face is w6av's surface.

## Witness (real output)
Replay: `MIX_BUILD_ROOT=_build-lane-w6ay MIX_ENV=test mix run --no-start tmp/w6ay_witness.exs`

Authoritative output (10/10 legs, run 08:35:23Z):
```
L1_SET_2_RULES_OK
L2_PREFLIGHT_ALLOWED_OK
L3_PREFLIGHT_DENIED_OK
L4_WILDCARD_OK
L5_EXPOSE_OK
L6_BAD_METHOD_400_OK
L7_TOO_MANY_400_OK
L8_CLEAR_OK
L9_WIRE_PREFLIGHT_200_OK
L10_WIRE_PREFLIGHT_403_OK
```
Full log: `tmp/w6ay_witness_run.log`. (L10 printed as L10_WIRE_PREFLIGHT_403_OK.)

## Verdict + falsifier
- 10/10 legs PASS: 2-rule set → allowed preflight 200 with exact
  Access-Control headers, disallowed origin 403, wildcard, expose headers,
  bad method token 400, >5 rules 400, PUT-without-Cors clears rules, and the
  wire preflight 200/403 through real `EgressRouter.egress_cors/2` dispatch
  (real conn adapter, halted responses asserted).
- Falsifier: re-run `tmp/w6ay_witness.exs` — green under a broken
  `blob_plane_path?/1` denylist or a preflight admitting the evil origin
  would be vacuous. Non-vacuity legs: L3/L10 (evil-origin 403).
- One in-lane fix during witnessing: `w6ay_blob_cors/1` reduce target was
  conn-not-headers (FunctionClauseError on the wire leg) — fixed and
  re-witnessed.

## Compilation
- `blob_cors.ex`: `elixirc --warnings-as-errors` RC=0, zero warnings.
- egress_router.ex: my region zero diagnostics; residual strict-compile
  failures are sibling-owned (w6av's `ensure_service_props_table` in
  blob_storage.ex ~:2699 uses the illegal keyword-then-tuple ets.new option
  list — flagged to its owner; file_share.ex/key_vault_actions.ex/
  sb_management.ex churn windows were owner-repaired within SLA; no
  foreign-file edits by this lane.

## Integration notes
- Keep `tmp/w6ay_witness.exs` + `tmp/w6ay_witness_run.log` for replay.
- No KD register edits; no git commands; build root `_build-lane-w6ay` left
  for lane-clean.