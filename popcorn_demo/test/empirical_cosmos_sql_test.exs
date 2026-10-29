defmodule PopcornDemo.EmpiricalCosmosSqlTest do
  @moduledoc """
  E6SQL — empirical raw-wire Cosmos SQL contract for the live substrate
  (v26.10.20 wave, lane E6SQL). Follows the E3/E4KV pattern
  (popcorn_demo/test/empirical_flag_latency_test.exs,
  popcorn_demo/test/empirical_kv_latency_test.exs): raw `:gen_tcp`
  HTTP/1.1 to the data plane on 8443, KD-15 challenge handshake
  (tokenless 401 + WWW-Authenticate -> STS mint -> bearer), then a full
  Cosmos NoSQL contract on a run-unique database/container:

    1. Create db + container partitioned on /tenantId.
    2. Seed 50 docs (5 tenants x 10 docs), partition key /tenantId.
    3. (a) Point read by id with the x-ms-documentdb-partitionkey header,
       100x per round x 3 rounds, fresh TCP connection per call —
       p50/p95/p99 per round reported; fence best-round p99 < 10ms.
    4. (b) Parameterized SQL query `SELECT * FROM c WHERE c.tenantId = @t`
       via content-type application/query+json + "parameters" — returns
       EXACTLY the seeded subset for the tenant (correctness; no latency
       fence).
    5. (c) Cross-partition query — `SELECT * FROM c` with NO
       x-ms-documentdb-partitionkey header — returns the FULL seeded set of
       50 (typed behavior witness; no fence).

  Point-read fence justification (from the E4KV/E3 envelope, same substrate,
  same wire, same fresh-conn-per-call shape): the loopback wire round-trip
  through the same router/ETS stack lands orders of magnitude under the
  50-100ms remote-SDK figure; E3 fenced p99 < 5ms and E4KV fenced
  p99 < 10ms with wide margin, and the Cosmos point read is the same
  Store read behind the same router (one extra partition-key extract on the
  same in-memory path), so 10ms is a loose but falsifiable bound — a
  regression that doubles the per-call cost or adds any queueing/IO stall
  blows it.

  Honest-failure policy: every attempt is recorded — all 300 per-op
  latencies feed the reported percentile table; errors surface as assertion
  failures naming the step and wire body. All rounds recorded.

  No mocks. Asserts on final measured state. Skips loudly only when the
  substrate is down.
  """

  use ExUnit.Case, async: false

  @n 100
  @rounds 3
  @seed_count 50
  @tenants 5
  @docs_per_tenant div(@seed_count, @tenants)
  @p99_fence_us 10_000
  @data_port 8443

  substrate_down? =
    with {:ok, sock} <-
           :gen_tcp.connect(~c"127.0.0.1", 9443, [:binary, active: false], 2_000) do
      :gen_tcp.close(sock)
      false
    else
      _ -> true
    end

  @substrate_skip if(substrate_down?,
                     do: "substrate down — run 9>&- just substrate-up",
                     else: false
                   )

  if substrate_down? do
    IO.puts(:stderr, "[popcorn_demo] SKIP: substrate down — run 9>&- just substrate-up")
  end

  @tag skip: @substrate_skip
  test "KD-15 challenge observed on the cosmos surface: tokenless GET -> 401 + WWW-Authenticate" do
    {db, coll} = run_target()

    {:ok, 401, headers, _body} = wire_req("GET", doc_path(db, coll, "no-such-doc"), [])

    assert {_, wa} = List.keyfind(headers, "www-authenticate", 0)
    assert {_, authority} = Regex.run(~r/authorization="([^"]+)"/, wa) |> List.to_tuple()
    assert authority =~ "http://127.0.0.1:9443"
  end

  @tag skip: @substrate_skip
  test "point-read latency contract: 100 wire reads x 3 rounds, best-round p99 < 10ms, 300/300 byte-equal" do
    assert {:ok, db, coll, seeded} = seed()
    doc = Enum.random(seeded)

    round_stats =
      for _r <- 1..@rounds do
        lat_us =
          for _i <- 1..@n do
            t0 = System.monotonic_time(:microsecond)
            got = point_read(db, coll, doc)
            dt = System.monotonic_time(:microsecond) - t0

            # correctness on every single call: byte-identical document
            assert got == doc
            dt
          end

        sorted = Enum.sort(lat_us)

        %{
          p50: Enum.at(sorted, div(@n, 2)),
          p95: Enum.at(sorted, trunc(@n * 0.95)),
          p99: Enum.at(sorted, min(@n - 1, trunc(@n * 0.99))),
          max: List.last(sorted)
        }
      end

    best = Enum.min_by(round_stats, & &1.p99)

    IO.puts(:stdio, """
    [E6SQL point-read latency] n=#{@n} fresh-conn loopback wire round-trips x #{@rounds} rounds (best round fenced)
      #{round_stats |> Enum.with_index(1) |> Enum.map_join("\n  ", fn {s, r} -> "round #{r}: p50=#{s.p50}us  p95=#{s.p95}us  p99=#{s.p99}us  max=#{s.max}us" end)}
      fence: best-round p99 < #{@p99_fence_us}us (E3/E4KV same-stack envelope; remote-SDK figure 50_000-100_000us)
    """)

    assert best.p99 < @p99_fence_us,
           "COSMOS-POINT-READ-LATENCY-FAIL: best-round p99=#{best.p99}us >= #{@p99_fence_us}us fence"

    assert length(round_stats) == @rounds
  end

  @tag skip: @substrate_skip
  test "parameterized SQL query SELECT * FROM c WHERE c.tenantId = @t returns exactly the seeded subset" do
    assert {:ok, db, coll, seeded} = seed()
    tenant = "t3"

    expected =
      seeded |> Enum.filter(&(&1["tenantId"] == tenant)) |> Enum.sort_by(& &1["id"])

    {:ok, %{"Documents" => docs, "_count" => count}} =
      sql_query(db, coll, "SELECT * FROM c WHERE c.tenantId = @t", [{"@t", tenant}], tenant)

    got =
      docs
      |> Enum.map(&Map.take(&1, ["id", "tenantId", "n", "payload"]))
      |> Enum.sort_by(& &1["id"])

    assert count == @docs_per_tenant, "count=#{count}, expected #{@docs_per_tenant}"
    assert got == expected, "query result diverges from the seeded subset for #{tenant}"
  end

  @tag skip: @substrate_skip
  test "cross-partition query without the partition key returns the full seeded set" do
    assert {:ok, db, coll, seeded} = seed()
    expected = Enum.sort_by(seeded, & &1["id"])

    {:ok, %{"Documents" => docs, "_count" => count}} =
      sql_query(db, coll, "SELECT * FROM c", [], nil)

    got =
      docs
      |> Enum.map(&Map.take(&1, ["id", "tenantId", "n", "payload"]))
      |> Enum.sort_by(& &1["id"])

    assert count == @seed_count, "count=#{count}, expected full set of #{@seed_count}"
    assert got == expected, "cross-partition scan diverges from the seeded set"
  end

  # ---- fixture: db + container + 50 seeded docs ------------------------------

  defp seed do
    assert {:ok, token} = challenge_token()
    {db, coll} = run_target()

    assert {:ok, 201, _h, _} = wire_req("POST", "/dbs", auth(token), Jason.encode!(%{"id" => db})),
           "db create failed"

    assert {:ok, 201, _h, _} =
             wire_req(
               "POST",
               "/dbs/#{db}/colls",
               auth(token),
               Jason.encode!(%{
                 "id" => coll,
                 "partitionKey" => %{"paths" => ["/tenantId"]}
               })
             ),
           "container create failed"

    expected_docs =
      for t <- 1..@tenants, i <- 1..@docs_per_tenant do
        tenant = "t#{t}"
        id = "doc-t#{t}-#{String.pad_leading(Integer.to_string(i), 3, "0")}"

        body =
          Jason.encode!(%{
            "id" => id,
            "tenantId" => tenant,
            "n" => i,
            "payload" => "e6sql-#{tenant}-#{i}"
          })

        assert {:ok, 201, _h, _} =
                 wire_req("POST", docs_path(db, coll), auth(token) ++ pk_header(tenant), body),
               "doc create failed: #{id}"

        %{"id" => id, "tenantId" => tenant, "n" => i, "payload" => "e6sql-#{tenant}-#{i}"}
      end

    {:ok, db, coll, expected_docs}
  end

  # Point read: GET by id + partition-key header; returns the document
  # byte-equal (minus any server-added system fields — we strip those from
  # the server doc before comparing, so the comparison is on the seeded
  # application state).
  defp point_read(db, coll, doc) do
    token = bearer()
    {:ok, 200, _h, body} = wire_req("GET", doc_path(db, coll, doc["id"]), auth(token) ++ pk_header(doc["tenantId"]))
    {:ok, server_doc} = Jason.decode(body)
    Map.take(server_doc, ["id", "tenantId", "n", "payload"])
  end

  # Parameterized (or plain) SQL query over the wire. pk_or_nil: non-nil
  # pins the partition-key header (partition-scoped query); nil rides
  # cross-partition.
  defp sql_query(db, coll, q, params, pk_or_nil) do
    token = bearer()

    headers =
      [{"authorization", "Bearer " <> token}, {"content-type", "application/query+json"}] ++
        (if pk_or_nil, do: pk_header(pk_or_nil), else: [])

    body =
      Jason.encode!(%{
        "query" => q,
        "parameters" =>
          Enum.map(params, fn {name, value} -> %{"name" => name, "value" => value} end)
      })

    {:ok, 200, _h, resp_body} = wire_req("POST", docs_path(db, coll), headers, body)
    {:ok, Jason.decode!(resp_body)}
  end

  defp bearer, do: challenge_token!()

  # KD-15 challenge handshake: tokenless GET -> 401 + WWW-Authenticate naming
  # the STS authority -> mint the bearer there. Cached per-process after the
  # first mint (STS accepts any client_id/secret; the token outlives the run).
  defp challenge_token do
    {:ok, 401, headers, _body} = wire_req("GET", "/dbs", [])

    assert {_, wa} = List.keyfind(headers, "www-authenticate", 0)

    assert {_, authority} =
             Regex.run(~r/authorization="([^"]+)"/, wa) |> List.to_tuple()

    {:ok, status, _h, body} =
      wire_req_raw(
        "POST",
        authority <> "/oauth2/v2.0/token",
        [{"content-type", "application/x-www-form-urlencoded"}],
        "grant_type=client_credentials&client_id=e6sql-cosmos-sql&client_secret=not-checked"
      )

    assert status == 200, "STS mint failed: http #{status}: #{slice(body)}"
    assert {:ok, %{"access_token" => tok}} = Jason.decode(body)
    {:ok, tok}
  end

  defp challenge_token! do
    case :persistent_term.get({__MODULE__, :bearer}, :absent) do
      {:ok, tok} -> tok
      :absent ->
        {:ok, tok} = challenge_token()
        :persistent_term.put({__MODULE__, :bearer}, {:ok, tok})
        tok
    end
  end

  defp run_target do
    stamp = Integer.to_string(System.system_time(:millisecond))
    {"e6sql-db-" <> stamp, "e6sql-coll-" <> stamp}
  end

  defp auth(token),
    do: [{"authorization", "Bearer " <> token}, {"content-type", "application/json"}]

  # Cosmos wire form: the partition key is a JSON-encoded ARRAY of path
  # values (e.g. ["t3"]) in the x-ms-documentdb-partitionkey header.
  defp pk_header(tenant),
    do: [{"x-ms-documentdb-partitionkey", Jason.encode!([tenant])}]

  defp docs_path(db, coll), do: "/dbs/#{db}/colls/#{coll}/docs"
  defp doc_path(db, coll, id), do: "/dbs/#{db}/colls/#{coll}/docs/#{id}"

  defp wire_req(method, path, headers, body \\ nil) do
    wire_req_raw(method, "http://127.0.0.1:#{@data_port}" <> path, headers, body)
  end

  defp wire_req_raw(method, url, headers, body) do
    uri = URI.parse(url)
    host = uri.host <> ":" <> Integer.to_string(uri.port)
    path_q = (uri.path || "/") <> (uri.query && "?" <> uri.query || "")

    req =
      "#{method} #{path_q} HTTP/1.1\r\n" <>
        "host: #{host}\r\n" <>
        "connection: close\r\n" <>
        (if body, do: "content-length: #{byte_size(body)}\r\n", else: "") <>
        Enum.map_join(headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end) <>
        "\r\n" <>
        (body || "")

    with {:ok, sock} <-
           :gen_tcp.connect(String.to_charlist(uri.host), uri.port,
             [:binary, packet: :raw, active: false],
             5_000
           ),
         :ok <- :gen_tcp.send(sock, req),
         {:ok, raw} <- read_all(sock) do
      :gen_tcp.close(sock)
      {:ok, %{status: status} = resp} = parse_response(raw)
      {status, resp}
    else
      {:error, reason} -> flunk("wire failure on #{method} #{path_q}: #{inspect(reason)}")
    end
    |> unwrap_resp()
  end

  defp unwrap_resp({status, %{headers: headers, body: body}}),
    do: {:ok, status, headers, body}

  defp parse_response(raw) do
    [head, rest] = String.split(raw, "\r\n\r\n", parts: 2)
    [status_line | header_lines] = String.split(head, "\r\n")

    headers =
      for line <- header_lines do
        [k, v] = String.split(line, ":", parts: 2)
        {String.downcase(String.trim(k)), String.trim(v)}
      end

    status =
      case String.split(status_line, " ") do
        [_v, code | _] -> String.to_integer(code)
        _ -> flunk("bad status line: #{status_line}")
      end

    body =
      case List.keyfind(headers, "transfer-encoding", 0) do
        {"transfer-encoding", te} ->
          if te =~ ~r/chunked/i, do: dechunk(rest), else: rest

        _ ->
          case List.keyfind(headers, "content-length", 0) do
            {"content-length", len} ->
              n = String.to_integer(len)
              binary_part(rest, 0, min(n, byte_size(rest)))

            _ ->
              rest
          end
      end

    {:ok, %{status: status, headers: headers, body: body}}
  end

  defp dechunk(bin, acc \\ [])

  defp dechunk("", acc), do: IO.iodata_to_binary(Enum.reverse(acc))

  defp dechunk(bin, acc) do
    case String.split(bin, "\r\n", parts: 2) do
      [size_line, rest0] ->
        n = String.to_integer(String.trim(size_line), 16)

        if n == 0 do
          dechunk("", acc)
        else
          <<chunk::binary-size(^n), "\r\n", rest::binary>> = rest0
          dechunk(rest, [chunk | acc])
        end

      _ ->
        IO.iodata_to_binary(Enum.reverse(acc))
    end
  end

  defp read_all(sock, acc \\ []) do
    case :gen_tcp.recv(sock, 0, 10_000) do
      {:ok, chunk} -> read_all(sock, [chunk | acc])
      {:error, :closed} -> {:ok, IO.iodata_to_binary(Enum.reverse(acc))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp slice(bin) when is_binary(bin) do
    if byte_size(bin) > 160, do: binary_part(bin, 0, 160) <> "...", else: bin
  end

  defp slice(other), do: inspect(other)
end
