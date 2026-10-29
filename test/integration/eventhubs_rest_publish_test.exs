defmodule Smalt.Egress.W6rEventHubsRestFallthrough do
  # Test-local mount of the `w6r_fallthrough` chain the delegator moduledocs
  # describe: the EH-REST delegator router runs FIRST — it answers its face
  # or passes the conn through un-halted — then the main `Smalt.EgressRouter`
  # handles everything else. Mounting the chain inside `Smalt.EgressRouter`
  # itself is the coordinator's one-line integration step (see
  # `Smalt.Egress.GraphRoutes` moduledoc), deliberately outside the lane
  # lease, so the court boots the chain locally. Delegator-first ordering is
  # load-bearing here: POST /{hub}/messages shares its path shape with the
  # main router's Queue Storage message surface (/{account}/{queue}/messages),
  # so a bare-router boot lets the queue plane answer the EH face.
  # lease, so the court boots the chain locally. The chain runs the router's
  # body-parse plug first (same `@parsers_opts` as
  # `lib/smalt/egress_router.ex` `maybe_parse_body/2`) — harmless for the
  # EH face: application/octet-stream rides `pass: ["*/*"]` unconsumed, so
  # the delegator's capped raw read_body still sees the full body.
  @parsers_opts Plug.Parsers.init(parsers: [:json, :urlencoded], pass: ["*/*"], json_decoder: Jason)

  def init(opts), do: opts

  def call(conn, opts) do
    conn
    |> Plug.Parsers.call(@parsers_opts)
    |> Smalt.Egress.EventHubsRestRoutes.call(opts)
    |> fallthrough()
  end

  defp fallthrough(%Plug.Conn{halted: true} = conn), do: conn

  defp fallthrough(%Plug.Conn{state: state} = conn) when state in [:sent, :chunked], do: conn

  defp fallthrough(conn), do: Smalt.EgressRouter.call(conn, [])
end

