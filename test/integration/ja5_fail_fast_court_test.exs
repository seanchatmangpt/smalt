defmodule Smalt.Integration.Ja5FailFastCourt do
  # JA-5 — Joe Armstrong fail-fast court (OTP-29 lane, MIX_BUILD_ROOT=_build-ja5).
  #
  # Doctrine: invalid input crashes/refuses at the boundary with a typed error,
  # never propagates silently into the system. Four gates, all on REAL wire
  # faces (Bandit + Smalt.EgressRouter + raw :httpc HTTP, no test-adapter
  # conns, no mocks):
  #
  #   Gate 1: malformed JSON -> typed 400 at the boundary; deep-assert the
  #           data plane was never touched (:smalt_cosmos_docs has no row for
  #           the victim id, doc count unchanged).
  #   Gate 2: oversized payload -> typed 413 RequestBodyTooLarge (the
  #           ensure_put_blob_type / 8MB transport-cap guard); plus the
  #           CAS 412 PreconditionFailed guard on a wrong If-Match.
  #   Gate 3: atom-smuggling battery (the ARMSTRONG class): binaries crafted
  #           to provoke atom creation (paths, query params, header names,
  #           JSON keys/values, XML tags) -> :erlang.system_info(:atom_count)
  #           fence unchanged across the battery.
  #   Gate 4: a crash inside a Bandit handler -> the connection drops, the
  #           acceptor supervisor survives, the very next request on a fresh
  #           connection succeeds (worker disposable, system not).
  #
  # Chicago discipline: real collaborators only (real HTTP client, real
  # server, real ETS store); assertions on final state (statuses, store rows,
  # atom-count delta), never call counts.

  use ExUnit.Case, async: false

  @moduletag :integration

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:crypto)

    # Reserve OS-assigned ports, then bind Bandit to them (sj4 pattern).
    ports =
      for _ <- 1..2 do
        {:ok, sock} = :gen_tcp.listen(0, [])
        {:ok, port} = :inet.port(sock)
        :gen_tcp.close(sock)
        port
      end

    [main_port, crash_port] = ports

    {:ok, main_server} =
      Bandit.start_link(plug: Smalt.EgressRouter, scheme: :http, port: main_port)

    {:ok, crash_server} =
      Bandit.start_link(plug: Ja5CrashPlug, scheme: :http, port: crash_port)

    on_exit(fn ->
      for pid <- [main_server, crash_server], Process.alive?(pid) do
        GenServer.stop(pid, :normal)
      end
    end)

    %{
      port: main_port,
      crash_port: crash_port,
      crash_server: crash_server
    }
  end

  # ---------------------------------------------------------------------------
  # Gate 1 — malformed JSON: typed 400 at the boundary, no data-plane write
  # ---------------------------------------------------------------------------
  test "gate 1: malformed JSON answers typed 400 and never reaches the data plane", %{
    port: port
  } do
    db = "ja5db1"
    coll = "ja5c1"
    victim_id = "ja5-victim"
    key = "#{db}/#{coll}/#{victim_id}"

    # Clean-room precondition: the victim row must not pre-exist.
    assert :ets.lookup(:smalt_cosmos_docs, key) == [],
           "gate 1 REFUSED: victim row pre-exists in :smalt_cosmos_docs"

    before_rows =
      :ets.tab2list(:smalt_cosmos_docs)
      |> Enum.count(fn {k, _} -> is_binary(k) and String.starts_with?(k, "#{db}/#{coll}/") end)

    # (a) truncated JSON with an application/json content-type
    conn = raw_request(:post, port, "/dbs/#{db}/colls/#{coll}/docs", [{"content-type", "application/json"}], ~s({"id":"#{victim_id}","v":))

    assert conn.status == 400,
           "expected typed 400 for truncated JSON, got #{conn.status}: #{resp_body(conn)}"

    refute malformed_body_echo?(resp_body(conn)), "400 must be typed, not an echo/error page"

    # (b) syntactically valid JSON of the wrong shape (top-level scalar)
    conn2 =
      raw_request(:post, port, "/dbs/#{db}/colls/#{coll}/docs", [{"content-type", "application/json"}], "5")

    assert conn2.status == 400, "expected 400 for scalar JSON body, got #{conn2.status}"

    # (c) structurally-valid JSON whose id violates the Cosmos doc-id grammar
    conn3 =
      raw_request(:post, port, "/dbs/#{db}/colls/#{coll}/docs", [{"content-type", "application/json"}], ~s({"id":"a/b"}))

    assert conn3.status == 400, "expected 400 for invalid doc id grammar, got #{conn3.status}"

    # (d) malformed JSON on a second surface (Event Grid ingestion)
    conn4 =
      raw_request(:post, port, "/topics/ja5topic/events", [{"content-type", "application/json"}], ~s({"specversion":))

    assert conn4.status in [400, 415] and is_binary(error_code(resp_body(conn4))),
           "expected a typed refusal (400/415 envelope) for truncated CloudEvent JSON, got #{conn4.status}: #{resp_body(conn4)}"

    # Deep assert: the data plane was never touched.
    assert :ets.lookup(:smalt_cosmos_docs, key) == [],
           "FAIL-FAST VIOLATION: malformed JSON created an ETS row for #{key}"

    after_rows =
      :ets.tab2list(:smalt_cosmos_docs)
      |> Enum.count(fn {k, _} -> is_binary(k) and String.starts_with?(k, "#{db}/#{coll}/") end)

    assert after_rows == before_rows,
           "FAIL-FAST VIOLATION: container row count changed #{before_rows} -> #{after_rows}"
  end

  # ---------------------------------------------------------------------------
  # Gate 2 — oversized payload: typed 413; CAS 412 guard
  # ---------------------------------------------------------------------------
  test "gate 2: oversized blob payload answers typed 413 and wrong If-Match answers 412", %{
    port: port
  } do
    account = "ja5acct2"
    container = "ja5c2"

    conn =
      raw_request(:put, port, "/#{account}/#{container}?restype=container",
        [{"x-ms-version", "2023-11-03"}, {"content-length", "0"}], "")

    assert conn.status in [201, 409],
           "container create refused: #{conn.status}: #{resp_body(conn)}"

    # (a) 9 MB Put Blob body against the 8,000,000-byte transport cap ->
    # typed 413 RequestBodyTooLarge (ensure_put_blob_type / read_body guard).
    oversized = :binary.copy(<<0>>, 9_000_000)

    conn2 =
      raw_request(
        :put,
        port,
        "/#{account}/#{container}/toobig.bin",
        [{"x-ms-blob-type", "BlockBlob"}, {"x-ms-version", "2023-11-03"}],
        oversized
      )

    assert conn2.status == 413,
           "expected typed 413 RequestBodyTooLarge, got #{conn2.status}: #{resp_body(conn2)}"

    code2 = error_code(resp_body(conn2))

    assert code2 == "RequestBodyTooLarge" or resp_body(conn2) == "",
           "expected typed code RequestBodyTooLarge (or transport-close empty body), got #{inspect(code2)} body=#{inspect(resp_body(conn2))}"

    # Deep assert: the oversized blob was never admitted into the store.
    assert blob_not_stored?(account, container, "toobig.bin", port),
           "FAIL-FAST VIOLATION: oversized body was stored despite the 413"

    # (b) CAS guard: create a real blob, then PUT with a wrong If-Match ->
    # typed 412 PreconditionFailed, body untouched.
    conn3 =
      raw_request(:put, port, "/#{account}/#{container}/cas.bin",
        [{"x-ms-blob-type", "BlockBlob"}, {"x-ms-version", "2023-11-03"}],
        "v1"
      )

    assert conn3.status == 201, "baseline blob create refused: #{conn3.status}"

    conn4 =
      raw_request(:put, port, "/#{account}/#{container}/cas.bin",
        [{"x-ms-blob-type", "BlockBlob"}, {"x-ms-version", "2023-11-03"}, {"if-match", "\"wrong\""}],
        "v2"
      )

    assert conn4.status == 412,
           "expected typed 412 PreconditionFailed for wrong If-Match, got #{conn4.status}"

    assert error_code(resp_body(conn4)) == "PreconditionFailed",
           "expected typed code PreconditionFailed, got #{inspect(error_code(resp_body(conn4)))}"

    conn5 =
      raw_request(:get, port, "/#{account}/#{container}/cas.bin", [{"x-ms-version", "2023-11-03"}], nil)

    assert resp_body(conn5) == "v1", "CAS-refused PUT must leave the blob body untouched"
  end

  # ---------------------------------------------------------------------------
  # Gate 3 — atom-smuggling battery (the ARMSTRONG class)
  # ---------------------------------------------------------------------------
  test "gate 3: atom-smuggling battery mints zero new atoms", %{port: port} do
    # Warm-up so one-time framework initialization (inets profiles, telemetry
    # event names, Logger, first-touch route/module/ETS initialization on each
    # probe surface) happens BEFORE the fence baseline. Each probe CLASS below
    # has a representative in the warm-up, so the fence measures per-request
    # minting, not one-time lazy init.
    warmups = [
      {:get, "/ja5warmup/x/y", []},
      {:get, "/dbs/:atom_smuggle/colls/:fun/docs", []},
      {:get, "/topics/ja5topic/events", [{"content-type", "application/json"}]},
      {:put, "/ja5acct3/ja5c3/sbg.bin?comp=blocklist",
       [{"content-type", "application/xml"}, {"x-ms-version", "2023-11-03"}]}
    ]

    for {m, path, hs} <- warmups, i <- 1..5 do
      body = if m == :put, do: "<BlockList><Latest>w</Latest></BlockList>", else: nil
      hdrs = if m == :put, do: hs, else: []

      case raw_http(m, port, path, hdrs, body) do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end
    end

    baseline = :erlang.system_info(:atom_count)

    payloads = [
      # JSON keys/values that are also Erlang fun/atom names
      ~s({"apply":1,"spawn":2,"exit":3,"halt":4,"list_to_atom":"<atom>"}),
      ~s({"__struct__":"Elixir.NoSuchStruct","key\xff\xfe":"val😀"}),
      # path segments that look like atoms / module names / pseudo-protocol
      "/Elixir.NoSuchModule/:erlang.apply/`atom`",
      "/dbs/:atom_smuggle/colls/:fun/docs",
      "/ja5%2e%2e%2f%2e%2e/trailing?x=",
      # query parameter battery
      "/ja5acct3/c?atom=1&apply=2& :fun =3&undefined&nil&do end",
      # XML with atom-shaped tags (blob ACL / batch faces parse XML)
      ~s(<?xml version="1.0"?><BlockList><Latest>ja5-attempt-#{:erlang.unique_integer()}</Latest></BlockList>)
    ]

    classes = ["json-body", "json-weird-bytes", "path", "cosmos-path", "traversal-path", "query", "xml"]

    reqs =
      payloads
      |> Enum.zip(classes)
      |> Enum.flat_map(fn {payload, class} ->
        [
          {class <> "/get", fn -> raw_http(:get, port, payload, [{"x-ja5-probe", "ja5"}], nil) end},
          {class <> "/events", fn ->
             raw_http(:post, port, "/topics/ja5topic/events",
               [{"content-type", "application/json"}], payload)
           end},
          {class <> "/blocklist", fn ->
             raw_http(:put, port, "/ja5acct3/ja5c3/sbg.bin?comp=blocklist",
               [{"x-ms-version", "2023-11-03"}, {"content-type", "application/xml"}], payload)
           end}
        ]
      end)

    # Per-class bisect: which probe class (if any) mints atoms.
    deltas =
      Enum.map(reqs, fn {name, f} ->
        before = :erlang.system_info(:atom_count)

        case f.() do
          {:ok, _} -> :ok
          {:error, _} -> :ok
        end

        {name, :erlang.system_info(:atom_count) - before}
      end)

    offenders = for {name, d} <- deltas, d != 0, do: {name, d}

    total = :erlang.system_info(:atom_count) - baseline

    assert offenders == [] and total == 0,
           "ARMSTRONG CLASS VIOLATION: total=#{total}, offenders=#{inspect(offenders, limit: 20)}"
  end

  # ---------------------------------------------------------------------------
  # Gate 4 — handler crash: connection drops, supervisor survives, next
  # request succeeds
  # ---------------------------------------------------------------------------
  test "gate 4: Bandit handler crash drops the connection, system survives", %{
    crash_port: crash_port,
    crash_server: crash_server
  } do
    assert Process.alive?(crash_server)

    # 1) The crashing request does NOT produce a lying 2xx — it is answered
    #    with a connection-level failure (or, at worst, a 5xx).
    result = raw_http(:get, crash_port, "/ja5-crash", [], nil)

    crash_refused =
      case result do
        {:error, _reason} -> true
        {:ok, {{_v, status, _phrase}, _h, _b}} when status >= 500 -> true
        _ -> false
      end

    assert crash_refused,
           "crash request neither dropped the connection nor answered 5xx: #{inspect(result)}"

    # 2) The Bandit supervisor is still alive (worker disposable, system not).
    assert Process.alive?(crash_server), "Bandit supervisor died with its handler"

    # 3) The very next request, on a fresh connection, succeeds and is typed.
    conn =
      raw_request(:get, crash_port, "/ja5-after-crash/no/such/route",
        [{"x-ms-version", "2023-11-03"}], nil)

    assert conn.status == 404, "expected typed 404 after crash, got #{conn.status}"

    assert is_binary(error_code(resp_body(conn))),
           "expected a typed error body after crash, got #{inspect(resp_body(conn))}"

    # 4) The system still enforces the fail-fast boundary post-crash.
    conn2 =
      raw_request(:post, crash_port, "/dbs/ja5db4/colls/ja5c4/docs",
        [{"content-type", "application/json"}], ~s({"id":"x",))

    assert conn2.status == 400, "expected typed 400 after crash, got #{conn2.status}"

    assert :ets.lookup(:smalt_cosmos_docs, "ja5db4/ja5c4/x") == [],
           "FAIL-FAST VIOLATION: store row created after supervisor recovery"
  end

  # ---------------------------------------------------------------------------
  # Real collaborators
  # ---------------------------------------------------------------------------

  # Raw HTTP over the real socket. Returns {:ok, {{status_line, headers}, body}}
  # or {:error, reason}. A *typed* response is post-processed into a
  # %Plug.Conn{}-shaped map via typed/2 for status/code assertions.
  defp raw_http(method, port, path, headers, body) do
    url = :erlang.binary_to_list("http://127.0.0.1:#{port}#{path}")

    hdrs = Enum.map(headers, fn {k, v} -> {:erlang.binary_to_list(k), :erlang.binary_to_list(v)} end)

    request =
      if body in [nil, ""] do
        {url, hdrs}
      else
        {url, hdrs, ~c"application/octet-stream", body}
      end

    :httpc.request(method, request, [timeout: 30_000, connect_timeout: 10_000],
      body_format: :binary
    )
  end

  defp raw_request(method, port, path, headers, body) do
    {:ok, {{_http_ver, status, _reason}, _resp_headers, resp_body}} =
      raw_http(method, port, path, headers, body)

    %Plug.Conn{
      status: status,
      resp_headers: [],
      private: %{ja5_body: resp_body}
    }
  end

  defp resp_body(%Plug.Conn{private: %{ja5_body: body}}), do: body

  defp error_code(body) when is_binary(body) do
    cond do
      xml = xml_code(body) -> xml
      true ->
        case Smalt.JsonCompat.decode(body) do
          {:ok, %{"error" => %{"code" => code}}} -> code
          {:ok, %{"code" => code}} when is_binary(code) -> code
          _ -> nil
        end
    end
  end

  defp xml_code(body) when is_binary(body) do
    case Regex.run(~r/<Code>([^<]+)<\/Code>/, body) do
      [_, code] -> code
      _ -> nil
    end
  end

  defp malformed_body_echo?(body) when is_binary(body) do
    # A typed refusal must be a JSON envelope (or empty) — never an HTML error
    # page or an echo of the raw payload.
    cond do
      body == "" -> false
      String.contains?(body, "<html") -> true
      match?({:ok, %{"error" => %{"code" => _}}}, Smalt.JsonCompat.decode(body)) -> false
      match?({:ok, %{"code" => _}}, Smalt.JsonCompat.decode(body)) -> false
      true -> true
    end
  end

  defp blob_not_stored?(account, container, blob, port) do
    conn = raw_request(:get, port, "/#{account}/#{container}/#{blob}", [{"x-ms-version", "2023-11-03"}], nil)
    conn.status == 404
  end
end

# A real plug whose handler crashes on the sentinel path and delegates
# everything else to the REAL router — a hand-written real collaborator, not
# a mock (Chicago: the crash is genuine, the delegation is genuine).
defmodule Ja5CrashPlug do
  def init(opts), do: opts

  def call(%Plug.Conn{path_info: ["ja5-crash" | _]} = _conn, _opts) do
    raise RuntimeError, "JA-5 court: deliberate handler crash"
  end

  def call(conn, opts), do: Smalt.EgressRouter.call(conn, opts)
end
