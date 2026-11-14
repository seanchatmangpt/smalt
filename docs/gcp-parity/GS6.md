# GS6 Receipt

Standing: UNVERIFIED

Authoring lane: no mix/just/git run. Nothing compiled or tested.

## Files (all new)

- lib/smalt/gcp/cloud_run.ex (Smalt.GCP.CloudRun)
- lib/smalt/gcp/logging.ex (Smalt.GCP.Logging)
- test/gcp/run_logging_test.exs (real Store, no mocks, no sleeps)
- docs/gcp-parity/GS6-run-census.md, GCP_WIRE_PARITY.md, KD-GCP-CANDIDATES.md

## Wiring

Engines are wire-free and need only `:smalt_resources` (existing). Router (to be mounted by
the GS5 host-keyed `Smalt.GCP.Router`) maps: POST `/v2/projects/:p/locations/:l/services`
(`serviceId` query) -> `create_service/4`; GET/PATCH/DELETE `.../services/:s` ->
`get/replace/delete_service`; GET `.../services/:s/revisions[/:r]`; GET
`/v2/projects/:p/locations/:l/operations/:id` -> `get_operation/1`; POST
`.../services/:s:getIamPolicy|:setIamPolicy`; POST `/v2/entries:write|:list` ->
`Logging.write_entries/1`, `list_entries/1`. Errors are `{:error, {http, status, msg}}`.
Run first: `mix test test/gcp/run_logging_test.exs`.
