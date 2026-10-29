# w6a — KV key rotationPolicy face (wave-6)

**Standing:** PARTIAL_ALIVE — module-direct witness ALL FACES OK (real Store, real
crypto-material key create); wire tier compiles; full-tree compile and internal
tier run blocked during the lane by other lanes' in-flight syntax churn
(disclosed below).

## Surface

- `lib/smalt/data_plane/key_vault_actions.ex` (exclusive lane surface):
  - `get_rotation_policy/1` — GET /keys/{name}/rotationpolicy. Default (never
    set) returns 200 with `lifetimeActions: []`; unknown key 404 KeyNotFound.
  - `set_rotation_policy/2` — PUT /keys/{name}/rotationpolicy. Validates:
    `lifetimeActions` list, `action.type` in [Rotate, Notify]; trigger
    `timeAfterCreate`/`timeBeforeExpiry` must match an ISO-8601 duration
    (P...T...); `attributes.expiryTime` RFC3339 or null. Malformed input is a
    typed 400 `InvalidParameter`, no write. Policy stored on the root record
    under `rotation_policy`.
- `lib/smalt/egress_router.ex` (shared seam, one route patch — disclosed):
  literal `get`/`put "/keys/:name/rotationpolicy"` routes defined BEFORE the
  `/keys/:name/:action` catch-all so the literal wins (same shape as the
  rotate route above them).

## Witness (real output, module-direct with real Store)

Replay:
```
mkdir -p tmp/w6a_beams && elixirc -o tmp/w6a_beams -pa _build-lane-w5j/test/lib/smalt/ebin lib/smalt/data_plane/key_vault_actions.ex
elixir $(for d in _build-lane-w5j/test/lib/*/ebin; do [ -d "$d" ] && printf -- "-pa %s " "$d"; done) -pa tmp/w6a_beams tmp/w6a_witness.exs
```
(the fresh lane beam path must be LAST — Elixir `-pa` is last-in-first-out on
the code path)

```
DEFAULT_POLICY_200_OK
PUT_POLICY_200_OK
GET_ECHO_OK
BAD_ACTION_400_OK code=InvalidParameter
BAD_DURATION_400_OK
BAD_EXPIRY_400_OK
UNKNOWN_404_OK
W6A WITNESS: ALL FACES OK
```

## Gates

- Module compile: `elixirc --warnings-as-errors` — clean (one pre-existing
  warning at :1421 `do_verify` KvPss.verify_pss clause, not in this diff).
- Router compile: isolated `elixirc` of egress_router.ex — 0 errors.
- Full-tree `mix compile --warnings-as-errors` in `_build-lane-w6a`: BLOCKED
  by concurrent in-flight syntax churn in other lanes' files (witnessed
  sequence: egress_router w6s block typo → `lib/smalt/arm/deployments.ex`
  typo → `certificates.ex:590` unclosed delimiter → `file_share.ex:172`
  mismatched delimiter). None of these are in my diff. My surface files
  compile clean in isolation against the w5j beams.

## Disclosures

- egress_router.ex is a shared seam; I added only the two rotation-policy
  literal routes. I also authored a minimal unblock fix of another lane's
  (w6s) broken block? — no. w6s fixed their own block within the SLA (observed
  fixed within one 20 s poll). No foreign edits by this lane.
- `lib/smalt/arm/deployments.ex`, `certificates.ex`, `file_share.ex` syntax
  breaks were owner-fixed within the SLA each poll cycle; no fixes applied by
  me.
- No git commands, no Process.sleep (bounded polls only).
## RE-WITNESS addendum — 2026-10-22 (lane BK-REWIT3): cheap replay PASS — ALIVE

Re-ran `tmp/w6a_witness.exs` module-direct over a fresh `_build-rewit3`
tree (`MIX_BUILD_ROOT=_build-rewit3 MIX_ENV=test mix run --no-start`):
`DEFAULT_POLICY_200_OK / PUT_POLICY_200_OK / GET_ECHO_OK /
BAD_ACTION_400_OK code=InvalidParameter / BAD_DURATION_400_OK /
BAD_EXPIRY_400_OK / UNKNOWN_404_OK / W6A WITNESS: ALL FACES OK`, exit=0 —
byte-for-byte the original witness tail. Rotation-policy surface still
present in key_vault_actions.ex (14 hits). SUSPECT cleared; standing now
ALIVE (full-tree compile ran clean in _build-rewit3 — the receipt's
PARTIAL_ALIVE blocker is gone).
