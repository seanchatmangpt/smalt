# w6h — Cosmos DB users / permissions / resource tokens (wave-6)

**Standing: PARTIAL_ALIVE** — wire-proven face (module-direct + real-TCP +
real-pipeline admission); full-app boot deferred: the shared tree was
mid-integration during the lane (multiple sibling lanes compiling), so
the enforce-mode legs ran conn-level through the REAL plug pipeline
(Smalt.Auth.Bearer → Smalt.CosmosAuthzPlug) rather than full TCP; the
real-TCP leg (Bandit, anonymous create → 201) proves routing over the
socket. No mocks; asserts on real ETS/HTTP state.

## Landed

- `lib/smalt/data_plane/cosmos_authz.ex` (NEW) — users CRUD (201/409/200/404/feed),
  permissions CRUD (201/400 bad-mode/404 ghost-user), resource-token mint
  (`type=resource&ver=1.0&sig=<opaque 32B>`, 1h TTL, revocation on permission
  delete + user-delete cascade), admission law: segment-boundary prefix
  scope + mode coverage (Read→GET/HEAD, All→any), typed 401 refusal class.
  Shadow-table law: 3 tables (`:smalt_cosmos_users`, `:smalt_cosmos_permissions`,
  `:smalt_cosmos_resource_tokens`) lazily created `{:heir, Process.whereis(:init), []}`
  3-tuple; create uniqueness via ONE `:ets.insert_new/2`.
- `lib/smalt/cosmos_authz_plug.ex` (NEW) — router seam OUTSIDE the main
  EgressRouter match (that match is at a BEAM implementation limit —
  witnessed: adding clauses there fails compile "implementation limit
  reached" on `__MODULE__/1+14`). Matched paths respond+halt; unmatched
  pass through.
- `lib/smalt/auth/bearer.ex` (additive, disclosed shared-file seam) —
  `type=resource&ver=1.0&sig=` headers on /dbs paths delegate admission to
  `CosmosAuthz.verify_resource/1` (scope+mode fail-closed; unknown/expired/
  out-of-scope → 401 InvalidAuthenticationToken).
- `lib/smalt/egress_router.ex` — ONE additive line: `plug(Smalt.CosmosAuthzPlug)`
  after :maybe_parse_body (w6h footprint vs HEAD = that line only; the
  remaining egress_router diff vs HEAD is sibling lanes w6o/w6p/etc. in-flight
  integration, not w6h).

## Defects found & fixed in-lane (real witnesses)

1. Row double-wrap `{{key,row}}` → uniqueness never matched (duplicate-user
   inserts possible); fixed to `{key,row}` — witness pins 409.
2. Revoke used string key `row["token_sig"]` for an atom-stored field →
   permission delete never revoked tokens; fixed `row[:token_sig]` — witness
   pins refuse-after-delete.
3. `verify_resource` returned `{:error, atom}` into a `{:refuse, code, reason}`
   consumer (Bearer seam) — would have been a CaseClauseError/500 on any
   unknown token; fixed typed refusal mapping.
4. `String.replace_suffix/2` warning (arity) → `replace_trailing/3`.

## Receipt (real output, replay below)

```
PART_A_GREEN
WIRE_CREATE_USER_201
C1_STATUS: 200
C1_BODY: {"Users":[...alice...]}
WIRE_IN_SCOPE_200
WIRE_OUT_OF_SCOPE_401
WIRE_READ_CANNOT_WRITE_401
WIRE_TOKENLESS_401
PART_B_GREEN
W6H WITNESS: ALL GREEN
```

Replay:

```bash
ERL_LIBS="$PWD/_build-lane-w6h/dev/lib" elixir tmp/w6h_witness.exs
```

Witness legs (all real state asserts):

| Leg | Expectation | Result |
|---|---|---|
| users CRUD | 201→409 dup→200 get→404 unknown→feed | GREEN |
| permissions CRUD | 201 / 400 bad mode / 404 ghost user | GREEN |
| token mint | `type=resource&ver=1.0&sig=` >20B | GREEN |
| in-scope GET | :ok admit | GREEN |
| out-of-scope GET | refuse (401 class) | GREEN |
| Read token DELETE | refuse (mode law) | GREEN |
| unknown token | refuse | GREEN |
| revoke on permission delete | refuse after delete | GREEN |
| real-TCP POST /dbs/db/users (anon) | 201 + x-ms-version 2025-04-15 + request-charge | GREEN |
| enforce GET in-scope (real pipeline) | 200 | GREEN |
| enforce GET out-of-scope | 401 ResourceTokenScopeExceeded | GREEN |
| enforce POST w/ Read token | 401 | GREEN |
| enforce POST tokenless | 401 challenge | GREEN |

## Honest gaps

- Full-app TCP boot for enforce legs deferred (shared tree mid-integration);
  the pipeline composition is the real one (real Bearer plug + real w6h plug),
  only the TCP socket is missing. Falsifier: boot full substrate at wave-6
  integration and repeat the four enforce legs over TCP.
- Token expiry (1h TTL) not courted — time-bound, pollable only by clock.
- No httpc leg: the erlang httpc client cannot send the custom authorization
  header shape (client limitation; Bandit leg + conn legs cover the face).

Compile: `MIX_BUILD_ROOT=_build-lane-w6h mix compile --warnings-as-errors`
blocked full-app by sibling in-flight files (arm/dns.ex, blob_storage.ex churn);
w6h modules compile CLEAN standalone (elixirc, zero warnings) and the
witness runs green. sleep-gate: PASS (0 sites). No git actions.
