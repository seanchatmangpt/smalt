# Receipt: W4H — Purview Atlas glossary surface (ERRC CREATE lane)

Standing: PARTIAL_ALIVE (module-level surface ALIVE; HTTP routes NOT mounted — route patch lines handed to coordinator, `egress_router.ex` outside lane ownership)
Context: solo
Subject: lib/smalt/data_plane/purview_atlas.ex (exclusive), test/data_plane/purview_glossary_test.exs (new)
Build root: _build-lane-w4h

## Landed

- `glossary/1` (GET /glossary face): glossary record, stable minted guid (`GLOSSARY:` key), `terms` summary (`termGuid` + `displayText`), sorted by name.
- `list_terms/1` (GET /glossary/terms): full term maps, sorted by name.
- `put_term/2` (PUT /glossary/term): create 201 / update 200 keyed on binary `guid`; requires binary `name` (typed 400 `ATLAS-400-00-001`); `definition`, `abbreviation`, `status`, `seeAlso`, `relatedTerms` stored; `assignedEntities` validated BEFORE any write (unknown guid -> 404 `ATLAS-404-00-005`, no partial attach).
- `get_term/2`, `delete_term/2`: unknown term guid -> typed face `ATLAS-404-GLOSSARY-TERM`; DELETE removes the term AND its `AtlasGlossaryTerm` lineage edges (204).
- Term->entity attachment mints real `AtlasGlossaryTerm` edges in `:smalt_purview_edges` — lineage GET shows the term link with zero lineage-code changes; `guidEntityMap` falls back to the term store so the term renders by name instead of `Unknown`.
- Lane-disclosed repair of an audited pre-existing defect in my owned file: `list_typedefs/1` destructured `{k, v}` pairs out of `Store.list/1`, which returns VALUES only — it would raise on any call. Replaced with `prefix_values/2` (Store.keys + get) and reused for `list_terms_raw/0`.

## Command output (real)

Compile (final): `MIX_BUILD_ROOT=_build-lane-w4h mix compile` -> `Generated smalt app` (exit 0; only unrelated warnings from other lanes' files).

Witness (MIX_ENV=test MIX_BUILD_ROOT=_build-lane-w4h mix run /tmp/w4h_witness.exs):

```
TERMS_CREATED 451d806f-e562-cf66-7907-142efb292e69 7e14c0fe-279e-d3a6-0755-b7f7bcb43461
GLOSSARY_TERMS 2
LINEAGE_TERM_LINK true map_name=PII
UNKNOWN_TERM_FACE ATLAS-404-GLOSSARY-TERM
POST_DELETE gone=true code=ATLAS-404-GLOSSARY-TERM
```

Test gate:

```
MIX_BUILD_ROOT=_build-lane-w4h mix test test/data_plane/purview_glossary_test.exs
..
Finished in 0.1 seconds (0.00s async, 0.1s sync)
2 tests, 0 failures
```

Internal tier (pre-existing files, excluding the census file and two foreign in-flight files `arm_dcr_test.exs` / `sb_arm_rules_test.exs` dropped into test/internal by other lanes mid-write — those account for ALL 5 census failures, every violation names only those two files):

```
36 tests, 0 failures
```

Glossary code introduces zero test/internal changes and zero new census-surface tokens.

## Route patch lines for coordinator (egress_router.ex, after the lineage route, ~line 1878)

```elixir
  get "/atlas/v2/glossary" do
    with_route(conn, Purview, fn conn ->
      case Purview.glossary() do
        {:ok, status, body} -> blob_error(conn, status, body)
        {:error, status, body} -> blob_error(conn, status, body)
      end
    end)
  end

  get "/atlas/v2/glossary/terms" do
    with_route(conn, Purview, fn conn ->
      case Purview.list_terms() do
        {:ok, status, body} -> blob_error(conn, status, body)
        {:error, status, body} -> blob_error(conn, status, body)
      end
    end)
  end

  put "/atlas/v2/glossary/term" do
    with_route(conn, Purview, fn conn ->
      with_valid_body(conn, fn conn ->
        case Purview.put_term(conn.body_params, header_map(conn)) do
          {:ok, status, body} -> blob_error(conn, status, body)
          {:error, status, body} -> blob_error(conn, status, body)
        end
      end)
    end)
  end

  get "/atlas/v2/glossary/terms/:guid" do
    with_route(conn, Purview, fn conn ->
      case Purview.get_term(guid, header_map(conn)) do
        {:ok, status, body} -> blob_error(conn, status, body)
        {:error, status, body} -> blob_error(conn, status, body)
      end
    end)
  end

  delete "/atlas/v2/glossary/terms/:guid" do
    with_route(conn, Purview, fn conn ->
      case Purview.delete_term(guid, header_map(conn)) do
        {:ok, status, body} -> blob_error(conn, status, body)
        {:error, status, body} -> blob_error(conn, status, body)
      end
    end)
  end
```

Route blocks mirror the existing `/atlas/v2/entity` handlers exactly
(`with_route` + `blob_error` dispatch, `with_valid_body` on the PUT).
Unverified at the wire level: routes are NOT mounted in this lane
(`egress_router.ex` outside ownership) — mounting + an HTTP-level court are
the coordinator's integration step.

## Compile-freeze disclosures

- arm_gateway/router.ex and data_plane/key_vault_actions.ex were observed mid-edit (syntax errors, undefined functions) by other lanes; lane waited per the compile-freeze SLA (retry loop, ~1-2 min each), never edited their files.
- Fixed a compile-breaking defect in MY OWN file only (Store.list shape misuse; disclosed above).
- test/internal census failures observed during the run are 100% attributable to foreign in-flight files (arm_dcr_test.exs, sb_arm_rules_test.exs) — pre-existing relative to this lane, disclosed for the coordinator.

## Falsifier

Reverting this lane's diff (glossary section + prefix_values) makes `mix test test/data_plane/purview_glossary_test.exs` fail to compile (module functions gone).
