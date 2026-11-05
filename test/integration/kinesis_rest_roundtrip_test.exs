defmodule Smalt.Egress.W6rKinesisFallthrough do
  # Test-local mount of the w6r_fallthrough chain (same shape as
  # `Smalt.Egress.W6rEventHubsRestFallthrough` in
  # test/integration/eventhubs_rest_publish_test.exs): the Kinesis delegator
  # runs FIRST — it answers POST / with an X-Amz-Target or passes the conn
  # through un-halted — then the main `Smalt.EgressRouter` handles everything
  # else. Mounting the chain inside `lib/smalt/egress_router.ex` is the
  # coordinator's one-line integration step, deliberately outside this lane's
  # lease (DISCLOSED mount line: `plug Smalt.Egress.KinesisRoutes` ahead of
  # the existing face plugs in the egress_router plug chain).
  @parsers_opts Plug.Parsers.init(parsers: [:json, :urlencoded], pass: ["*/*"], json_decoder: Jason)

  def init(opts), do: opts

  def call(conn, opts) do
    conn
    |> Plug.Parsers.call(@parsers_opts)
    |> Smalt.Egress.KinesisRoutes.call(opts)
    |> fallthrough()
  end

  defp fallthrough(%Plug.Conn{halted: true} = conn), do: conn

  defp fallthrough(%Plug.Conn{state: state} = conn) when state in [:sent, :chunked], do: conn

  defp fallthrough(conn), do: Smalt.EgressRouter.call(conn, [])
end

