# BOOTPROF cut #2 (RELCUT, NFR-FOOTPRINT): phased listener start boot probe.
#
# Run as `mix run --no-start scripts/deferred_boot_probe.exs` (MIX_ENV=test).
# Boots the real Smalt.Application on the test config's ephemeral ports with
# real TCP accepts (no sleeps: bounded connect polls on real observables) and
# emits one JSON line:
#
#   {"deferred": bool, "accepted_ms": {"arm": .., "egress": .., "arm_tls": ..,
#    "amqp": .., "event_hubs": .., "mcp": ..}}
#
# SMALT_DEFERRED_LISTENERS=1 flips the boot to phased (front door first,
# deferred listeners via handle_continue after a tick). Exit 0 always; the
# caller (the ExUnit court) asserts on the JSON faces.

deferred? = System.get_env("SMALT_DEFERRED_LISTENERS") in ["1", "true"]
Application.put_env(:smalt, :deferred_listeners, deferred?)

t0 = System.monotonic_time(:millisecond)
{:ok, _} = Application.ensure_all_started(:smalt)

port_of = fn key, env, default ->
  Application.get_env(:smalt, env, default)
end

ports = %{
  arm: port_of.(:arm, :arm_port, 9443),
  egress: port_of.(:egress, :egress_port, 8443),
  arm_tls: port_of.(:arm_tls, :arm_tls_port, 9444),
  amqp: port_of.(:amqp, :amqp_port, 5672),
  event_hubs: port_of.(:event_hubs, :event_hubs_port, 5673),
  mcp: port_of.(:mcp, :mcp_port, 9545)
}

front_door = [:arm, :egress]
deferred_keys = [:arm_tls, :amqp, :event_hubs, :mcp]

# Bounded connect-poll (no sleeps): retry :gen_tcp.connect until the listener
# accepts or the deadline lapses, then read the socket once to confirm.
accept_ms = fn key ->
  port = Map.fetch!(ports, key)
  deadline = System.monotonic_time(:millisecond) + 15_000

  loop = fn loop ->
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 250) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        System.monotonic_time(:millisecond) - t0

      {:error, _} ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "listener #{key} on port #{port} never accepted within 15s"
        end

        loop.(loop)
    end
  end

  loop.(loop)
end

accepted =
  front_door
  |> Enum.map(fn k -> {k, accept_ms.(k)} end)
  |> Map.new()
  |> Map.merge(Map.new(deferred_keys, fn k -> {k, accept_ms.(k)} end))

Jason.encode!(%{
  deferred: deferred?,
  boot_ms: System.monotonic_time(:millisecond) - t0,
  accepted_ms: accepted
})
|> IO.puts()

dbg = fn ->
  IO.puts(
    :stderr,
    "PROBE_PORTS=#{inspect(%{arm: Application.get_env(:smalt, :arm_port), egress: Application.get_env(:smalt, :egress_port)})}"
  )
end

dbg.()
