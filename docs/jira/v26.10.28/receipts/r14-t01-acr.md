# r14 — T-01: Azure Container Registry control plane + Tasks (FileTaskRunRequest / EncodedTaskRunRequest)

- window: v26.10.28 · ticket: `tickets/T01-acr-control-plane-and-tasks.md` · date: 2026-10-29
- tier: beam (`test/integration/acr_test.exs`) · status: **CODE-COMPLETE (r14), awaiting integration run**

## landed

1. **ARM `Microsoft.ContainerRegistry/registries` CRUD + `listKeys` + webhooks**
   (`lib/smalt/arm_gateway/providers/acr_router.ex`, engine
   `lib/smalt/data_plane/acr.ex`): PUT registry is 201 create / 200 idempotent
   re-put (`registry_put` acr_router.ex:149; `create_registry/2` acr.ex:96 —
   re-put preserves the original `creationDate`), GET echo, GET LIST at
   resource-group scope (`registries_list` acr_router.ex:199 via
   `Store.list_prefix`), and DELETE as a **typed 202 LRO** —
   Azure-AsyncOperation/Location/Retry-After headers over the real
   `Smalt.ArmGateway.LRO.start_op` seam (`registry_delete` acr_router.ex:180),
   with an eager cascade of the registry's child rows
   (`delete_registry/1` acr.ex:147). POST `…/registries/:name/listKeys`
   answers the real `RegistryListCredentialsResult` shape (`username` +
   `passwords[{name, value}]` password/password2, `registry_list_keys`
   acr_router.ex:216; `list_keys/1` acr.ex:169); the real-API
   `listCredentials` operation is answered on the same handler. `credentials/1`
   (acr.ex:68) is the single source of truth — deterministic sha256 material
   (SB authorization-rule style), `loginServer` on the metadata DNS suffix
   `registry.smalt.local` (`arm_gateway/router.ex:4220`).
   Webhooks are registry children with typed PUT 201/200 re-put, GET, LIST,
   DELETE faces (`webhook_put` acr_router.ex:301). Regenerations
   (`regenerateCredential`) and `replications` are NOT in this round — the r14
   scope line for this ticket was registries CRUD + listKeys + webhooks; both
   are typed follow-ups, not divergences.
