# SW1 application.ex GCP wiring receipt

Standing: UNVERIFIED

Edited without mix/just/git (lane law). Gate for coordinator: `mix compile --warnings-as-errors`.
No result is claimed here.

## Diff (lib/smalt/application.ex)

- `children`: `... Smalt.Monitor.Metrics] ++ gcp_children() ++ mcp_tail ++ ...`
- new `defp gcp_children/0` returning:
  - `Smalt.GCP.Storage.Server` (GS1; GenServer, own child_spec, named)
  - `Smalt.Gcp.PubSub` (GS2; GenServer start_link/1, named; code spelling `Gcp`)
  - `%{id: Smalt.GCP.SecretManager, start: {Smalt.GCP.SecretManager, :start_link, []}}` (GS4; unnamed Agent)
  - `%{id: Smalt.GCP.KMS, start: {Smalt.GCP.KMS, :start_link, []}}` (GS4; unnamed Agent)

## Not wired (verified by reading code)

GS3 Firestore (Store-backed), GS5 Identity/IAM (stateless), GS6 CloudRun/Logging: no
start_link/child_spec, no children needed.

## Divergence

SecretManager/KMS Agents are unnamed: router needs their pids (e.g. via Supervisor.which_children
by id) or a later `name:` change in those modules.
