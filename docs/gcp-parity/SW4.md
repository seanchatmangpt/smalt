# SW4 Receipt

Standing: UNVERIFIED

Authoring lane: no mix/just/git run. Nothing compiled or tested.

## Files (all new)

- lib/smalt/gcp/run_logging_router.ex (Smalt.GCP.RunLoggingRouter)
- test/gcp/run_logging_router_test.exs (Plug.Test, real engines, no mocks, no sleeps)

## Route function (for SW2)

`Smalt.GCP.RunLoggingRouter.route(%Plug.Conn{}) :: Plug.Conn.t() | nil`. No constructor, no
process to start. Returns a halted conn or nil. Reads the JSON body itself. Matches
`/v2/projects/{p}/locations/{l}/...` (services, revisions, operations, :getIamPolicy,
:setIamPolicy), `/v2/entries:write|list`, `/v2/projects/{p}/sinks[/{id}]`. Sinks are plain rows
under `gcp:logsink:` (no export); errors use `{"error":{code,message,status}}`.
