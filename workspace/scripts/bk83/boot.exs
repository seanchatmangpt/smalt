# BK-83 enforce-mode witness runtime: real EgressRouter + real Sync.Store +
# real ArmGateway.Router (the production STS mint face) over real TCP.
# Auth mode: :enforce (default) — the sync surface finally authenticated.
Application.ensure_all_started(:telemetry)
Application.ensure_all_started(:jason)
{:ok, _} = Application.ensure_all_started(:bandit)

{:ok, _} = Smalt.Sync.Store.start_link([])
{:ok, _} =
  Bandit.start_link(plug: Smalt.EgressRouter, scheme: :http, port: 18543, ip: {127, 0, 0, 1})
{:ok, _} =
  Bandit.start_link(plug: Smalt.ArmGateway.Router, scheme: :http, port: 18581, ip: {127, 0, 0, 1})

IO.puts("BK83_BOOT_OK enforce sync=:18543 sts=:18581")
Process.sleep(:infinity)