2. **ACR Tasks runs (simulated state machine, no container execution)**:
   POST `…/registries/:name/scheduleRun` accepts `FileTaskRunRequest`
   (requires `taskPath`; smalt has no source-control fetch, so an inline
   base64 copy may ride the family's `encodedTaskContent` member) and
   `EncodedTaskRunRequest` (requires base64 `encodedTaskContent`) —
   (`schedule_run` acr_router.ex:231; `put_run/2` acr.ex:205). Validation is
   fail-closed with typed codes: `ValidationError`,
   `UnsupportedRunRequestType`, `InvalidEncodedTaskContent`,
   `InvalidTaskContent`; unknown registry seat is 404 `RegistryNotFound`.
   The run is a `Microsoft.ContainerRegistry/registries/runs` row stored on
   the downcased resource-id key with its queue stamp `_acr_queued_ms`; the
   status machine walks **Queued → Running (300 ms) → Succeeded (800 ms)**
   lazily on GET/LIST observation and persists the advance
   (`advance_run` acr.ex:439; thresholds acr.ex:53-54). GET `…/runs/:run`
   (acr_router.ex:246), LIST `…/runs` (acr_router.ex:259, registry-existence
   gated), and GET `…/runs/:run/logs` — the logLink target face as a
   text/plain stream of the run's RECORDED SYNTHETIC output in real acr-run
   log typology ("Executing step ID: build. …", terminal "Run ID: … was
   successful after Ns" landing exactly on the Succeeded flip) —
   (acr_router.ex:278). The smalt-private members (`logs`, `_acr_queued_ms`,
   `_acr_task`) are stripped from wire renders (`render_run`
   acr_router.ex:569). `append_log/2` (acr.ex:250) and `list_runs/0`
   (acr.ex:236) complete the engine surface. The engine exports EXACTLY the
   nine contracted functions.
3. **Registry data-plane metadata surface (simulated), auth with the listed
   keys**: mounted under `/acr/:registry/v2` inside the same pass-through
   plug (`handle_v2` acr_router.ex:390): GET `/v2/_catalog` answers
   repositories = blob containers of the registry-named account
   (`v2_catalog` acr_router.ex:410), GET `/v2/:repo/tags/list` answers tags =
   blob names (`v2_tags` acr_router.ex:424) — both read the REAL
   blob-backed store tables (`:smalt_blob_containers` / `:smalt_blobs`;
   seeding in the court goes through `Smalt.DataPlane.BlobStorage`).
   Access is docker Basic auth against `credentials/1`
   (`authenticate_registry` acr_router.ex:441): no/incorrect credentials get
   the typed 401 `UNAUTHORIZED` + `WWW-Authenticate: Basic realm="<loginServer>"`
   challenge; an unknown registry seat is 404 `NAME_UNKNOWN`.
4. **Task YAML parses through YamlElixir** (`read_from_string/1`,
   parse seam acr.ex:336): NO hand-rolled YAML parser. The common ACR
   task-file shape is tolerated (`steps:` list; step `id` + one of
   build/push/cmd/task/login/logout); `{{.Values.<name>}}` placeholders
   substitute from the request's `values` BEFORE parsing (acr.ex:357); step
   content rides the recorded synthetic logs, and the PARSED task — including
   unknown YAML fields verbatim — maps into the recorded run body under the
   `_acr_task` member (acr.ex:412).

**Pass-through discipline**: `call/2` (acr_router.ex:61) pattern-matches
`conn.path_info`/method (`own?` acr_router.ex:74); any conn the ACR plane
does not own — including ACR-namespaced paths with unknown sub-actions —
returns UNCHANGED so the router pipeline composes (the main router's generic
provider routes / catch-all still see them). Non-ACR conns are not even
query-fetched.

## court

`Smalt.Internal.AcrTest` (`test/integration/acr_test.exs`) — in-process
dispatch of `Smalt.ArmGateway.Providers.AcrRouter.call/2` with Plug.Test
conns (mirrors `sb_arm_rules_test.exs` conventions), real
`Smalt.Store` `:smalt_resources` rows on the downcased resource-id key
convention, real blob-backed store, real LRO seam. 6 tests:

1. PUT registry 201 → idempotent re-PUT 200 (creationDate preserved) →
   GET echo → LIST → listKeys shape (password/password2) agreeing with
   `credentials/1` + the `listCredentials` alias (line 150).
2. scheduleRun FileTaskRunRequest → 201 Queued → poll walk Running →
   Succeeded (lifecycle timestamps filled) → logs text carries the
   YamlElixir-parsed step lines + terminal line; logLink seats the
   credentials/1 server; wire render is log-free; LIST runs terminal
   (line 215).
3. EncodedTaskRunRequest with `values` substitution (`{{.Values.Tag}}`) →
   recorded step output; `_acr_task` carries the parsed steps verbatim;
   typed refusals: bad base64 `InvalidEncodedTaskContent`,
   `UnsupportedRunRequestType` (DockerBuildRequest — no container
   execution), missing member `ValidationError`, unparseable YAML
   `InvalidTaskContent`, unknown registry `RegistryNotFound` 404
   (line 281).
4. Webhooks: PUT 201 → idempotent 200 → GET → LIST → DELETE → 404; missing
   parent 404 (line 352).
5. `/v2` catalog + tags over the blob-backed store: 401 challenge
   (WWW-Authenticate realm = loginServer) anonymous and wrong-password;
   catalog/tags 200 under docker Basic auth with the listed keys;
   unknown seat 404 NAME_UNKNOWN (line 405).
6. DELETE registry → typed 202 LRO (async headers + op record) completing
   `Succeeded` via `LRO.get_op`; registry/credentials/runs cascade; runs
   LIST on the missing parent 404; unknown-registry delete 404 (line 447).

**Not yet executed** — the r14 lane is code-only per the compile-freeze SLA
(no mix/test/git in this pass); the court runs with the next integration
pass and this receipt + the ticket stamp say so.

## DoD mapping (ticket "Definition of Done")

- "`az acr create -n myreg --sku Basic` returns a registry with
  `provisioningState: Succeeded` and a `loginServer` on the smalt DNS
  suffix" → court test 1 (`sku` from the PUT body defaults Basic;
  `loginServer = "<name>.registry.smalt.local"` = metadata suffix
  `containerRegistry`).
- "`az acr run --file task.yaml` returns a run id; polling walks Queued →
  Running → Succeeded; logs stream the recorded step output" → court tests
  2–3 (scheduleRun 201 with the run id; GET run poll face; GET logs text
  stream).
- "`az acr list` / `az acr show` answer the same shapes real Azure does" →
  court test 1 (echo/LIST + typed type/id/name/sku/properties members).
- "Deleting the registry answers a typed 202 LRO that completes" → court
  test 6 (Azure-AsyncOperation face; `LRO.get_op` terminal Succeeded).
- "An `@azure/arm-containerregistry` SDK client does the same with zero code
  changes" → rides the integration pass (`parity/reports/<runid>/` acr
  suite + a `verification/ts/` probe) — pending, stated by the ticket stamp.

