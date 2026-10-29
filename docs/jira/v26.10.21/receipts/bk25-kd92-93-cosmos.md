# BK-25 — KD-92 + KD-93 fix lane receipt

**Standing: ALIVE** — both DISPOSITIONED rows witnessed closed on a live substrate;
KD-92 fix landed (`# KD-COVERS: KD-92`), KD-93 refuted as probe artifact (emulator
parity-correct, falsifier passes with a correctly-formed query).
**Context: solo**
Date: 2026-10-21 · Lane: BK-25 · Build root: `_build-bk25` · No commit (per lane order).

## KD-92 — ARM container PUT not visible to blob data plane

**Root cause**: the ARM child PUT route for
`.../blobServices/default/containers/:name` wrote only the `:smalt_resources`
record (generic `handle_child_put/5`) — the blob data plane's
`:smalt_blob_containers` DETS was never populated, so a subsequent data-plane
blob PUT answered 404 `ContainerNotFound`. Real Azure: an ARM-created container
is immediately visible to the blob data plane.

**Fix** (`lib/smalt/arm_gateway/router.ex`, `# KD-COVERS: KD-92`):
- blob-container child PUT now routes through
  `handle_storage_container_child_put/5` → `handle_child_put/6` with a
  post-PUT mirror hook `seed_blob_container/3` that writes the exact
  `do_create_container` record shape into `:smalt_blob_containers`
  (mirror-only-when-absent: never clobbers a data-plane-created container's
  WORM/immutability state; silently skipped when the blob tables are absent —
  control plane stays independent of data-plane readiness, same contract as
  `seed_cosmos_child`).
- `handle_child_put` gained an optional 6th `after_put` hook arg (default nil —
  all 5-arg call sites unchanged). The hook runs only AFTER the resource record
  lands, so a refused PUT never seeds.

### Before (divergence LIVE — default build, pre-fix)

```
$ TS=$(date +%s); DB="bk921792637209"; ARM="http://127.0.0.1:9443"; EG="http://127.0.0.1:8443"
$ curl -s -o /dev/null -w "%{http_code}" -X PUT -H "Authorization: Bearer $TOK" \
    "$ARM/subscriptions/.../storageAccounts/$DB?api-version=2021-04-01" -d '{...}'
202
$ curl -s -o /dev/null -w "%{http_code}" -X PUT -H "Authorization: Bearer $TOK" \
    "$ARM/.../storageAccounts/$DB/blobServices/default/containers/kd92c?api-version=2021-04-01" -d '{}'
201
$ curl -s -X PUT -H "Authorization: Bearer $TOK" -H "x-ms-version: 2021-12-02" \
    -H "x-ms-blob-type: BlockBlob" "$EG/$DB/kd92c/bk92.txt" --data-binary hello
404 <Error><Code>ContainerNotFound</Code></Error>     # ← divergence
```

### After (fix live on substrate — falsifier PASS)

```
$ # substrate bounced to the lane build (mix run recompiles the shared source,
$ # so the running beam includes the landed fix; confirmed: seed_blob_container
$ # present in the loaded Router.beam via strings(1) — both _build/dev and
$ # _build-bk25 beams carry it)
$ curl ... ARM PUT storageAccounts/bk92f1792639014            → 202
$ curl ... ARM PUT .../containers/kd92c                       → 201
$ curl ... PUT https://127.0.0.1:8443/bk92f1792639014/kd92c/bk92.txt → 201   # ← falsifier PASS
# re-witness on the next substrate boot (another lane bounce), fresh account:
$ ARM PUT storageAccounts/bk92h1792639077 → 202; containers/kd92c → 201; blob PUT → 201
# negative leg (mirror is per-container, not blanket auto-vivify):
$ PUT $EG/bk92f1792639014/kd92nope/n.txt (never ARM-created)  → 404 ContainerNotFound
# negative control (data-plane container create path unchanged):
$ PUT $EG/$DB/kd92e?restype=container → 201; blob PUT → 201
```

### Regression legs