defmodule Smalt.Integration.EventHubsRestPublishTest do
  # EH-REST lane court: the Microsoft-documented Event Hubs REST producer face
  # (POST /{hub}/messages) over REAL TCP — Bandit + the real delegator
  # `Smalt.Egress.EventHubsRestRoutes` ahead of the real `Smalt.EgressRouter`
  # (the w6r_fallthrough chain, see `Smalt.Egress.W6rEventHubsRestFallthrough`
  # above) + raw :httpc, no test-adapter conns, no mocks.
  #
  # Gates:
  #   1. happy path: raw HTTP publish with a real SharedAccessSignature header
  #      and x-ms-partition-key -> 201 EMPTY body; the event lands in the
  #      pk-derived partition (KD-76 law: md5(pk) first byte rem 2) and reads
  #      back through the shared partition readout path.
  #   2. bad SAS: tampered sig -> typed 401; missing header -> typed 401.
  #   3. unknown hub (pinned :eh_hubs) -> typed 404 HubNotFound.
  #   4. over-1MiB body -> typed 413 RequestEntityTooLarge.

  use ExUnit.Case, async: false

  @moduletag :eh_rest

  alias Smalt.Amqp.SasVerifier
  alias Smalt.Messaging.EventHubs
  alias Smalt.Store

  @hub "eh-rest-court-hub"
  @pk "kd76-court-pk"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)

    {:ok, sock} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)

    {:ok, _server} =
      Bandit.start_link(plug: Smalt.Egress.W6rEventHubsRestFallthrough, scheme: :http, port: port)

    %{port: port}
  end

  setup context do
    case GenServer.start_link(Store, []) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok = EventHubs.ensure_tables()

    Application.delete_env(:smalt, :eh_hubs)
    Application.delete_env(:smalt, :sb_shared_key)

    on_exit(fn ->
      Application.delete_env(:smalt, :eh_hubs)
      Application.delete_env(:smalt, :sb_shared_key)
    end)

    %{port: context.port, partition: pk_partition(@pk)}
  end

  # -- Gate 1: happy path ------------------------------------------------------

  test "publish with x-ms-partition-key returns 201 empty body and lands in the pk-derived partition",
       %{port: port, partition: expected_partition} do
    body = "rest-published-payload-1"

    {:ok, {{_, 201, _}, _headers, ""}} =
      post(port, "/#{@hub}/messages?api-version=2014-01", sas_headers(port, body), body)

    events = EventHubs.receive_events("#{@hub}/partitions/#{expected_partition}", 0, 100)

    landed =
      Enum.any?(events, fn ev ->
        ev["body"] == body and ev["partition_key"] == @pk
      end)

    assert landed,
           "expected the event in partition #{@hub}/partitions/#{expected_partition} (KD-76 pk law)"
  end

  # -- Gate 2: SAS law ---------------------------------------------------------

  test "tampered signature is a typed 401", %{port: port} do
    body = "bad-sig-body"
    [{"authorization", _good} | rest_headers] = sas_headers(port, body)
    headers = [{"authorization", tampered_token(port)} | rest_headers]

    {:ok, {{_, 401, _}, _headers, resp}} =
      post(port, "/#{@hub}/messages?api-version=2014-01", headers, body)

    assert Jason.decode!(resp)["error"]["code"] == "Unauthorized"
  end

  test "missing authorization header is a typed 401", %{port: port} do
    {:ok, {{_, 401, _}, _headers, resp}} =
      post(port, "/#{@hub}/messages?api-version=2014-01", [], "no-auth-body")

    assert Jason.decode!(resp)["error"]["code"] == "Unauthorized"
  end

  # -- Gate 3: unknown hub -----------------------------------------------------

  test "unknown hub under a pinned namespace is a typed 404", %{port: port} do
    Application.put_env(:smalt, :eh_hubs, [@hub])

    {:ok, {{_, 404, _}, _headers, resp}} =
      post(port, "/no-such-hub/messages?api-version=2014-01", sas_headers(port, "x"), "x")

    assert Jason.decode!(resp)["error"]["code"] == "HubNotFound"
  end

  # -- Gate 4: 1 MiB cap -------------------------------------------------------

  test "body over 1 MiB is a typed 413 RequestEntityTooLarge", %{port: port} do
    body = :binary.copy(<<0>>, 1_048_577)

    {:ok, {{_, 413, _}, _headers, resp}} =
      post(port, "/#{@hub}/messages?api-version=2014-01", sas_headers(port, body), body)

    assert Jason.decode!(resp)["error"]["code"] == "RequestEntityTooLarge"
  end

  # -- helpers -----------------------------------------------------------------

  # The pk-partition law under court (mirrors the route's storage_partition/2):
  # first byte of md5(pk) rem 2 over the pinned partition set ["0", "1"].
  defp pk_partition(pk) do
    bin = if is_binary(pk), do: pk, else: :erlang.term_to_binary(pk)
    <<first::unsigned-8, _::binary>> = :erlang.md5(bin)
    rem(first, 2)
  end

  # Mint a REAL token: SAS string-to-sign is "#{sr}\n#{se}" signed with the
  # shared key SasVerifier verifies with (dev key unless overridden).
  defp sas_headers(port, _body) do
    sr = "sb://127.0.0.1:#{port}/#{@hub}"
    key = SasVerifier.shared_key()
    se = System.system_time(:second) + 3_600
    sig = Base.encode64(:crypto.mac(:hmac, :sha256, key, "#{sr}\n#{se}"))

    token =
      "SharedAccessSignature sr=#{sr}&sig=#{sig}&se=#{se}&skn=RootManageSharedAccessKey"

    [{"authorization", token}, {"x-ms-partition-key", @pk}]
  end

  defp tampered_token(port) do
    [{"authorization", good} | _] = sas_headers(port, "")
    flip_sig(good)
  end

  defp flip_sig(token) do
    case String.split(token, "sig=", parts: 2) do
      [head, tail] ->
        case String.split(tail, "&", parts: 2) do
          [sig, rest] -> head <> "sig=" <> Base.encode64("tampered-sig") <> "&" <> rest
          [sig] -> head <> "sig=" <> Base.encode64("tampered-sig")
        end

      _ ->
        token
    end
  end

  defp post(port, path, headers, body) do
    char_path = String.to_charlist(path)

    char_headers =
      Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    :httpc.request(
      :post,
      {~c"http://127.0.0.1:#{port}" ++ char_path, char_headers, ~c"application/octet-stream",
       body},
      [],
      body_format: :binary
    )
  end
end