## integration wiring (EXACT patch — the integrator applies it)

Single line added to the `Smalt.ArmGateway.Router` plug pipeline
(`lib/smalt/arm_gateway/router.ex`), immediately BEFORE `plug(:match)`
(line 77) and AFTER `plug(Smalt.Egress.ThrottlePlug)` (line 76 — the ACR
surface rides the parsed body params and the auth/throttle posture):

```diff
   plug(Smalt.Egress.ThrottlePlug)
+  plug(Smalt.ArmGateway.Providers.AcrRouter)
   plug(:match)
   plug(:dispatch)
```

The line to add verbatim:

```elixir
  plug(Smalt.ArmGateway.Providers.AcrRouter)
```

## dependency note — yaml_elixir (per 2026-10-29 scope directive)

Task YAML parses with **YamlElixir** (`YamlElixir.read_from_string/1`).
`yaml_elixir` is a **TRANSITIVE dep today**: present and compiled in the
deps tree (`mix.lock` pins `yaml_elixir 2.12.2`, pulled by `reactor
1.0.7` under its `{:yaml_elixir, "~> 2.11"}` requirement; `deps/yaml_elixir`
verified). This r14 code compiles against the version already present. The
integrator should PROMOTE it to a direct dependency at integration time by
adding to `mix.exs` `deps/`:

```elixir
{:yaml_elixir, "~> 2.11"}
```

(matches the existing constraint version — the lock resolves it to
`yaml_elixir 2.12.2`; no lock churn).

## notes

- **`regenerateKey`/`regenerateCredential` and `replications` are follow-ups**,
  not divergences: the r14 scope line for T-01 was registries CRUD +
  listKeys + webhooks; the ticket's scope item 1 mentions both extras and
  they should land as a small additive pass on the same two files (deterministic
  credentials make regeneration a seed-rotation design decision worth its
  own receipt line).
- **Admin user**: the honest dev face defaults `adminUserEnabled` TRUE and
  always lists credentials (real Azure defaults FALSE and 400s listCredentials
  when disabled). Typed divergence — the /v2 auth flow depends on it.
- **FileTaskRunRequest inline content**: real ACR fetches the task file from
  source control; smalt (air-gap, no real execution) simulates against an
  OPTIONAL inline base64 copy under the family's `encodedTaskContent`
  member. Content-less FileTaskRunRequest is accepted and runs with no
  parsed steps (header + terminal log lines only).
- **Nested repo names**: the simulated catalog maps repositories 1:1 to blob
  containers (3-63 chars, no slashes), so slash-separated repos
  (`team/app`) are a typed follow-up (blob container naming forbids slashes).
- **Store contract**: every row (registries, webhooks, runs) lives in
  `:smalt_resources` under the downcased resource-id key — mirrors how
  `sb_arm_rules_test.exs` seeds `:smalt_resources`; run cascade on registry
  delete is a key-prefix sweep (`Store.prefix_keys`).

File scope: exactly the four files named below were written/changed by r14.

## files

- `lib/smalt/data_plane/acr.ex` (NEW — engine; exports exactly
  credentials/1, create_registry/2, get_registry/1, delete_registry/1,
  list_keys/1, put_run/2, get_run/1, list_runs/0, append_log/2)
- `lib/smalt/arm_gateway/providers/acr_router.ex` (NEW — pass-through Plug)
- `test/integration/acr_test.exs` (NEW — court, 6 tests, NOT yet run)
- `docs/jira/v26.10.28/receipts/r14-t01-acr.md` (THIS receipt)
- `docs/jira/v26.10.28/tickets/T01-acr-control-plane-and-tasks.md`
  (status stamp only)
