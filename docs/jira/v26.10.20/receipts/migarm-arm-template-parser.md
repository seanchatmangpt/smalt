# MIGARM — ARM template JSON parser (smalt-migrate, PRD Module 1, third language)

**Standing:** ALIVE (all 14 new tests pass; full migrate surface 62 passed / 1 skipped, pre-existing skip)
Repo: /Users/sac/smalt

## Files

- `smalt-cli/smalt_cli/migrate/arm_template.py` (new) — `*.arm.json` extractor
  projecting onto the same `ResourceBlock` shape terraform.py/bicep.py emit;
  reuses `BICEP_TYPE_MAP` (case-normalized, both sides), `_CAMEL_SNAKE`,
  `ResourceBlock`/`ScanError`/`ScanResult` from the existing modules.
- `smalt-cli/tests/test_migrate_arm.py` (new) — 14 tests.
- `smalt-cli/tests/fixtures/migrate/full.arm.json` (new) — all 7 type families
  (cosmos nested db+container with partitionKey.paths, top-level slash-path
  container, storage nested + slash-path containers, SB ns/queue/topic/sub,
  EH ns/hub/cg, vault+secret, APIM) plus one unsupported type.
- `smalt-cli/tests/fixtures/migrate/unresolved.arm.json` (new) — expression
  names/throughput; `broken.arm.json` (new) — malformed JSON.
- **Seam edit (disclosed):** `smalt-cli/smalt_cli/migrate/pipeline.py`
  `scan_all` now merges `.tf` + `.bicep` + `.arm.json` into one ScanResult —
  the same merge path bicep already used. No other shared file touched.

## Semantics

- ARM expressions (`[parameters(...)]`, `[variables(...)]`, `concat(...)`)
  typed `{"raw": ..., "unresolved": True}` — never guessed.
- Parent resolution: nested `resources[]` chains and top-level name-slash
  paths. Literal-named parents resolve by name (existing by_name path);
  expression-named parents resolve via deterministic `ref_hcl` label so
  children stay attached, with the expression typed unresolved.
- Undeclared slash-path ancestors (e.g. `.../legacy/legacyItems` with no
  declared `legacy` db) surface as typed orphans
  (`database_ref_unresolved: true`), never guessed or dropped.
- Storage containers: declared `storageAccounts` ancestor preferred over
  slash segments; `storage_account_ref` set for both nested and slash-path.
- `sku.name` -> `sku` (+ `sku_name` for APIM), `sku.capacity` -> `capacity`,
  `properties.options.throughput` -> `offer_throughput`,
  `partitionKey.paths` -> `partition_key_paths` (via the shared bicep camel
  -> snake path).
- `Microsoft.Storage/storageAccounts` has no topology surface (tf parity:
  no `azurerm_storage_account` in SUPPORTED_TYPES) — counted unsupported.
- Fail-closed: malformed JSON / non-object root / missing string
  `type`/`name` -> typed `unparsable_file` ScanError; block list stays empty.

## Verification (actual output)

```
$ cd smalt-cli && .venv-cli/bin/python -m pytest tests/test_migrate_arm.py -q
14 passed in 0.05s

$ .venv-cli/bin/python -m pytest tests/test_migrate_arm.py tests/test_migrate_scan.py \
    tests/test_migrate_pipeline.py tests/test_migrate_e2e.py tests/test_migrate_inject.py \
    tests/test_migrate_manifest.py tests/test_migrate_verify.py -q
62 passed, 1 skipped in 3.56s

$ .venv-cli/bin/python -m pytest tests/ -q
4 failed, 104 passed, 3 skipped in 43.70s
```

## Pre-existing failures (not session-introduced; disclosed per no-silent-partial)

`tests/test_blob.py::test_immutable_overwrite_409_container_locked`,
`tests/test_cosmos.py::test_whitelist_refuses_grammar_external_queries_400[...]`,
`tests/test_error_codes_doc.py::test_error_codes_doc_is_byte_identical_projection`,
`tests/test_w3_session_ops.py::test_session_state_round_trip` — all four in
files this lane never modified (git status confirms only `pipeline.py` M plus
new files); they fail against the shared tree's in-flight lib/ edits from
other lanes (live-substrate / doc-projection tests, no migrate imports).

## Determinism

`test_parse_deterministic` asserts byte-identical topology JSON across two
full scans of the fixture dir.