defmodule Smalt.Integration.KinesisRestRoundtripTest do
  # K-IN lane court: the AWS Kinesis JSON protocol face over REAL TCP —
  # Bandit + the real `Smalt.Egress.KinesisRoutes` ahead of the real
  # `Smalt.EgressRouter` (w6r_fallthrough chain, see
  # `Smalt.Egress.W6rKinesisFallthrough` above) + raw :httpc, no mocks.
  #
  # Gates:
  #   1. roundtrip byte-fidelity: PutRecord -> 200 {ShardId, SequenceNumber}
  #      (plain decimal, KD-KIN-2); GetRecords reads back the exact bytes.
  #   2. auth falsifier: missing authorization -> 403 UnrecognizedClientException;
  #      pinned posture: valid SigV4 -> 200, tampered signature -> 403.
  #   3. pinned-stream 400: pinned :kinesis_streams -> unknown stream ->
  #      400 ResourceNotFoundException (botocore metadata law).
  #   4. 1 MiB boundary: exactly 1 MiB Data admitted; 1 MiB + 1 -> 400
  #      InvalidArgumentException.
  #   5. iterator semantics: AT_SEQUENCE_NUMBER inclusive vs AFTER exclusive
  #      vs LATEST; NextShardIterator advances.
  #   6. cross-face convergence: Kinesis PutRecord lands in the SAME store
  #      row its Event Hubs twin uses (KD-76 shard law, KD-KIN-4).

  use ExUnit.Case, async: false

  @moduletag :kinesis_rest

  alias Smalt.Messaging.EventHubs

  @pin %{
    access_key_id: "SMALTAKID",
    secret_access_key: "smalt-dev-secret",
    region: "smalt-1"
  }

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)

    {:ok, sock} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)

    {:ok, _server} =
      Bandit.start_link(plug: Smalt.Egress.W6rKinesisFallthrough, scheme: :http, port: port)

    %{port: port}
  end

  setup context do
    case GenServer.start_link(Smalt.Store, []) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok = EventHubs.ensure_tables()

    Application.delete_env(:smalt, :kinesis)
    Application.delete_env(:smalt, :kinesis_streams)

    on_exit(fn ->
      Application.delete_env(:smalt, :kinesis)
      Application.delete_env(:smalt, :kinesis_streams)
    end)

    %{port: context.port, run: System.unique_integer([:positive])}
  end

  # -- Gate 1: roundtrip byte-fidelity ------------------------------------------

  test "put_record roundtrips exact bytes with a plain-decimal sequence number",
       %{port: port, run: run} do
    stream = "kin-rt-#{run}"
    body = "kinesis-roundtrip-payload-#{run}"
    pk = "pk-#{run}"

    %{"ShardId" => shard, "SequenceNumber" => seq} =
      action!(port, "PutRecord", %{
        "StreamName" => stream,
        "Data" => Base.encode64(body),
        "PartitionKey" => pk
      })

    assert shard == "shardId-00000000000#{String.to_integer(Smalt.Egress.KinesisRoutes.pk_partition(pk))}"
    assert seq == Integer.to_string(String.to_integer(seq))
    assert String.length(seq) < 56, "KD-KIN-2: SequenceNumber is a plain decimal, not 56-digit"

    records = read_all(port, stream, shard)
    assert [%{"Data" => data, "PartitionKey" => ^pk, "SequenceNumber" => ^seq}] = records
    assert Base.decode64!(data) == body
  end

  # -- Gate 2: auth falsifier ---------------------------------------------------

  test "missing authorization is a typed 403 UnrecognizedClientException", %{port: port, run: run} do
    {:ok, {{_, 403, _}, _headers, resp}} =
      post(port, [], Jason.encode!(%{"StreamName" => "s", "Data" => "", "PartitionKey" => "p"}))

    assert from_type(resp) == "UnrecognizedClientException"
  end

  test "pinned posture: valid SigV4 admitted, tampered signature refused", %{port: port, run: run} do
    Application.put_env(:smalt, :kinesis, @pin)
    stream = "kin-auth-#{run}"
    req = %{"StreamName" => stream, "Data" => Base.encode64("auth-body"), "PartitionKey" => "pk"}

    {:ok, {{_, 200, _}, _headers, _}} = post(port, sigv4_headers(port, req), Jason.encode!(req))

    tampered =
      Enum.map(sigv4_headers(port, req), fn
        {"authorization", "AWS4-HMAC-SHA256 " <> rest} ->
          {"authorization",
           "AWS4-HMAC-SHA256 " <> String.replace(rest, "Signature=", "Signature=0000")}

        other ->
          other
      end)

    {:ok, {{_, 403, _}, _headers, resp}} = post(port, tampered, Jason.encode!(req))
    assert from_type(resp) == "InvalidSignatureException"
  end

  # -- Gate 3: pinned-stream 400 -------------------------------------------------

  test "unknown stream under a pinned :kinesis_streams list is a typed 400",
       %{port: port, run: run} do
    Application.put_env(:smalt, :kinesis_streams, ["kin-known-#{run}"])

    {:ok, {{_, 400, _}, _headers, resp}} =
      action_raw(port, "PutRecord", %{
        "StreamName" => "kin-unknown-#{run}",
        "Data" => Base.encode64("x"),
        "PartitionKey" => "pk"
      })

    assert from_type(resp) == "ResourceNotFoundException"
  end

  # -- Gate 4: 1 MiB boundary ----------------------------------------------------

  test "exactly 1 MiB Data is admitted, 1 MiB + 1 is a typed 400", %{port: port, run: run} do
    stream = "kin-cap-#{run}"
    exactly = :binary.copy(<<0>>, 1_048_576)

    %{"ShardId" => shard} =
      action!(port, "PutRecord", %{
        "StreamName" => stream,
        "Data" => Base.encode64(exactly),
        "PartitionKey" => "pk"
      })

    assert read_all(port, stream, shard)
           |> Enum.any?(fn r -> Base.decode64!(r["Data"]) == exactly end)

    {:ok, {{_, 400, _}, _headers, resp}} =
      action_raw(port, "PutRecord", %{
        "StreamName" => stream,
        "Data" => Base.encode64(:binary.copy(<<0>>, 1_048_577)),
        "PartitionKey" => "pk"
      })

    assert from_type(resp) == "InvalidArgumentException"
  end

  # -- Gate 5: iterator semantics -------------------------------------------------

  test "AT_SEQUENCE_NUMBER is inclusive, AFTER exclusive, LATEST starts at the tip",
       %{port: port, run: run} do
    stream = "kin-iter-#{run}"
    shard = shard_name(Smalt.Egress.KinesisRoutes.pk_partition("iter-pk"))

    seqs =
      for i <- 1..3 do
        %{"SequenceNumber" => seq} =
          action!(port, "PutRecord", %{
            "StreamName" => stream,
            "Data" => Base.encode64("iter-#{i}"),
            "PartitionKey" => "iter-pk"
          })

        String.to_integer(seq)
      end

    assert [s1, s2, s3] = seqs

    # AT_SEQUENCE_NUMBER n -> n is INCLUDED (iterator at n-1, exclusive read).
    at =
      action!(port, "GetShardIterator", %{
        "StreamName" => stream,
        "ShardId" => shard,
        "ShardIteratorType" => "AT_SEQUENCE_NUMBER",
        "SequenceNumber" => Integer.to_string(s2)
      })

    assert [%{"SequenceNumber" => at_seq}] = get_records_raw(port, at["ShardIterator"], 1)["Records"]
    assert String.to_integer(at_seq) == s2

    # AFTER_SEQUENCE_NUMBER n -> n EXCLUDED, next record is n+1.
    after_tok =
      action!(port, "GetShardIterator", %{
        "StreamName" => stream,
        "ShardId" => shard,
        "ShardIteratorType" => "AFTER_SEQUENCE_NUMBER",
        "SequenceNumber" => Integer.to_string(s2)
      })

    assert [%{"SequenceNumber" => after_seq}] =
             get_records_raw(port, after_tok["ShardIterator"], 1)["Records"]

    assert String.to_integer(after_seq) == s3

    # LATEST -> iterator at the tip; a fresh GetRecords returns nothing.
    latest =
      action!(port, "GetShardIterator", %{
        "StreamName" => stream,
        "ShardId" => shard,
        "ShardIteratorType" => "LATEST"
      })

    assert [] = read_all(port, stream, shard, latest["ShardIterator"])
  end

  test "NextShardIterator advances and GetRecords honors the Limit cap", %{port: port, run: run} do
    stream = "kin-next-#{run}"
    shard = shard_name(Smalt.Egress.KinesisRoutes.pk_partition("next-pk"))

    for i <- 1..3 do
      action!(port, "PutRecord", %{
        "StreamName" => stream,
        "Data" => Base.encode64("next-#{i}"),
        "PartitionKey" => "next-pk"
      })
    end

    trim = get_iterator(port, stream, shard, "TRIM_HORIZON")

    %{"Records" => first_page, "NextShardIterator" => next} =
      get_records_raw(port, trim["ShardIterator"], 2)

    assert length(first_page) == 2
    assert [r3] = read_all(port, stream, shard, next)
    assert Base.decode64!(r3["Data"]) == "next-3"
  end

  # -- Gate 6: cross-face convergence ---------------------------------------------

  test "kinesis PutRecord and EventHubs.receive_events meet in one store row",
       %{port: port, run: run} do
    stream = "kin-xface-#{run}"
    pk = "xface-pk-#{run}"
    body = "xface-payload-#{run}"

    %{"ShardId" => _shard, "SequenceNumber" => seq} =
      action!(port, "PutRecord", %{
        "StreamName" => stream,
        "Data" => Base.encode64(body),
        "PartitionKey" => pk
      })

    idx = String.to_integer(Smalt.Egress.KinesisRoutes.pk_partition(pk))
    partition = "#{stream}/partitions/#{idx}"

    eh_events = EventHubs.receive_events(partition, 0, 100)

    assert Enum.any?(eh_events, fn ev ->
             ev["body"] == body and Integer.to_string(ev["seq"]) == seq and
               ev["partition_key"] == pk
           end),
           "expected the Kinesis record in EH store row #{partition} with the same seq (KD-KIN-4)"
  end

  # -- helpers -------------------------------------------------------------------

  defp action!(port, action, req) do
    {:ok, {{_, 200, _}, _headers, resp}} = action_raw(port, action, req)
    Jason.decode!(resp)
  end

  defp action_raw(port, action, req) do
    headers = [
      {"x-amz-target", "Kinesis_20131202.#{action}"},
      {"content-type", "application/x-amz-json-1.1"},
      {"authorization", "AWS4-HMAC-SHA256 Credential=SMALTAKID/dev/smalt-1/kinesis/aws4_request, SignedHeaders=host;x-amz-date, Signature=#{fake_sig()}"}
    ]

    post(port, headers, Jason.encode!(req))
  end

  defp fake_sig, do: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

  # Mint a REAL SigV4 authorization header via the same aws_signature library
  # the route verifies with (re-sign-and-compare must admit its own twin).
  defp sigv4_headers(port, body) do
    x_amz_date = amz_date()

    headers = [
      {"host", "127.0.0.1:#{port}"},
      {"x-amz-date", x_amz_date}
    ]

    body_bin = Jason.encode!(body)

    computed =
      :aws_signature.sign_v4(
        "SMALTAKID",
        "smalt-dev-secret",
        "smalt-1",
        "kinesis",
        amz_date_tuple(x_amz_date),
        "POST",
        "https://localhost/",
        headers,
        body_bin
      )

    {"Authorization", auth} = Enum.find(computed, fn {k, _} -> k == "Authorization" end)

    [
      {"authorization", auth},
      {"x-amz-date", x_amz_date},
      {"content-type", "application/x-amz-json-1.1"},
      {"x-amz-target", "Kinesis_20131202.PutRecord"}
    ]
  end

  defp amz_date do
    {{y, mo, d}, {h, mi, s}} = :calendar.universal_time()
    :io_lib.format(~c"~4..0B~2..0B~2..0BT~2..0B~2..0B~2..0BZ", [y, mo, d, h, mi, s])
    |> IO.iodata_to_binary()
  end

  defp amz_date_tuple(date_bin) do
    <<y::binary-size(4), mo::binary-size(2), d::binary-size(2), "T", h::binary-size(2),
      mi::binary-size(2), s::binary-size(2), "Z">> = date_bin

    {{String.to_integer(y), String.to_integer(mo), String.to_integer(d)},
     {String.to_integer(h), String.to_integer(mi), String.to_integer(s)}}
  end

  defp get_iterator(port, stream, shard, type, extra \\ %{}) do
    action!(port, "GetShardIterator", %{
      "StreamName" => stream,
      "ShardId" => shard,
      "ShardIteratorType" => type
    })
    |> Map.merge(extra)
  end

  defp read_all(port, stream, shard, iterator \\ nil) do
    token = iterator || get_iterator(port, stream, shard, "TRIM_HORIZON")["ShardIterator"]

    collect(port, token, [])
  end

  defp collect(_port, nil, acc), do: Enum.reverse(acc)

  defp collect(port, token, acc) do
    %{"Records" => records, "NextShardIterator" => next} = get_records_raw(port, token, 10_000)

    acc = Enum.reverse(records) ++ acc

    # Records empty => NextShardIterator sits at the same seq; stop.
    if records == [] do
      Enum.reverse(acc)
    else
      collect(port, next, acc)
    end
  end

  defp get_records_raw(port, token, limit) do
    action!(port, "GetRecords", %{"ShardIterator" => token, "Limit" => limit})
  end

  defp shard_name("0"), do: "shardId-000000000000"
  defp shard_name("1"), do: "shardId-000000000001"

  defp from_type(resp) do
    %{"__type" => type} = Jason.decode!(resp)
    type |> String.split("#") |> List.last()
  end

  defp post(port, headers, body) do
    char_path = '/'

    char_headers =
      Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    :httpc.request(
      :post,
      {~c"http://127.0.0.1:#{port}" ++ char_path, char_headers, ~c"application/x-amz-json-1.1",
       body},
      [],
      body_format: :binary
    )
  end
end