```
$ MIX_BUILD_ROOT=_build-bk25 mix test test/integration/arm_dcr_test.exs \
    test/integration/namespace_put_test.exs            # exit 0 — 8 passed, 0 failures
$ MIX_BUILD_ROOT=_build-bk25 mix test test/internal/rg404_concurrent_lifecycle_court.exs
                                                       # exit 0 — 512 cycles, 0 failures
$ MIX_BUILD_ROOT=_build-bk25 mix test test/data_plane/cosmos_sql_raise_test.exs \
    test/data_plane/cosmos_k2_rows_witness_test.exs    # exit 0 — 27 passed, 0 failures
$ MIX_BUILD_ROOT=_build-bk25 mix compile               # exit 0
```

## KD-93 — cosmos query feed "phantom doc" (probe artifact, NOT a lib divergence)

**Root cause (proven live)**: the query POST was misrouted to **doc-create**
because the probe used `Content-Type: application/json`. smalt routes query
POSTs on `application/query+json` (`Smalt.EgressRouter.query_post?/1`), and a
doc-create POST without `"id"` auto-generates `doc_<unique_integer>` — real
Azure Cosmos does the same (auto-generated id when the client omits it). The
"phantom `doc_637510` the run never wrote" WAS written by the run itself, by
the misrouted request; a later correctly-routed feed then honestly answers that
self-minted row. Emulator behavior is real-Azure parity end to end.

### Reproduction of the phantom mechanism (fresh db `bk93m1792638005`, no pk)

```
$ curl -H "Content-Type: application/json" -X POST .../dbs/$DB/colls/c1/docs \
    -d '{"query":"SELECT * FROM c WHERE c.mark = @mark","parameters":[...]}'
201 {"id":"doc_13445","query":"SELECT * FROM c WHERE ...",...}   # ← the "phantom" is self-minted
$ curl -H "Content-Type: application/query+json" -X POST .../dbs/$DB/colls/c1/docs \
    -d '{"query":"SELECT * FROM c"}'
200 ids: ['doc_13445']                                            # feed honestly answers it
```

### After (correctly-formed query — falsifier PASS, re-witnessed on 2 boots)

```
$ # fresh db/coll (pk /mark), doc PUT 201, then immediately:
$ curl -H "Content-Type: application/query+json" \
    -H 'x-ms-documentdb-partitionkey: ["bk93-mark"]' -X POST .../dbs/bk93g*/colls/c1/docs \
    -d '{"query":"SELECT * FROM c WHERE c.mark = @mark","parameters":[{"name":"@mark","value":"bk93-mark"}]}'
200 ids: ['bk93doc1']      # just-written id, no phantom — falsifier PASS
# (earlier boot, db bk93f/bk93b-class fresh db: identical result ids: ['bk93doc1'])
```

Scoping/freshness faces of the original mint were already closed by the lane-523
query-feed code (`Store.list_prefix("#{db}/#{coll}/")` — db/coll-scoped scan,
`Smalt.CosmosSql.eval_docs` parameterized filtering over current store state);
marked `# KD-COVERS: KD-93` at that code (comment-only edit to
`lib/smalt/data_plane/cosmos.ex`).

## Register flips

`scripts/kd_flip.py --apply` (receipt-gated; this receipt postdates both
`# KD-COVERS` shims). Both rows flip OPEN → CLOSED-SIMULATED per the tool's
single flip class; the KD-93 row keeps its probe-artifact root cause inline.

## Boundary notes

- KD-92 delete-side sweep (ARM child DELETE also sweeping the mirrored
  `:smalt_blob_containers` row) is NOT in this diff — disposition scope was the
  PUT mirror; noted as a residual open question for the register.
- BK-11's fresh-probe evidence rows in `bk11-kd-legacy-triage.md` are stale
  (its probe lacked the query+json content-type); this receipt supersedes.
- Another lane owns kv keys routes (BK-24) — no files under that lane touched.
- Substrate bounced twice mid-lane by other lanes (pids 41215 → 48942); both
  falsifiers re-witnessed on the final boot.
