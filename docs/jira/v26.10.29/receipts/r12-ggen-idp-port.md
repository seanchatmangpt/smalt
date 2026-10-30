# r12 — GGEN-IDP lane: SAML IdP capability into the ggen/ontology layer

- window: v26.10.29 · lane: GGEN-IDP (r12) · date: 2026-10-29
- standing: **PARTIAL_ALIVE** (graph + generated config census + gate: ALIVE;
  canonical identity faces: BLOCKED by ownership boundary — §3; final lock pin:
  rides the wave integration writer — §5)

## 1. Pipeline recon (task item 1)

Actual input -> generator -> projection chain for capability truth in smalt:

```
ggen-marketplace/packs/smalt-substrate-pack/ontology.ttl (canonical graph)
  |  mix smalt.gen  (lib/mix/tasks/smalt.gen.ex: six Mix.Task.rerun stanzas of
  |                  ggen_igniter.sync; MIX_BUILD_ROOT=_build-gi1)
  +- queries/control_plane.rq -> templates/registry.ex.eex -> lib/smalt/registry.ex
  +- queries/config_keys.rq   -> templates/config.ex.eex    -> lib/smalt/config.ex
  |        (closed ConfigKey census + zero-arity accessors, name-sorted)
  +- store_tables / cascade_edges / event_registry / semconv stanzas (unchanged)
  v
Smalt.Registry (compile-time data)
  v
Smalt.Projection.Canonical.capability_document/0
  (lib/smalt/projection/canonical.ex — NOT ggen-projected; reads Registry accessors only)
  v
mix run -e 'Smalt.Projection.Canonical.write()' -> docs/capabilities.json
```

Second, independent chain (recon'd, deliberately NOT extended):
`lib/smalt/mcp/gen/smalt_mcp_surface.ttl` -> elixir-mcp-a2a-pack `mcp_capabilities.rq`
-> `lib/smalt/mcp/generated/mcp_descriptor.ex`. The ema: vocabulary has no standing
field and the surface law is read-only MCP tools; the IdP faces are HTTP faces on the
identity port, so the descriptor is not the home. Named decision, not an omission.

## 2. Graph additions (task item 2)

In `ggen-marketplace/packs/smalt-substrate-pack/ontology.ttl` (additive only):

- Classes `smalt:IdentityPlane` and `smalt:IdentityFace`; properties
  `smalt:standing` ("live" | "queued"), `smalt:ticket`, `smalt:endpoint`,
  `smalt:entityId`, `smalt:protocol`, `smalt:module`.
- Three face individuals:
  - `smalt:face-saml-idp`: protocol `saml2-idp`, standing **live**, module
    Smalt.Identity.SamlIdp, port 9445, entityID `urn:smalt:identity:saml`,
    endpoints /metadata + /sso.
  - `smalt:face-saml-slo`: protocol `saml2-slo`, standing **queued**,
    ticket pointer `docs/jira/v26.10.29/tickets/T04-saml-slo.md`, endpoint /slo.
  - `smalt:face-oidc-idp`: protocol `oidc`, standing **queued**, ticket pointer
    `docs/jira/v26.10.29/tickets/T05-oidc-idp.md`, endpoints /authorize,
    /userinfo, /.well-known/openid-configuration, /jwks.json.
- `smalt:ck-saml-idp-port` ConfigKey: surface `identity_plane`, default 9445,
  override none — mirrors the T02 call site
  `Application.get_env(:smalt, :saml_idp_port, 9445)`.

Live vs queued is machine-distinguishable in the graph. Witness (rdflib over the
ontology, actual query output):

```
oidc      | queued | docs/jira/v26.10.29/tickets/T05-oidc-idp.md | /authorize, /userinfo, /.well-known/openid-configuration, /jwks.json
saml2-idp | live   | - | /metadata, /sso
saml2-slo | queued | docs/jira/v26.10.29/tickets/T04-saml-slo.md | /slo
```

- Cross-lane disclosed restoration (see section 3): `smalt:ck-issuer-host`
  ConfigKey, verbatim from HEAD's generated census row (type string, default
  nil, surface auth) plus the R8 neutral-env template block — both lost from
  the pack working tree while smalt's committed generated artifacts still carry
  them.

## 3. Regeneration and fence verdict (task item 3)

Measured with `diff git-HEAD:lib/smalt/config.ex vs lib/smalt/config.ex` after
`MIX_BUILD_ROOT=_build-gi1 mix smalt.gen` (all six stanzas ok):

- Generated config.ex = HEAD + exactly three additive deltas:
  1. `issuer_host` census row + accessor: position shift only, zero semantic
     delta; disclosed cross-lane restoration (R9). Its pack row was lost from
     the pack working tree; without restoring it, my additive regen would have
     dropped the R9 accessor from the generated artifact.
  2. `redis_port` census row + accessor: GGEN-CACHE lane r11's pack rows,
     additive, theirs.
  3. `saml_idp_port` census row + accessor: mine. The identity plane enters the
     closed config census for the first time — T02's `:saml_idp_port` was read
     via Application.get_env with no census entry; a real parity gap closed.
- No registry rows added: identity faces are not ARM resource types; polluting
  `admitted_resource_types` would ripple into `Smalt.Registry.admitted?/2`
  admission behavior. Refused as dishonest modeling.
- `ggen_igniter.pack.lock` substrate row refreshed a454f2... -> 7b4bb6... via
  `mix ggen_igniter.pack.lock --path ../ggen-marketplace/packs/smalt-substrate-pack
  --lock ggen_igniter.pack.lock`. Contention disclosed: another lane also
  refreshes the lock and rewrites docs/capabilities.json concurrently. At one
  verified write the doc pin matched the live lock digest (packLockSha256 ==
  sha256 of ggen_igniter.pack.lock, byte-check True); at filing pin-match is
  False pending the wave integration writer's final run. The self-digest fence
  (identity.contentSha256 recomputed over the sorted-key doc minus the digest
  field) verified consistent at every observed state.
