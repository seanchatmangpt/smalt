defmodule Smalt.Posh.PoshClientTest do
  use ExUnit.Case, async: false

  import SmaltTest.AssertEventually

  alias Smalt.Posh.Client

  @max_frame_bytes 4 * 1024 * 1024

  setup do
    path = "/tmp/smalt-w2e2-#{System.unique_integer([:positive])}.sock"
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  defp start_client(path) do
    name = String.to_atom("posh_client_" <> Integer.to_string(System.unique_integer([:positive])))

    start_supervised!(
      {Client, socket_path: path, name: name},
      restart: :temporary
    )

    name
  end

  defp start_acceptor(path, opts \\ []) do
    silent = Keyword.get(opts, :silent, false)
    mode = if silent, do: :silent, else: Keyword.get(opts, :mode, :echo)
    parent = self()

    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ip: {:local, path}])

    accept_pid =
      spawn(fn ->
        accept_loop(listen, parent, mode)
      end)

    {:ok, listen, accept_pid}
  end

  defp accept_loop(listen, parent, mode) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        send(parent, {:w2e2_accepted, self()})
        serve_loop(sock, mode)
        accept_loop(listen, parent, mode)

      {:error, :closed} ->
        :ok
    end
  end

  # Echo server speaking the wire protocol. When :silent, it accepts the
  # connection but never answers — for the deadline case. When :garbage, it
  # answers every request with a JSON envelope of no recognized shape.
  defp serve_loop(sock, mode) do
    case :gen_tcp.recv(sock, 4, 5_000) do
      {:ok, <<len::32-big>>} when len > 0 and len <= @max_frame_bytes ->
        {:ok, payload} = :gen_tcp.recv(sock, len, 5_000)
        req = Jason.decode!(payload)

        unless mode == :silent do
          resp =
            cond do
              mode == :garbage ->
                Jason.encode!(%{"id" => req["id"], "nonsense" => true})

              req["op"] == "echo" ->
                Jason.encode!(%{"id" => req["id"], "ok" => %{"result" => req["params"]}})

              true ->
                Jason.encode!(%{
                  "id" => req["id"],
                  "error" => %{"code" => "UPSTREAM", "message" => "unknown op \"#{req["op"]}\""}
                })
            end

          :ok = :gen_tcp.send(sock, <<byte_size(resp)::32-big, resp::binary>>)
        end

        serve_loop(sock, mode)

      _other ->
        :gen_tcp.close(sock)
        :ok
    end
  end

  test "typed transport error when the socket path is missing", %{path: path} do
    client = start_client(path)
    assert {:error, {:transport, %{message: _}}} = Client.request(client, "echo", %{"m" => "x"})
  end

  test "echo round-trip against a real UDS wire-protocol acceptor", %{path: path} do
    {:ok, _listen, acceptor} = start_acceptor(path)
    client = start_client(path)

    assert_eventually(fn -> Client.status(client) == :connected end, timeout: 2_000)
    assert_receive {:w2e2_accepted, ^acceptor}, 2_000

    assert {:ok, %{"result" => %{"msg" => "hello"}}} =
             Client.request(client, "echo", %{"msg" => "hello"})
  end

  test "unknown op maps to typed upstream error", %{path: path} do
    {:ok, _listen, _acceptor} = start_acceptor(path)
    client = start_client(path)

    assert_eventually(fn -> Client.status(client) == :connected end, timeout: 2_000)

    assert {:error, {:upstream, %{code: "UPSTREAM", message: msg}}} =
             Client.request(client, "nope", %{})

    assert msg =~ "unknown op"
  end

  test "deadline expiry returns typed deadline error", %{path: path} do
    {:ok, _listen, _acceptor} = start_acceptor(path, silent: true)
    client = start_client(path)

    assert_eventually(fn -> Client.status(client) == :connected end, timeout: 2_000)

    assert {:error, {:deadline, %{message: _}}} =
             Client.request(client, "echo", %{"msg" => "x"}, deadline_ms: 150)
  end

  test "oversized request is refused client-side at the 4 MiB cap", %{path: path} do
    {:ok, _listen, _acceptor} = start_acceptor(path)
    client = start_client(path)

    assert_eventually(fn -> Client.status(client) == :connected end, timeout: 2_000)

    assert {:error, {:transport, %{reason: :frame_too_large}}} =
             Client.request(client, "echo", %{"blob" => String.duplicate("a", 5 * 1024 * 1024)})
  end

  test "reconnect recovery after the acceptor dies (typed transport, then recovery)", %{
    path: path
  } do
    {:ok, listen, acceptor} = start_acceptor(path)
    client = start_client(path)

    assert_eventually(fn -> Client.status(client) == :connected end, timeout: 2_000)
    assert {:ok, _} = Client.request(client, "echo", %{"n" => "1"})

    # Kill the acceptor: the socket path stops serving and the connection drops.
    Process.exit(acceptor, :kill)
    :gen_tcp.close(listen)
    File.rm(path)

    assert {:error, {:transport, _}} = Client.request(client, "echo", %{"n" => "2"})

    # Acceptor returns: the client must reconnect on its send_after backoff.
    {:ok, _listen2, _acceptor2} = start_acceptor(path)

    assert_eventually(
      fn ->
        match?({:ok, %{"result" => %{"n" => "3"}}}, Client.request(client, "echo", %{"n" => "3"}))
      end,
      timeout: 5_000
    )

    assert pid = GenServer.whereis(client)
    assert Process.alive?(pid)
  end

  test "second request while one is in flight is refused typed :request_in_flight", %{path: path} do
    {:ok, _listen, _acceptor} = start_acceptor(path, silent: true)
    client = start_client(path)

    assert_eventually(fn -> Client.status(client) == :connected end, timeout: 2_000)

    # Two concurrent callers on a silent acceptor: exactly one takes the
    # pending slot and deadlines; the other is refused typed in-flight.
    results =
      [
        Task.async(fn -> Client.request(client, "echo", %{"n" => "1"}, deadline_ms: 2_000) end),
        Task.async(fn -> Client.request(client, "echo", %{"n" => "2"}, deadline_ms: 2_000) end)
      ]
      |> Task.await_many(10_000)

    busy = Enum.count(results, &match?({:error, {:transport, %{reason: :request_in_flight}}}, &1))
    deadline = Enum.count(results, &match?({:error, {:deadline, %{}}}, &1))

    assert busy == 1
    assert deadline == 1
  end

  test "unrecognized envelope shape is a typed :bad_envelope transport error", %{path: path} do
    {:ok, _listen, _acceptor} = start_acceptor(path, mode: :garbage)
    client = start_client(path)

    assert_eventually(fn -> Client.status(client) == :connected end, timeout: 2_000)

    assert {:error, {:transport, %{reason: :bad_envelope, message: "malformed response envelope"}}} =
             Client.request(client, "echo", %{"n" => "1"})
  end

  test "params that are not a map are refused typed", %{path: path} do
    {:ok, _listen, _acceptor} = start_acceptor(path)
    client = start_client(path)

    assert_eventually(fn -> Client.status(client) == :connected end, timeout: 2_000)

    assert {:error, {:transport, %{message: "params must be a map"}}} =
             Client.request(client, "echo", [not: "a_map"])
  end
end
