# regenerate-without-losing-handwork

How to regenerate a generated artifact when committed hand-work has drifted
ahead of the generator's inputs — the config.ex incident, from both sides.

## The incident

`lib/smalt/config.ex` is a generated artifact (the config_keys census, one
zero-arity accessor per ontology row). At receipt time it was AHEAD of the
pack ontology: it carried committed blocks with no template backing
(r11 §"BLOCKED — config.ex"):

- the R8 `@neutral_aliases` / `neutral_env/1` section
  (`lib/smalt/config.ex:20-37` on disk today), plus `neutral_env` rewires
  inside several accessors
- the R9 `issuer_host` census row + accessor
  (`lib/smalt/config.ex:431`, `:712-718` on disk today)

r11 verified with `git show HEAD` (6 hits) that a fresh
`config_keys.rq` render (ggen_igniter wrote 167 rows in the lease) would
NOT contain them — regenerating would delete landed capability code.
Typed BLOCKED (awaiting R8/R9 template landing); not regenerated, not
hand-edited.

## The recovery: union-merge, then the template is the source again

r12's §3 measured the recovery end-state. After the R8 neutral-env block
and the `smalt:ck-issuer-host` ConfigKey row were restored into the pack
(`templates/config.ex.eex` + `ontology.ttl`), the regenerated config.ex =
HEAD + exactly three additive deltas:

1. `issuer_host` census row + accessor: position shift only, zero semantic
   delta (the disclosed R9 restoration)
2. `redis_port` census row + accessor (r11's row, additive, theirs)
3. `saml_idp_port` census row + accessor (r12's row — the identity plane
   entering the closed config census for the first time)

`git diff` between HEAD config.ex and the regenerated file measured the
delta before landing; the union-merge into the generator inputs (not into
the artifact) is what made regeneration lawful again.

## The lawful end-state, proven by a gate

r12's gate ran with the restored template in place:

```bash
MIX_BUILD_ROOT=_build-gi1 mix test test/config_alias_law_test.exs \
  test/smalt_gen_ash_replay_identity_test.exs \
  test/integration/saml_idp_test.exs
```

exit 0, `Result: 18 passed` (7.8s). The alias-law test passes over the
grown census (the saml_idp_port row carries env_var nil, so no alias is
needed — the law holds); the live IdP booted inside the test on dynamic
ports. Backing restored in `templates/config.ex.eex` is the difference
between a lawful regen and `mu_unlawful` (deleting landed capability).

## The law, stated for reuse

1. Never regenerate over committed hand-work. Diff HEAD vs would-be output
   first; if the output is missing committed content, the generator inputs
   are missing it too.
2. Recover by union-merge into the SOURCE (ontology rows + templates), so
   the next regen is a superset of HEAD, additive-only.
3. Then regenerate and gate. Additive-only diff + green gate = the
   artifact is a projection again.
4. If the source restoration is outside your ownership, the regen is
   BLOCKED, not forced: type it, name the owner, land the rest (r11's
   BLOCKED section is the pattern).

## Related

- [generated-files-are-projections](../explanation/generated-files-are-projections.md)
- [extend-the-capability-graph](../how-to/extend-the-capability-graph.md)
- [adopt-generated-code-safely](../how-to/adopt-generated-code-safely.md)
