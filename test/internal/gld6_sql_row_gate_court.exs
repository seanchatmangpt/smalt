defmodule Smalt.Gld6SqlRowGateCourtTest do
  use ExUnit.Case, async: false

  # GLD-6 security court (v26.10.21): POST /sql-ingest — the SHACL gate
  # extended to the DATA itself. Base harness reuses the GLD-3 wire court — the SQL ingestion wire
  # face. Chicago discipline: real collaborators everywhere — the real
  # `Smalt.EgressRouter` served over a real Bandit TCP listener, real HTTP
  # POSTs via :httpc, real `Smalt.SqlIngest` COPY-block parse, real
  # `Smalt.Powl2.AndonWire` 422 envelope, real `Smalt.Ocel` envelope
  # validation. No mocks; assertions are on wire bytes (status, headers,
  # JSON body).
  #
  # Context: solo (internal tier, in-process Bandit + :httpc loopback).
  # No mocks: real Bandit TCP, real :httpc, real SqlIngest parse, real
  # SqlRowGate -> SqlShapeGen -> Validator gate, real AndonWire envelope.

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    port = free_port()

    start_supervised!(
      {Bandit, plug: Smalt.EgressRouter, scheme: :http, port: port}
    )

    wait_listening(port, 20)
    {:ok, base: ~c"http://127.0.0.1:#{port}/sql-ingest"}
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

  
  defp post(base, dump_text) do
    body =
      Jason.encode!(%{
        "format" => "postgres_dump",
        "mapping_iri" => "https://example.com/mapping/gld6-1",
        "data_b64" => Base.encode64(dump_text)
      })

    {:ok, {{_, status, _}, headers, resp}} =
      :httpc.request(
        :post,
        {base, [{'content-type', 'application/json'}], 'application/json', body},
        [],
        body_format: :binary
      )

    {status, headers, resp}
  end

  defp andon!(status, headers, resp, want_status) do
    assert status == want_status, "want #{want_status}, got #{status}: #{inspect(resp)}"

    err = Jason.decode!(resp)["error"]

    assert err["code"] == "GraphlawRefusal"
    assert err["rule_id"] in ["sql.shacl_row", "sql.injection_token", "sql.shape_generation"]
    assert is_binary(err["diagnostic"])
    assert is_binary(err["repair_hint"])
    assert is_binary(err["agent_message"])
    assert is_binary(err["session"])
    assert is_integer(err["ts"])
    assert err["context_digest"] =~ ~r/^[0-9a-f]{64}$/

    assert Enum.any?(headers, fn {k, v} ->
             k == ~c"x-ms-error-code" and v == ~c"BusinessLawViolation"
           end)

    err
  end

  # -- fixtures -----------------------------------------------------------------
  # DDL and COPY column lists are set-equal, so every table is governed.
  @ddl """
  CREATE TABLE public.events (
      id integer NOT NULL,
      name character varying(50) NOT NULL,
      qty bigint
  );
  """
  @copy_header "COPY public.events (id, name, qty) FROM stdin;\n"

  test "control: a lawful dump still 201s — the gate is not a vacuous always-refuse", ctx do
    dump = @ddl <> @copy_header <> "1\talpha\t5\n2\tbeta\t6\n\\.\n"
    {status, _headers, resp} = post(ctx.base, dump)
    assert status == 201, "control dump must project, got #{status}: #{inspect(resp)}"

    payload = Jason.decode!(resp)
    assert payload["status"] == "ingested"
    [t] = payload["tables"]
    assert t["name"] == "events"
    assert t["rowCount"] == 2

    # deep ledger check: the OCEL projection carries exactly the lawful rows
    assert payload["ocel"] == %{"eventCount" => 1, "objectCount" => 2}

    # and the gate agrees at module level
    {:ok, tables} = Smalt.SqlIngest.parse_dump(dump)
    assert Smalt.GraphLaw.SqlRowGate.check(dump, tables) == :ok
  end

  test "422: NULL in a NOT NULL column refuses naming the shape, column, row", ctx do
    dump = @ddl <> @copy_header <> "1\talpha\t5\n\\N\tbeta\t6\n\\.\n"
    {status, headers, resp} = post(ctx.base, dump)

    err = andon!(status, headers, resp, 422)

    assert err["rule_id"] == "sql.shacl_row"
    assert err["diagnostic"] =~ "row 2"
    assert err["diagnostic"] =~ "events"
    assert err["diagnostic"] =~ "SqlEventsShape"
    assert err["diagnostic"] =~ "minCount"
    assert err["diagnostic"] =~ "column id"
    assert err["repair_hint"] =~ "id"

    # deep ledger check: the refusal body carries NO projection — no tables,
    # no ocel envelope; nothing of the dump left the wire face.
    refute Map.has_key?(Jason.decode!(resp), "tables")
    refute Map.has_key?(Jason.decode!(resp), "ocel")

    # and at module level the gate refuses before any projection could run
    {:ok, tables} = Smalt.SqlIngest.parse_dump(dump)

    assert {:refusal, %{rule_id: "sql.shacl_row"}} =
             Smalt.GraphLaw.SqlRowGate.check(dump, tables)
  end

  test "422: string in an integer column refuses naming the datatype violation", ctx do
    dump = @ddl <> @copy_header <> "1\talpha\tnot-a-number\n\\.\n"
    {status, headers, resp} = post(ctx.base, dump)

    err = andon!(status, headers, resp, 422)

    assert err["rule_id"] == "sql.shacl_row"
    assert err["diagnostic"] =~ "datatype"
    assert err["diagnostic"] =~ "qty"
    assert err["diagnostic"] =~ "xsd:integer"

    # zero bad rows in the projected ledger: nothing projected at all
    refute Map.has_key?(Jason.decode!(resp), "tables")

    {:ok, tables} = Smalt.SqlIngest.parse_dump(dump)

    assert {:refusal, %{rule_id: "sql.shacl_row"}} =
             Smalt.GraphLaw.SqlRowGate.check(dump, tables)
  end

  test "422: a second statement smuggled after the COPY terminator is refused, never minted",
       ctx do
    # forged COPY header with an injection-token table name after the
    # legitimate terminator
    dump =
      @ddl <>
        @copy_header <>
        "1\talpha\t5\n\\.\n" <>
        "COPY evil; DROP TABLE public.events-- (a) FROM stdin;\n1\tboom\n\\.\n"

    {status, headers, resp} = post(ctx.base, dump)

    err = andon!(status, headers, resp, 422)

    assert err["rule_id"] == "sql.injection_token"
    assert err["diagnostic"] =~ "evil;"

    # the smuggled statement never minted a second table anywhere
    refute Map.has_key?(Jason.decode!(resp), "tables")

    # the parser itself fails CLOSED on the whole dump: the forged COPY
    # target aborts the parse (no partial ingestion of a poisoned dump)
    assert {:error, {:injection_token, "evil;"}} = Smalt.SqlIngest.parse_dump(dump)
  end

  test "row smuggling the terminator inside the data is contained or refused, never a 500",
       ctx do
    # the line "\. COPY ..." is NOT the terminator (suffix present), so it is
    # row DATA: a smuggled second statement disguised as a field of column id
    dump = @ddl <> @copy_header <> "\\. COPY evil FROM stdin; DROP TABLE public.events;\n\\.\n"

    {status, _headers, resp} = post(ctx.base, dump)

    assert status in [201, 422]
    refute status == 500

    cond do
      status == 422 ->
        err = Jason.decode!(resp)["error"]
        assert err["code"] == "GraphlawRefusal"
        # whatever fires, the refusal is typed and names a real law
        assert err["rule_id"] in ["sql.shacl_row", "sql.injection_token"]

      true ->
        payload = Jason.decode!(resp)
        [t] = payload["tables"]
        # the smuggled text must ride as inert data of the governed table,
        # never as a second projected statement/table
        assert t["name"] == "events"
        assert payload["ocel"]["objectCount"] == 2
    end
  end

  test "422: DDL with an unsupported column type refuses shape-generation, naming table.column",
       ctx do
    dump =
      "CREATE TABLE public.t2 (id integer, ratio double precision NOT NULL);\n" <>
        "COPY public.t2 (id, ratio) FROM stdin;\n1\t1.5\n\\.\n"

    {status, headers, resp} = post(ctx.base, dump)

    err = andon!(status, headers, resp, 422)

    assert err["rule_id"] == "sql.shape_generation"
    assert err["diagnostic"] =~ "ratio"
    assert err["diagnostic"] =~ "double"

    refute Map.has_key?(Jason.decode!(resp), "tables")
  end

  test "gate module-level: schema-less dump (COPY only) is ungoverned but never 500s", ctx do
    dump = "COPY events (k, v) FROM stdin;\na\t1\n\\.\n"
    {status, _headers, resp} = post(ctx.base, dump)

    assert status in [201, 422]
    refute status == 500

    if status == 201 do
      payload = Jason.decode!(resp)
      [t] = payload["tables"]
      assert t["name"] == "events"
    end
  end
end
