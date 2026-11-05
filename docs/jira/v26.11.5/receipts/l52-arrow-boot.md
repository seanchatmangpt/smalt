# L52 — AoQ Arrow schema-bundle boot write path

Standing: PASS

Repo: /Users/sac/smalt · lane L52 · AOQ Explore LOW-2 · spec
`docs/jira/v26.11.5/aq-architecture-spec.md` §5

## Premise check (done first, per dispatch)

NOT premise-rot — the wiring was genuinely absent, and worse than
described. `lib/smalt/aoq/supervisor.ex` (landed 73eeeee2, clean in the
tree) loaded the bundle via `Arrow.Loader.load/0` and put
`{:aoq, :arrow_schemas}` into `:persistent_term` DIRECTLY — bypassing
`Tables.boot/1` entirely: no seal, no `frame_types`/`epochs` writes, and
a corrupt bundle would have crashed supervisor init with a raw
`MatchError` instead of a typed refusal + fallback.

## Diff

- `lib/smalt/aoq/arrow/boot.ex` (NEW): `Boot.registry/2` — load-verify
  the bundle through the existing court ladder
  (`Bundle.decode` → `Court` grammar/semantic/digest/registry tiers →
  BLAKE3 digest re-derivation), return the verified
  `schema_id => %{schema, digest}` map for `Tables.boot/1`'s
  `:arrow_schemas` opt. Any refusal (missing/corrupt/court-refused
  bundle) is a loud `Logger.error` naming the typed reason + return of
  `Tables.fallback_arrow_schemas()` — the plane always boots.
- `lib/smalt/aoq/tables.ex` (DISCLOSED additive, +12 lines): new public
  `fallback_arrow_schemas/0` exposing the compile-time `@arrow_schemas`
  so Boot's fallback is the same map object, not a re-derived one. The
  `boot/1` seam already accepted an injected `:arrow_schemas` map
  (pre-existing), so no param change was needed — only the fallback
  accessor. `boot/1` behavior unchanged.
- `lib/smalt/aoq/supervisor.ex` (DISCLOSED narrow edit — L11-owned,
  boot-source block only, no child-spec change): the direct
  `:persistent_term.put` replaced with the lawful path
  `Tables.boot(arrow_schemas: Arrow.Boot.registry())`. This also fixes
  the latent gap where supervisor boot never wrote `frame_types` /
  `epochs` / the seal; now a full lawful boot happens before children
  start. supervisor_test.exs: 7 passed (L11's suite, re-run by this
  lane).
- `test/smalt/aoq/arrow/boot_test.exs` (NEW): three-leg court over real
  bundle files in tempdirs, no mocks, no sleeps, `async: false` with
  on_exit `Tables.boot()` restore.

## Court (real files, real restores)

Command:
`MIX_BUILD_ROOT=_build-lane52 mix test test/smalt/aoq/arrow/boot_test.exs test/smalt/aoq/tables_test.exs test/smalt/aoq/arrow.loader_test.exs ...` —
full set: `boot_test.exs tables_test.exs arrow/loader_test.exs
frame_epoch_rotate_test.exs courts/aoq_framing_court.exs` +
`supervisor_test.exs` + `mix compile`

Output (all legs, real exit evidence):

```
Result: 47 passed      (boot + tables + loader + epoch + framing court)
Result: 7 passed       (supervisor_test.exs)
mix compile → "Generated smalt app", 0 errors
```

Three legs:

1. **Real bundle → registry**: real bundle file (utf8+decimal128
   schema, court-verified, BLAKE3 re-derived digest) →
   `Boot.registry(path)` returns the bundle's map; `Tables.boot(arrow_schemas: registry)`
   → `Tables.arrow_schemas()` reads back the bundle schemas via the hot
   path; sealed. 47-pass run.
2. **Corrupt bundle → typed refusal + fallback + loud log**: garbage
   bytes file → `Loader.load` returns
   `{:error, {:bundle_consult, path, {:erl_scan, {:illegal, :character}}}}`
   typed reason; `Boot.registry` logs
   `AOQ Arrow bundle REFUSED at boot (path=...): ... falling back to the compile-time registry`
   at `:error` level (asserted via CaptureLog); plane still boots —
   `Tables.boot(arrow_schemas: Boot.registry(corrupt))` → hot read ==
   fallback registry, sealed. In the 47-pass run.
3. **No bundle → compile-time fallback unchanged**: missing path →
   fallback (enoent typed reason, loud log); bare `Tables.boot()` →
   `Tables.arrow_schemas() == %{} == fallback_arrow_schemas()` — the
   pre-bundle default is byte-identical. Shipped `priv/aoq/arrow_schemas.bundle`
   exists and loads empty. In the 47-pass run.

## Standing

PASS — court green (47 + 7 passed, cited commands + output above), all
three legs on real bundle files, no mocks, no sleeps
(`async: false` + on_exit restore), explicit staging of 5 paths.
