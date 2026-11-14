# SW2 egress router GCP wiring

Standing: UNVERIFIED

Authored without mix/just/git. Gate to run: `mix test test/gcp`. Nothing compiled.

## Diff (lib/smalt/egress_router.ex only)

- `plug(:gcp_plane)` mounted after `:sqs_query_face`, BEFORE `Smalt.Auth.Bearer` and
  `:maybe_parse_body` (GCP routers read their own bodies and own auth), so GCS and
  the blob splat (`StorageCatchAll`, runs post-dispatch) never see GCP paths.
- `gcp_family/1` claim table, `gcp_serve/2` per family, `gcp_call/3` (missing module
  -> 503 RouteNotReady; `nil` route result -> pass through un-halted).
- Secret Manager / KMS: pid-addressed Agents lazily started once (unlinked parked
  owner, pid in `:persistent_term`), `handle/5` -> `{status, map}` JSON. Supervision
  children would be cleaner (disclosed gap).
- Firestore Router is a Plug.Router meant for `forward "/v1"`: path_info/script_name
  are adjusted manually and restored.

## Collision analysis

Family is chosen by the segment after `/v1/projects/{p}/`: topics|subscriptions|
snapshots -> Pub/Sub; databases -> Firestore; secrets -> Secret Manager;
locations/{l}/keyRings -> KMS. Disjoint literals, no overlap. Cloud Run
(`/v2/projects/_/locations/_/services|operations`), sinks, `/v2/entries:write|list`
-> `Smalt.GCP.RunLoggingRouter.route/1`. Azure `/v1/workspaces`, `/v1.0/*`, `/v2/track`,
`/keys`, `/secrets` differ at segment 2 or 1 and are never claimed. Host-style GCS
claims only hosts ending `storage.googleapis.com`.

## Gaps

`Smalt.GCP.Storage.Server` and Pub/Sub engine still need application children
(GS1/GS2 wiring, not this lane). No signing_key passed to host-style GCS.
