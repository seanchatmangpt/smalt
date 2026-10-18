defmodule SmaltTest.Wire do
  @moduledoc """
  Shared wire-tier harness mechanics for the auth/egress/eventgrid suites
  (v26.10.18 B5 rewrite, spec: docs/jira/v26.10.18/rewrite-drafts/auth-wire-egress.md §2).

  Assertions stay in the suites; this module owns only lifecycle + transport.
  Zero production-code changes.
  """

  # Compile-freeze unblock (2026-10-18, lane b-await-migration, minimal): a
  # support module is not compiled inside a `use ExUnit.Case` scope, so the
  # auto-imported start_supervised!/1 is not in scope; import it explicitly.
  # Runtime semantics unchanged (callers still invoke from the test process).
  import ExUnit.Callbacks, only: [start_supervised!: 1]

  # -- §2.1 store readiness (consolidates resilient_clear) --------------------

  @clear_retries 50

  @doc """
  Ensure the shared Store is up, then clear it, riding out the async-sibling
  ETS teardown race (i21): a dead-table ArgumentError retries after 10 ms,
  re-ensuring the store each round; persistent failure raises (loud, never
  swallowed). Replaces the private resilient_clear/1 in egress_dispatch_test.exs
  and the bare Store.clear() in kd79/blob_hardening setups.
  """
  def resilient_clear! do
    case do_clear(@clear_retries) do
      :ok -> :ok
      {:error, :store_unavailable} -> raise "shared Store unavailable after retry bound"
    end
  end

  defp do_clear(0), do: {:error, :store_unavailable}

  defp do_clear(retries) do
    SmaltTest.Lifecycle.ensure_store_up()
    Smalt.Store.clear()
    :ok
  rescue
    # ArgumentError only: the `in [message: ...]` rescue form is not legal
    # Elixir (alias-only match) — i21 leak-batch2 narrowing preserved.
    ArgumentError ->
      Process.sleep(10)
      do_clear(retries - 1)
  end

  # -- §2.2 ExUnit-owned private tree (replaces ConfWireSup hand trees) --------

  @doc """
  Boot {Smalt.Store, Bandit(arm), Bandit(egress)} under ExUnit's own supervisor
  via start_supervised!/1 — ExUnit shuts the tree down between tests and links
  failures to the test, removing hand-written stop_tree/stop_existing_tree/
  Process.exit(:kill). The caller stops the shared app tree first
  (stop_existing_tree/0) and pins port envs via pin_ports!/3.
  """
  def start_wire_tree(arm_port: arm, egress_port: egress) do
    start_supervised!(Smalt.Store)

    if arm, do: start_supervised!({Bandit, plug: Smalt.ArmGateway.Router, scheme: :http, port: arm})
    if egress, do: start_supervised!({Bandit, plug: Smalt.EgressRouter, scheme: :http, port: egress})

    :ok
  end

  @doc "Save-prev/put/on_exit-restore for the three port env pins."
  def pin_ports!(arm \\ nil, egress \\ nil, amqp \\ nil) do
    prev = %{
      arm_port: Application.get_env(:smalt, :arm_port),
      egress_port: Application.get_env(:smalt, :egress_port),
      amqp_port: Application.get_env(:smalt, :amqp_port)
    }

    set = fn
      _key, nil -> :ok
      key, val -> Application.put_env(:smalt, key, val)
    end

    set.(:arm_port, arm)
    set.(:egress_port, egress)
    set.(:amqp_port, amqp || get_free_port())

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(prev, fn
        {k, nil} -> Application.delete_env(:smalt, k)
        {k, v} -> Application.put_env(:smalt, k, v)
      end)
    end)

    prev
  end

  @doc """
  Stop the shared app tree before booting a private wire tree (same contract
  as the per-suite copies this promotes: the two-branch whereis shape). The
  name list is the superset (Store + AmqpBroker) — a superset stop is safe
  (each arm tolerates a missing name) and normalizes the divergence between
  the two former eventgrid suites. Shared-tree teardown is bounded +
  non-raising via SmaltTest.Lifecycle.stop_shared_tree/0.
  """
  def stop_existing_tree do
    case Process.whereis(Smalt.Supervisor) do
      nil ->
        for name <- [Smalt.Store, Smalt.AmqpBroker] do
          if pid = Process.whereis(name), do: GenServer.stop(pid)
        end

      _sup ->
        SmaltTest.Lifecycle.stop_shared_tree()
    end
  end

  # -- §2.3 uniform env save/restore -------------------------------------------

  @doc """
  save_restore(auth_mode: :enforce, sts_signing_secret: @secret) — reads each
  key's current value, applies the overrides, and registers an on_exit that
  restores (or deletes when previously unset). Replaces the four divergent
  after/on_exit/Process.put styles in the current suites.

  Delegates the save/restore mechanics to the B0 canonical
  `SmaltTest.Env.put_restored/1` (one implementation of the discipline —
  N-implementations drift law), keeping the spec's call shape.
  """
  defmacro save_restore(overrides) do
    quote do
      SmaltTest.Env.put_restored(unquote(overrides))
    end
  end

  # -- §2.4 raw HTTP/1.1 over :gen_tcp (single copy) ----------------------------

  def get_free_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  @recv_timeout 15_000

  def http_request(port, method, path, opts \\ []) do
    headers = Keyword.get(opts, :headers, [])
    body = Keyword.get(opts, :body, "")

    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5000)

    header_lines =
      Enum.map_join(headers ++ [{"host", "127.0.0.1:#{port}"}, {"connection", "close"}],
        "\r\n", fn {k, v} -> "#{k}: #{v}" end)

    req =
      "#{method} #{path} HTTP/1.1\r\n" <> header_lines <>
        "\r\ncontent-length: #{byte_size(body)}\r\n\r\n" <> body

    :ok = :gen_tcp.send(sock, req)
    raw = recv_all(sock) |> IO.iodata_to_binary()
    :gen_tcp.close(sock)
    parse_response(raw)
  end

  defp recv_all(sock) do
    case :gen_tcp.recv(sock, 0, @recv_timeout) do
      {:ok, data} -> [data | recv_all(sock)]
      {:error, :closed} -> []
    end
  end

  defp parse_response(raw) do
    [head, rest] = :binary.split(raw, "\r\n\r\n")
    [status_line | header_lines] = String.split(head, "\r\n")
    [_, status, _] = String.split(status_line, " ", parts: 3)

    body =
      if header_line_value(header_lines, "transfer-encoding") == "chunked",
        do: decode_chunked(rest),
        else: rest

    %{status: String.to_integer(status), body: body, headers: header_lines}
  end

  defp header_line_value(lines, name) do
    case Enum.find(lines, &String.starts_with?(String.downcase(&1), name)) do
      nil -> nil
      l -> l |> String.split(": ", parts: 2) |> Enum.at(1)
    end
  end

  defp decode_chunked(bin, acc \\ [])

  defp decode_chunked("\r\n" <> rest, acc), do: decode_chunked(rest, acc)

  defp decode_chunked(bin, acc) do
    case Integer.parse(bin, 16) do
      {0, _} ->
        IO.iodata_to_binary(Enum.reverse(acc))

      {size, rest} ->
        <<chunk::binary-size(size), "\r\n", rest2::binary>> = rest
        decode_chunked(rest2, [chunk | acc])

      :error ->
        IO.iodata_to_binary(Enum.reverse(acc))
    end
  end
end
