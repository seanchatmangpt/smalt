# BK-EPLAW (v26.10.22): shared ephemeral-port boot preamble for in-process
# test/bench harnesses that call Application.ensure_all_started(:smalt)
# directly (scripts/bench/*.exs). The BK-PORTS2 reconcile
# (docs/jira/v26.10.22/receipts/bkports2-reconcile.md) witnessed the class:
# a harness self-booting outside the flock window collides with real
# substrate windows on the canonical ports (9443/9444/8443/5672/5673).
#
# Contract (mirrors config/test.exs):
#   - Default: EVERY listener gets a probed-free port (bind 0, read, close —
#     same accepted probe-then-close contract as config/test.exs).
#   - Lane-scope pin: an explicit SMALT_TEST_<NAME>_PORT env var wins and is
#     honored verbatim (config/test.exs names; honored even under MIX_ENV=dev,
#     where config/test.exs does not apply — that is the hole this closes).
#   - Per-run journal dirs (kafka/acl) so a bare `mix run` harness never
#     writes a shared dev journal dir.
#
# Usage (top of an exs harness, BEFORE Application.ensure_all_started(:smalt)):
#   Code.require_file(Path.join(__DIR__, "../lib/test_boot_ports.exs"))
#   SmaltTestBoot.pin!()
#
# Production substrate boot (scripts/substrate.sh, config/config.exs) is
# untouched: canonical ports remain correct for the real front door.
defmodule SmaltTestBoot do
  @moduledoc false

  # BK-PORTS2 canonical front-door ports — a pinned or probed port must never
  # land on one of these.
  @canonical [9443, 9444, 8443, 5672, 5673, 9545]

  # {app env key, SMALT_TEST env name, canonical default}
  @listeners [
    {:arm_port, "ARM", 9443},
    {:arm_tls_port, "ARM_TLS", 9444},
    {:egress_port, "EGRESS", 8443},
    {:amqp_port, "AMQP", 5672},
    {:event_hubs_port, "EVENT_HUBS", 5673},
    {:mcp_port, "MCP", 9545},
    {:ws_amqp_relay_port, "WS_RELAY", 5675},
    {:web_pubsub_port, "WPS", 5676},
    {:confidential_ledger_port, "ACL", 8444},
    {:kafka_port, "KAFKA", 9092}
  ]

  @doc "Pins every listener to a probed-free port unless SMALT_TEST_<NAME>_PORT pins it."
  def pin! do
    assigned = MapSet.new()

    Enum.reduce(@listeners, assigned, fn {key, env_name, canonical}, taken ->
      port =
        case System.get_env("SMALT_TEST_#{env_name}_PORT") do
          nil -> free_port_excluding!(MapSet.put(taken, canonical))
          "" -> free_port_excluding!(MapSet.put(taken, canonical))
          val -> {int, ""} = Integer.parse(val)
                 int
        end

      Application.put_env(:smalt, key, port)
      MapSet.put(taken, port)
    end)

    :persistent_term.put({__MODULE__, :pinned}, true)

    unless System.get_env("SMALT_KAFKA_LOG_DIR") do
      Application.put_env(:smalt, :kafka_log_dir, tmp_dir("smalt-eplaw-kafka"))
    end

    unless System.get_env("SMALT_ACL_JOURNAL_DIR") do
      Application.put_env(:smalt, :acl_journal_dir, tmp_dir("smalt-eplaw-acl"))
    end

    :ok
  end

  @doc """
  BK-EPLAW2 fail-closed fence (BK-EPLAW law: fences, not doc discipline).

  Call AFTER `pin!/0` and BEFORE `Application.ensure_all_started(:smalt)`.
  Aborts with a typed FATAL (exit 1) unless the pinned-port contract holds:
  `pin!/0` ran in this VM, or explicit `SMALT_TEST_<NAME>_PORT` env pins are
  present, AND no listener env resolved to a canonical front-door port.
  """
  def fence!(harness \\ "harness") do
    pinned_here? = :persistent_term.get({__MODULE__, :pinned}, false)

    explicit? =
      Enum.any?(@listeners, fn {_, env_name, _} ->
        case System.get_env("SMALT_TEST_#{env_name}_PORT") do
          nil -> false
          "" -> false
          _ -> true
        end
      end)

    canonical_hits =
      for {key, env_name, canonical} <- @listeners,
          Application.get_env(:smalt, key) == canonical do
        {key, env_name, canonical}
      end

    cond do
      canonical_hits != [] ->
        fatal!(harness, {
          :canonical_port_binding,
          canonical_hits,
          "call SmaltTestBoot.pin!() before boot, or move SMALT_TEST_<NAME>_PORT pins off canonical ports"
        })

      pinned_here? or explicit? ->
        :ok

      true ->
        fatal!(harness, {
          :missing_pin_contract,
          "no SmaltTestBoot.pin!() call and no SMALT_TEST_<NAME>_PORT env pins",
          "require scripts/lib/test_boot_ports.exs and call SmaltTestBoot.pin!() before Application.ensure_all_started(:smalt)"
        })
    end
  end

  defp fatal!(harness, reason) do
    IO.puts("""
    [FATAL] #{harness}: pinned-port contract VIOLATED — refusing to boot on canonical defaults.
    Reason: #{inspect(reason)}
    Fix: Code.require_file("test_boot_ports.exs", Path.join(File.cwd!(), "scripts/lib"))
         SmaltTestBoot.pin!(); SmaltTestBoot.fence!("#{harness}")
         (or export explicit SMALT_TEST_<NAME>_PORT pins off the canonical five)
    """)

    System.halt(1)
  end

  @doc "Pinned/probed port for a listener (post-pin introspection for courts)."
  def port(key), do: Application.get_env(:smalt, key)

  @doc "Canonical front-door ports that must never be bound by a test boot."
  def canonical_ports, do: @canonical

  def free_port_excluding!(taken, tries \\ 50)

  def free_port_excluding!(_taken, 0), do: raise("SmaltTestBoot: no free port found")

  def free_port_excluding!(taken, tries) do
    port = free_port!()

    if MapSet.member?(taken, port) or port in @canonical do
      free_port_excluding!(taken, tries - 1)
    else
      port
    end
  end

  defp free_port! do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defp tmp_dir(name) do
    Path.join(System.tmp_dir!(), "#{name}-#{:rand.uniform(1_000_000_000)}")
  end
end