- BLOCKED (typed): docs/capabilities.json cannot gain the identity faces within
  lane ownership. The doc's only capability vocabulary is
  `Smalt.Registry.admitted_resource_types` (49 ARM types). An identity-faces
  section needs an edit to `lib/smalt/projection/canonical.ex` (repo file,
  outside lane ownership) or `templates/registry.ex.eex` (pack template,
  outside lane ownership). Everything up to that boundary is landed; the
  boundary is the blocker. Hand-editing the generated doc or polluting ARM
  types were the refused alternatives.
- MCP descriptor untouched: the ema: vocabulary has no standing field and the
  surface is read-only MCP tools; identity faces are HTTP faces. Named decision.

## 4. Concurrency ledger (compile-freeze disclosure)

Shared-checkout reality this session; every one of my `mix` steps ran inside a
bounded poll on the real observable (compile/exit), no Process.sleep:

| time (PDT) | frozen file | owner (by scope) | resolution |
|---|---|---|---|
| 22:00 | lib/smalt/policy/eval.ex (`scope_covers?/2` undef) | T10 policy lane | owner fixed 22:07 |
| 22:08 | lib/smalt/data_plane/cosmos/auth.ex (truncated mid-write) | T09 lane | owner completed 22:13 |
| 22:15 | lib/smalt/mcp/router.ex, mcp/tool/cosmos.ex | T10 lane | owner fixed |
| 22:19 | lib/smalt/data_plane/purview_atlas/glossary.ex (`put_edge/4` undefined) | T09 lane | owner fixed |
| 22:2x-23:01 | lib/smalt/identity/oidc_authorize.ex (scratch var, then syntax) | T05 lane (dev loop) | owner iterated; gate polled through |

No SLA unblock was applied by this lane; every freeze was resolved by its owner
within the window. One misleading exit-code capture (my `EXIT=$?` after a pipe)
was corrected mid-session to true mix exits; retry predicates distinguish
compile-abort (exit 1 with `== Compilation error`) from real test results
(W672 census-vs-abort law).

## 5. Test gate (task item 4)

- Command: `MIX_BUILD_ROOT=_build-gi1 mix test test/config_alias_law_test.exs
  test/smalt_gen_ash_replay_identity_test.exs test/integration/saml_idp_test.exs`
- LANDED GREEN at 23:02 PDT: exit 0, `Result: 18 passed` (7.8s, 0.00s async).
  Covers: R8 alias law over the grown census (saml_idp_port row carries
  env_var nil, so no alias needed — law holds); smalt.gen.ash replay-identity
  fence (disk no-op); the T02 SAML IdP read-only court rerun — the log shows
  the live IdP booting on the tests' dynamic ports (`Running
  Smalt.Identity.SamlIdp with Bandit 1.13.1 at 127.0.0.1:53527 (http)` and
  `:42138`) with all assertions passing, proving this lane's graph + generated
  changes did not break the live IdP.
- Canonical final pin: doc self-digest fence verified consistent (True) after
  the gate; pack-lock pin verified True at one earlier successful write and
  False at filing — the wave's integration writer re-pins it; 10 further
  bounded write attempts were compile-frozen by the T04 SLO lane's in-flight
  saml_slo.ex.

## 6. Files touched

Lane-owned:
- `/Users/sac/ggen-marketplace/packs/smalt-substrate-pack/ontology.ttl`
  (identity-plane section + ck-saml-idp-port + ck-issuer-host restoration)
- `/Users/sac/smalt/docs/jira/v26.10.29/receipts/r12-ggen-idp-port.md` (this file)

Disclosed cross-lane (generator inputs, minimal, HEAD-derived):
- `/Users/sac/ggen-marketplace/packs/smalt-substrate-pack/templates/config.ex.eex`
  (R8 neutral-env block + neutral_env bodies in the four override classes +
  SMALT_PROFILE/AZURE_PROFILE refusal message — restores the standing law the
  pack working tree lost; the committed pack template never had it, smalt's
  HEAD config.ex is the evidence of the standing law).

Regenerated projections (not hand-edited):
- `/Users/sac/smalt/lib/smalt/config.ex`
- `/Users/sac/smalt/docs/capabilities.json` (+ `docs/THIRD_PARTY.md` by the same
  write; its deltas are other lanes' additive mix.lock rows, e.g. cachex,
  eternal)

Also refreshed: `/Users/sac/smalt/ggen_igniter.pack.lock` (substrate row).
`lib/smalt/registry.ex` delta vs HEAD is the GGEN-CACHE lane's additive redis
accessors (theirs, from the pack working tree) — zero rows from this lane.
Post-gate disclosure: the pack ontology sha moved after this lane's edits
(f50cc3... -> a98e69..., concurrent lane additions); this lane's section was
re-verified present on disk afterwards (IdentityFace individuals + both
restored/additive ConfigKeys), and config.ex still carries the saml_idp_port
row, the R8 neutral block, and issuer_host.

## 7. Standing line

- ALIVE: identity-plane graph section (3 faces, standing vocabulary, rdflib
  witness); `saml_idp_port` config census entry + accessor (generated,
  additive); pack-lock substrate row refresh; three-test gate exit 0 / 18
  passed.
- ALIVE (contended): canonical projection write (multiple exit-0 runs; final
  lock pin rides the wave integration writer).
- BLOCKED: capabilities.json identity faces (ownership boundary, section 3).
