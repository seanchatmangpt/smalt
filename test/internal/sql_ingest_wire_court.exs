defmodule Smalt.Egress.W6rSqlIngestFallthrough do
  # Test-local mount of the `w6r_fallthrough` chain the delegator moduledocs
  # describe: the delegator router runs FIRST — it answers its face or passes
  # the conn through un-halted — then the main `Smalt.EgressRouter` (blob
  # splat + 404 catch-all) handles everything else. Mounting the chain inside
  # `Smalt.EgressRouter` itself is the coordinator's one-line integration step
  # (see `Smalt.Egress.GraphRoutes` moduledoc), deliberately outside the lane
  # lease, so the court boots the chain locally. Any non-sql-ingest request
  # passes through the delegator's catch-all and is answered by the REAL main
  # router — the pass-through arm of the delegator is court-exercised, not
  # dead code. The chain runs the router's body-parse plug first (same
  # `@parsers_opts` as `lib/smalt/egress_router.ex` `maybe_parse_body/2`):
  # the delegator's `with_valid_body/2` consumes `conn.body_params`, which
  # only Plug.Parsers fills.
  @parsers_opts Plug.Parsers.init(parsers: [:json, :urlencoded], pass: ["*/*"], json_decoder: Jason)

  def init(opts), do: opts

  def call(conn, opts) do
    conn
    |> Plug.Parsers.call(@parsers_opts)
    |> Smalt.Egress.SqlIngestRoutes.call(opts)
    |> fallthrough()
  end

  defp fallthrough(%Plug.Conn{halted: true} = conn), do: conn

  defp fallthrough(%Plug.Conn{state: state} = conn) when state in [:sent, :chunked], do: conn

  defp fallthrough(conn), do: Smalt.EgressRouter.call(conn, [])
end

