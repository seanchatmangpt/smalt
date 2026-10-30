# extend-the-capability-graph

How to add a new capability (config key, identity face) so the whole
projection chain picks it up — graph to generated accessors to the
capabilities document.

## The chain you are extending

From r12's §1 recon (verbatim shape):

```text
pack ontology.ttl (canonical graph)
  -> queries -> templates -> generated lib/ artifacts (mix smalt.gen)
  -> Smalt.Registry (compile-time data)
  -> Smalt.Projection.Canonical.capability_document/0
  -> mix run -e 'Smalt.Projection.Canonical.write()' -> docs/capabilities.json
```

## Worked example A: a config key (r11, redis_port)

1. Add the ConfigKey row to the pack ontology
   (`/Users/sac/ggen-marketplace/packs/smalt-substrate-pack/ontology.ttl`):
   `smalt:ck-redis-port`, name `redis_port`, integer, default 6380, secret
   false, surface `data_plane`, envVarName `-`, override `none` — mirroring
   the real call site `Application.get_env(:smalt, :redis_port, 6380)`.
2. Extend the template
   (`templates/registry.ex.eex`): `redis_port/0` (runtime accessor,
   mirrors the call-site law) + `redis_port_default/0` (env-independent
   canonical default).
3. Regenerate (`mix smalt.gen` or the lease-render + atomic-mv path from
   [adopt-generated-code-safely](../how-to/adopt-generated-code-safely.md)).
   r11's landed diff: registry.ex +6 lines exactly.
4. Mirror into the canonical projection: r11 added `"redisWire" =>
   {"port" => Registry.redis_port_default(), ...}` in
   `lib/smalt/projection/canonical.ex`, then
   `MIX_BUILD_ROOT=_build-gc1 mix run -e
   'Smalt.Projection.Canonical.write()'` → exit 0, and capabilities.json
   gained `endpoints.redisWire.port = 6380` from the projected default.

## Worked example B: an identity face (r12, saml_idp_port)

1. Additive graph section in the pack ontology: classes
   `smalt:IdentityPlane` / `smalt:IdentityFace`; properties
   `smalt:standing` ("live" | "queued"), `smalt:ticket`, `smalt:endpoint`,
   `smalt:entityId`, `smalt:protocol`, `smalt:module`; three face
   individuals (saml-idp live; saml-slo and oidc-idp queued).
2. Add the ConfigKey `smalt:ck-saml-idp-port` (surface `identity_plane`,
   default 9445, override none — mirrors T02's call site
   `Application.get_env(:smalt, :saml_idp_port, 9445)`).
3. Regenerate: `MIX_BUILD_ROOT=_build-gi1 mix smalt.gen` — all six stanzas
   ok. Generated config.ex = HEAD + three additive deltas (issuer_host
   position shift, redis_port, saml_idp_port); the census gained the
   identity plane for the first time.
4. Gate (r12 §5, verbatim command):

   ```bash
   MIX_BUILD_ROOT=_build-gi1 mix test test/config_alias_law_test.exs \
     test/smalt_gen_ash_replay_identity_test.exs \
     test/integration/saml_idp_test.exs
   ```

   → exit 0, `Result: 18 passed` (7.8s).

## Live-vs-queued standing vocabulary

`smalt:standing` ("live" | "queued") is machine-distinguishable in the
graph. r12's rdflib witness (actual query output, verbatim):

```text
oidc      | queued | docs/jira/v26.10.29/tickets/T05-oidc-idp.md |
          |        |   /authorize, /userinfo, /.well-known/openid-configuration, /jwks.json
saml2-idp | live   | - | /metadata, /sso
saml2-slo | queued | docs/jira/v26.10.29/tickets/T04-saml-slo.md | /slo
```

(First row reflowed onto two lines to fit this guide's 100-char limit;
content unchanged from r12 §2.)

## Do not

- Do not add identity faces as registry rows: r12 REFUSED polluting
  `admitted_resource_types` (49 ARM types) because it would ripple into
  `Smalt.Registry.admitted?/2` admission behavior — "refused as dishonest
  modeling".
- Do not hand-edit capabilities.json (see
  [generated-files-are-projections](../explanation/generated-files-are-projections.md)).
- Do not extend the MCP descriptor chain for HTTP faces: r12 §1 named the
  decision — the ema: vocabulary has no standing field and the surface is
  read-only MCP tools; the descriptor is not the home.

## Related

- [smalt-generation-pipeline](../reference/smalt-generation-pipeline.md)
- [regenerate-without-losing-handwork](../how-to/regenerate-without-losing-handwork.md)
