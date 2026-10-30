# adopt-generated-code-safely

How to land generated files into a live shared checkout without freezing
the other lanes or losing anyone's work.

## Why a protocol at all

The wave that produced this guide ran 17 concurrent lanes over one
canonical smalt checkout (per the wave dispatch); 21 receipt files in
`docs/jira/v26.10.29/receipts/` document the individual lanes. Generated
artifacts landed by regenerating them, not by hand-applying diffs; three
receipts document the landing discipline:

- r11 (`receipts/r11-ggen-cache-port.md`): registry.ex rendered in a
  scratch lease (/tmp/gc1-lease, deps only on ggen_igniter, build root
  `_build-gc1`), formatted with smalt's own .formatter.exs, installed by
  atomic mv.
- r12 (`receipts/r12-ggen-idp-port.md`): all six stanzas of
  `MIX_BUILD_ROOT=_build-gi1 mix smalt.gen` ran in-tree, then a three-test
  gate, then the canonical projection write.
- r11's BLOCKED section: config.ex regeneration was REFUSED in-window
  because it would have deleted landed R8/R9 content (see
  [regenerate-without-losing-handwork](../how-to/regenerate-without-losing-handwork.md)).

## The protocol

1. Render in a lease, not in the shared tree. r11's lease: `/tmp/gc1-lease`,
   deps only on ggen_igniter, `MIX_BUILD_ROOT=_build-gc1` — the shared
   `_build` is never the first place a render touches.
2. Compile-validate before install. r11 formatted the rendered registry.ex
   with smalt's own `.formatter.exs` (mix format in smalt cwd) before the
   atomic mv.
3. Install atomically (`mv`, not in-place rewrite). Diff vs HEAD is the
   receipt's claim surface: r11's diff was "exactly the +6 lines
   (redis_port accessors + disclosure comment)".
4. Declare ownership. canonical.ex was outside r11's ownership list; the
   redisWire endpoint edit is disclosed in r11 for coordinator
   adjudication, not smuggled.
5. Coordinate the compile freeze. A generated `lib/` file freezes every
   lane's compile while it is torn; the SLA is owner-fixes-or-reverts in
   ~10 minutes, minimal disclosed unblock only (r11 named the blocker
   hsm.ex and did not touch it; see
   [multi-agent-compile-freeze-economics](../explanation/multi-agent-compile-freeze-economics.md)).
6. Gate on the real consumers. r12's gate:
   `mix test test/config_alias_law_test.exs
   test/smalt_gen_ash_replay_identity_test.exs
   test/integration/saml_idp_test.exs` → exit 0, `Result: 18 passed`
   (7.8s) — the live SAML IdP booted on dynamic ports inside the test.

## The header law

Generated extraction scaffolds carry a header law in the template itself
(/tmp/ggen-split `templates/module.ex.tera`, verbatim):

```text
# NEVER hand-expand: behavior lands by VERBATIM EXTRACTION from the source
module
```

(actual template line: `# NEVER hand-expand: behavior lands by VERBATIM
EXTRACTION from the source module`)

The law is positioned in every scaffold's comment header: hand-expanding a
scaffold mints behavior that no ontology row, gate, or receipt describes;
verbatim extraction keeps every landed function traceable to the plan row
it implements.

## Related

- [regenerate-without-losing-handwork](../how-to/regenerate-without-losing-handwork.md)
- [multi-agent-compile-freeze-economics](../explanation/multi-agent-compile-freeze-economics.md)
- [generated-files-are-projections](../explanation/generated-files-are-projections.md)