defmodule Smalt.SqlIngestWireCourtTest do
  use ExUnit.Case, async: false

  # GLD-3 wire court (v26.10.21): POST /sql-ingest — the SQL ingestion wire
  # face. Chicago discipline: real collaborators everywhere — the real
  # delegator `Smalt.Egress.SqlIngestRoutes` ahead of the real
  # `Smalt.EgressRouter` (the w6r_fallthrough chain, see
  # `Smalt.Egress.W6rSqlIngestFallthrough` above) served over a real Bandit
  # TCP listener, real HTTP POSTs via :httpc, real `Smalt.SqlIngest`
  # COPY-block parse, real `Smalt.Powl2.AndonWire` 422 envelope, real
  # `Smalt.Ocel` envelope validation. No mocks; assertions are on wire bytes
  # (status, headers, JSON body).
  #
  # Context: solo (internal tier, in-process Bandit + :httpc loopback).

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    port = free_port()

    start_supervised!(
      {Bandit, plug: Smalt.Egress.W6rSqlIngestFallthrough, scheme: :http, port: port}
    )

    wait_listening(port, 20)
    {:ok, port: port}
  end

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defp wait_listening(port, tries) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [], 500) do
      {:ok, s} ->
        :gen_tcp.close(s)
        :ok

      _ when tries > 0 ->
        # SLEEP-CLASS: POLL-STEP — bounded listen-reachable poll on the
        # observable that matters: a real TCP accept on the Bandit port.
        Process.sleep(100)
        wait_listening(port, tries - 1)

      _ ->
        flunk("bandit never listened on #{port}")
    end
  end

  defp wire(port, body) do
    wire_raw(
      :post,
      'http://127.0.0.1:#{port}/sql-ingest',
      Jason.encode!(body)
    )
  end

  defp wire_raw(method, url, req_body) do
    {:ok, result} =
      :httpc.request(
        method,
        {url, [{'content-type', 'application/json'}], 'application/json', req_body},
        [],
        body_format: :binary
      )

    result
  end

  defp dump(parts), do: Enum.join(parts, "\n")

  @good_dump """
  CREATE TABLE events (id bigint, kind text);
  COPY events (id, kind) FROM stdin;
  1\tspawn
  2\tfinish
  \\.
  """

  # The SHACL gate traveling to the wire face: the poisoned COPY target
  # `"users"` (quoted identifier, metacharacter-laden) fails the SqlIngest
  # identifier guard -> andon 422, nothing from the dump is ingested.
  @poisoned_dump """
  COPY kinds (k, v) FROM stdin;
  a\t1
  \\.
  COPY "users; DROP TABLE users; --" (id, kind) FROM stdin;
  1\tboom
  \\.
  """

  test "201: a clean pg_dump COPY-block projects to an OCEL summary", ctx do
    body = %{
      "format" => "postgres_dump",
      "mapping_iri" => "https://example.com/mapping/evt-1",
      "data_b64" => Base.encode64(dump([@good_dump]))
    }

    {{_, status, _}, _headers, resp} = wire(ctx.port, body)

    assert status == 201, "expected 201, got #{status}: #{inspect(resp)}"
    payload = Jason.decode!(resp)

    assert payload["status"] == "ingested"
    assert payload["format"] == "postgres_dump"
    assert payload["mappingIri"] == "https://example.com/mapping/evt-1"

    # SQLD-2 keying: the bare table name is the map key (schema qualifier
    # stripped — "public.events" and "events" collide on one key).
    assert [%{"name" => "events", "columns" => ["id", "kind"], "rowCount" => 2}] =
             payload["tables"]

    # 1 table object + 1 mapping object; 1 SqlTableIngested event.
    assert payload["ocel"] == %{"eventCount" => 1, "objectCount" => 2}
  end

  test "422: injection-token table name answers the GraphlawRefusal andon envelope", ctx do
    body = %{
      "format" => "postgres_dump",
      "mapping_iri" => "https://example.com/mapping/evt-2",
      "data_b64" => Base.encode64(dump([@poisoned_dump]))
    }

    {{_, status, _}, headers, resp} = wire(ctx.port, body)

    assert status == 422, "expected 422, got #{status}: #{inspect(resp)}"
    err = Jason.decode!(resp)["error"]

    assert err["code"] == "GraphlawRefusal"
    assert err["rule_id"] == "sql.injection_token"
    assert err["diagnostic"] =~ "users;"
    assert err["repair_hint"] =~ "identifier guard"
    assert err["context_digest"] =~ ~r/^[0-9a-f]{64}$/
    assert is_binary(err["agent_message"])
    assert is_binary(err["session"])
    assert is_integer(err["ts"])

    assert Enum.any?(headers, fn {k, v} ->
             k == 'x-ms-error-code' and v == 'BusinessLawViolation'
           end)
  end

  test "400 faces: malformed JSON, empty body, missing fields, bad base64, unsupported format",
       ctx do
    url = 'http://127.0.0.1:#{ctx.port}/sql-ingest'

    {{_, s1, _}, _, _} = wire_raw(:post, url, '{"format": ')
    assert s1 == 400

    {{_, s2, _}, _, _} = wire_raw(:post, url, '{}')
    assert s2 == 400

    {{_, s3, _}, _, r3} = wire(ctx.port, %{"format" => "postgres_dump"})
    assert s3 == 400
    assert Jason.decode!(r3)["error"]["code"] == "InvalidSqlIngestRequest"

    {{_, s4, _}, _, r4} =
      wire(ctx.port, %{
        "format" => "postgres_dump",
        "mapping_iri" => "https://example.com/m",
        "data_b64" => "!!!not-base64!!!"
      })

    assert s4 == 400
    assert Jason.decode!(r4)["error"]["code"] == "InvalidDataEncoding"

    # Format the pipeline does not (yet) wire: loud typed 400, never a 404.
    {{_, s5, _}, _, r5} =
      wire(ctx.port, %{
        "format" => "sqlite",
        "mapping_iri" => "https://example.com/m",
        "data_b64" => Base.encode64("SQLite format 3\0")
      })

    assert s5 == 400
    assert Jason.decode!(r5)["error"]["code"] == "UnsupportedSqlFormat"
    assert Jason.decode!(r5)["error"]["message"] =~ "sqlite"
  end

  test "fallthrough: a non-sql-ingest request passes the delegator un-halted to the main router",
       ctx do
    # The delegator's pass-through arm is real: an unmatched GET must NOT be
    # swallowed at the delegator (500 FunctionClauseError class) — it falls
    # through to the main router's 404 catch-all (Azure XML error envelope).
    {:ok, {{_, status, _}, _headers, resp}} =
      :httpc.request(
        :get,
        {~c"http://127.0.0.1:#{ctx.port}/no-such-plane", []},
        [],
        body_format: :binary
      )

    assert status == 404, "expected the main router's 404, got #{status}: #{inspect(resp)}"
    assert resp =~ "RouteNotFound", "expected the catch-all envelope, got: #{inspect(resp)}"
  end

end
