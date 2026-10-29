# Lane B-42: data-plane saturation pipeline — 10,000 requests over the
# canonical planes (BK-EPLAW: self-pins EPHEMERAL ports via
# scripts/lib/test_boot_ports.exs unless SMALT_TEST_*_PORT env pins a lane
# block explicitly). Wire-level HTTP (cosmos / blob block streaming / KV
# secrets) via :httpc against the substrate's egress listener (base/0 reads
# the pinned :egress_port); the AMQP leg rides
# the substrate's QueueStore (BEAM-tier; smalt ships no Elixir AMQP 1.0 client
# — disclosed; the AMQP wire tier is covered by the ts-servicebus SDK probes).
#
# 1,250 pipeline units x 8 ops = 10,000 requests, 50 concurrent workers
# (Task.async_stream, max_concurrency: 50). Per unit:
#   cosmos:  PUT doc + query feed POST (application/query+json, pk-scoped)   (2)
#   blob:    stage_block + commit_block_list + GET (block streaming)         (3)
#   kv:      PUT secret + GET secret                                         (2)
#   amqp:    enqueue (queue drained after the storm; dequeue+complete timed
#            as a separate batch row)                                       (1)
#
# Asserts: dropped connections == 0, read-your-write == 100%.
# Output:
#   docs/jira/v26.10.16/bench/b42-dataplane-saturation.jsonl  (lib.sh shape)
#   docs/jira/v26.10.16/sdk-results/dataplane-throughput.json (aggregate)

defmodule Bench.B42 do
  @lane "b42"
  defp base, do: "http://127.0.0.1:#{Application.get_env(:smalt, :egress_port)}"
  @db "b42db"
  @coll "b42coll"
  @acct "b42acct"
  @cont "b42cont"
  @units 1_250
  @workers 50
  @queue "b42-q"

  @jsonl "docs/jira/v26.10.16/bench/b42-dataplane-saturation.jsonl"
  @aggregate "docs/jira/v26.10.16/sdk-results/dataplane-throughput.json"

  def run do
    Code.require_file("test_boot_ports.exs", Path.join(File.cwd!(), "scripts/lib"))
    SmaltTestBoot.pin!()
    t0 = :erlang.monotonic_time(:millisecond)
    {:ok, _} = Application.ensure_all_started(:smalt)
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    init_tables()

    setup()
    warmup()

    parent = self()
    sampler = spawn(fn -> sampler_loop([], parent) end)

    results =
      Task.async_stream(1..@units, &unit/1,
        max_concurrency: @workers,
        timeout: 120_000,
        ordered: false
      )
      |> Enum.to_list()

    storm_ms = :erlang.monotonic_time(:millisecond) - t0
    dr = drain()

    send(sampler, :stop)

    samples =
      receive do
        {:samples, s} -> s
      after
        5_000 -> []
      end

    bad_units = Enum.count(results, &(&1 != {:ok, :ok}))
    emit_all(bad_units, storm_ms, dr, samples)

    if bad_units > 0 or dropped() > 0 or rww_violations() > 0 do
      System.stop(1)
    else
      System.stop(0)
    end
  end

  # -- ETS scratch (lane-private, names unique to this lane) --------------------

  defp init_tables do
    Enum.each([:b42_lat, :b42_err, :b42_cnt], fn t ->
      if :ets.info(t) != :undefined, do: :ets.delete(t)
      :ets.new(t, [:bag, :public, :named_table])
    end)
  end

  # Third element is a unique tiebreaker: ETS bags do NOT store exact
  # duplicate tuples, so identical {op, ms} pairs (fast ops, same quantized
  # latency) would silently collapse and skew n/percentiles.
  defp note_lat(op, ms),
    do: :ets.insert(:b42_lat, {op, ms, System.unique_integer([:monotonic, :positive])})

  defp note_fail(op), do: :ets.insert(:b42_err, {op, System.unique_integer()})

  defp op_failures(op) do
    :ets.select_count(:b42_err, [{{op, :_}, [], [true]}])
  end

  defp dropped, do: op_failures(:dropped)

  defp rww_violations, do: op_failures(:rww_violation)

  # -- setup -------------------------------------------------------------------

  defp setup do
    {s1, _} = req(:post, "#{base()}/dbs", [], ~c"application/json", Jason.encode!(%{"id" => @db}))

    {s2, _} =
      req(:post, "#{base()}/dbs/#{@db}/colls", [], ~c"application/json",
        Jason.encode!(%{"id" => @coll, "partitionKey" => %{"paths" => ["/pk"]}})
      )

    {s3, _} = req(:put, "#{base()}/#{@acct}/#{@cont}", [], ~c"application/json", "")
    q = Smalt.Amqp.QueueStore.ensure_queue(@queue)

    IO.puts("[b42] setup: db=#{s1} coll=#{s2} container=#{s3} queue=#{inspect(q)}")

    unless s1 in [200, 201] and s2 in [200, 201] and s3 in [200, 201] do
      IO.puts("[b42] FATAL setup failure")
      System.stop(1)
    end
  end

  defp warmup do
    {s, _} =
      req(:post, "#{base()}/dbs/#{@db}/colls/#{@coll}/docs",
        [{"x-ms-documentdb-partitionkey", ~s(["warm"])}],
        ~c"application/json",
        Jason.encode!(%{"id" => "warm-doc", "pk" => "warm", "v" => 0})
      )

    {sk, _} = req(:put, "#{base()}/secrets/b42-warm", [], ~c"application/json", Jason.encode!(%{"value" => "warm"}))
    IO.puts("[b42] warmup: cosmos=#{s} kv=#{sk}")
    Process.sleep(200)
  end

  # -- pipeline unit (one per worker task) ---------------------------------------

  defp unit(i) do
    ok? =
      cosmos_put(i) and cosmos_query(i) and blob_unit(i) and kv_unit(i) and amqp_enqueue(i)

    if ok?, do: :ok, else: :unit_failed
  end

  defp cosmos_put(i) do
    id = "doc-#{i}"
    body = Jason.encode!(%{"id" => id, "pk" => "p#{i}", "v" => i, "pad" => pad()})

    measure(:cosmos_put, fn ->
      {status, _} =
        req(:post, "#{base()}/dbs/#{@db}/colls/#{@coll}/docs",
          [{"x-ms-documentdb-partitionkey", ~s(["p#{i}"])}],
          ~c"application/json",
          body
        )

      status in [200, 201]
    end)
  end

  # Read-your-write via the query feed: pk-scoped scan (unique pk per unit)
  # must return exactly this unit's freshly written doc with its value.
  defp cosmos_query(i) do
    id = "doc-#{i}"

    measure(:cosmos_query, fn ->
      {status, body} =
        req(:post, "#{base()}/dbs/#{@db}/colls/#{@coll}/docs",
          [{"x-ms-documentdb-partitionkey", ~s(["p#{i}"])}],
          ~c"application/query+json",
          Jason.encode!(%{"query" => "SELECT * FROM c"})
        )

      cond do
        status != 200 ->
          false

        query_visible?(body, id, i) ->
          true

        true ->
          :ets.insert(:b42_err, {:rww_violation, {id, status}})
          false
      end
    end)
  end

  defp query_visible?(body, id, i) do
    case Jason.decode(body) do
      {:ok, %{"Documents" => docs}} ->
        Enum.any?(docs, fn d -> d["id"] == id and d["v"] == i end)

      _ ->
        false
    end
  end

  defp blob_unit(i) do
    name = "blob-#{i}"
    content = :binary.copy(<<"b", i::unsigned-integer-size(16)>>, 2048)
    block_id = Base.encode64("B1-#{i}")
    xml = "<BlockList><Latest>#{block_id}</Latest></BlockList>"

    ok_block =
      measure(:blob_stage_block, fn ->
        {status, _} =
          req(:put, "#{base()}/#{@acct}/#{@cont}/#{name}?comp=block&blockid=#{block_id}", [],
            ~c"application/octet-stream", content
          )

        status == 201
      end)

    ok_commit =
      measure(:blob_commit_block_list, fn ->
        {status, _} =
          req(:put, "#{base()}/#{@acct}/#{@cont}/#{name}?comp=blocklist", [],
            ~c"application/xml", xml
          )

        status == 201
      end)

    ok_get =
      measure(:blob_get, fn ->
        {status, body} = req(:get, "#{base()}/#{@acct}/#{@cont}/#{name}", [], "", "")
        status == 200 and body == content
      end)

    ok_block and ok_commit and ok_get
  end

  defp kv_unit(i) do
    name = "b42-sec-#{i}"
    value = "v#{i}-" <> pad()

    ok_put =
      measure(:kv_put, fn ->
        {status, _} = req(:put, "#{base()}/secrets/#{name}", [], ~c"application/json", Jason.encode!(%{"value" => value}))
        status in [200, 201]
      end)

    ok_get =
      measure(:kv_get, fn ->
        {status, body} = req(:get, "#{base()}/secrets/#{name}", [], "", "")

        case status == 200 && Jason.decode(body) do
          {:ok, %{"value" => ^value}} -> true
          _ -> false
        end
      end)

    ok_put and ok_get
  end

  defp amqp_enqueue(i) do
    measure(:amqp_enqueue, fn ->
      match?({:ok, _}, Smalt.Amqp.QueueStore.enqueue(@queue, "b42-msg-#{i}-" <> pad()))
    end)
  end

  # -- AMQP drain (dequeue+complete batch, timed apart) ---------------------------

  defp drain do
    t = :erlang.monotonic_time(:microsecond)
    {count, lats, bodies_ok} = drain_loop(0, [], 0)
    ms = (:erlang.monotonic_time(:microsecond) - t) / 1000
    %{count: count, ms: ms, lats: Enum.reverse(lats), bodies_ok: bodies_ok}
  end

  defp drain_loop(n, lats, bodies_ok) do
    t = :erlang.monotonic_time(:microsecond)

    case Smalt.Amqp.QueueStore.dequeue_matching(@queue) do
      {:ok, msg, _lock} ->
        lat = (:erlang.monotonic_time(:microsecond) - t) / 1000
        body = Map.get(msg, :body) || Map.get(msg, "body")
        body_ok = is_binary(body) and String.contains?(body, "b42-msg")
        :ok = Smalt.Amqp.QueueStore.complete(@queue, seq_of(msg))
        drain_loop(n + 1, [lat | lats], bodies_ok + if(body_ok, do: 1, else: 0))

      :empty ->
        {n, Enum.reverse(lats), bodies_ok}

      other ->
        IO.puts("[b42] drain unexpected: #{inspect(other)}")
        {n, Enum.reverse(lats), bodies_ok}
    end
  end

  defp seq_of(msg) do
    Map.get(msg, :sequence_number) || Map.get(msg, "sequence_number") ||
      Map.get(msg, :seq) || Map.get(msg, "seq")
  end

  # -- measurement -----------------------------------------------------------------

  defp measure(op, fun) do
    t = :erlang.monotonic_time(:microsecond)

    ok =
      try do
        fun.()
      rescue
        e ->
          IO.puts("[b42] op #{op} raised: #{Exception.format(:error, e)}")
          false
      end

    ms = (:erlang.monotonic_time(:microsecond) - t) / 1000
    note_lat(op, ms)
    :ets.insert(:b42_cnt, {op, 1})
    unless ok, do: note_fail(op)
    ok
  end

  defp pad, do: String.duplicate("x", 64)

  # -- Store GenServer mailbox sampler (ETS/lock contention proxy) ------------------
  # Smalt.Store puts are direct concurrent ETS writes; the only serialized
  # write path is the Store GenServer (CAS/next_seq). Contention ratio =
  # fraction of 20ms samples where the Store server mailbox is non-empty.

  defp sampler_loop(acc, parent) do
    len =
      case Process.whereis(Smalt.Store) do
        nil -> -1
        pid -> elem(Process.info(pid, :message_queue_len), 1)
      end

    receive do
      :stop ->
        send(parent, {:samples, Enum.reverse([len | acc])})
    after
      20 ->
        sampler_loop([len | acc], parent)
    end
  end

  # -- httpc request -----------------------------------------------------------------

  # Lane substrate runs auth_mode :anonymous (config/test.exs), but the KV
  # plane still challenges any request with NO Authorization header at all
  # (egress_router kv challenge) — send a bearer header on every request.
  @auth_hdr [
    {~c"authorization", ~c"Bearer b42-anonymous-lane"},
    {~c"x-ms-version", ~c"2021-12-02"}
  ]

  # body == "" -> GET-style 2-tuple; otherwise a 4-tuple with an explicit
  # per-request content-type (httpc appends the tuple's content-type as its
  # own header — a duplicate confuses content-type-dispatched routes such as
  # the Cosmos query feed, which dispatch on application/query+json).
  defp req(method, url, headers, ctype, body) do
    cl_headers = @auth_hdr ++ for {k, v} <- headers, do: {String.to_charlist(k), String.to_charlist(v)}

    http_req =
      if body == "" do
        {String.to_charlist(url), cl_headers}
      else
        {String.to_charlist(url), cl_headers, ctype, body}
      end

    opts = [timeout: 30_000, connect_timeout: 30_000, autoredirect: false]

    case :httpc.request(method, http_req, opts, [body_format: :binary]) do
      {:ok, {{_ver, status, _phrase}, _resp_headers, resp_body}} ->
        {status, resp_body}

      {:error, e} ->
        :ets.insert(:b42_err, {:dropped, inspect(e)})
        {-1, <<>>}
    end
  end

  # -- emission ---------------------------------------------------------------------

  defp emit_all(bad_units, storm_ms, dr, samples) do
    ops = [:cosmos_put, :cosmos_query, :blob_stage_block, :blob_commit_block_list, :blob_get, :kv_put, :kv_get, :amqp_enqueue]

    rows =
      for op <- ops do
        lats = lat_list(op)
        n = length(lats)
        {p50, p95, p99} = pcts(lats)
        ops_sec = if storm_ms > 0, do: n / (storm_ms / 1000), else: 0.0
        %{op: op, n: n, ops_per_sec: ops_sec, p50: p50, p95: p95, p99: p99, errors: op_failures(op)}
      end

    drain_lats = dr.lats
    {d50, d95, d99} = pcts(drain_lats)
    drain_ops_sec = if dr.ms > 0, do: dr.count / (dr.ms / 1000), else: 0.0

    # sampler samples: contention over nonzero samples (exclude pre-boot -1s)
    live = Enum.filter(samples, &(&1 >= 0))
    busy = Enum.count(live, &(&1 > 0))
    contention = if live == [], do: 0.0, else: busy / length(live)
    max_q = Enum.max([0 | live])

    machine = machine_spec()

    File.mkdir_p!(Path.dirname(@jsonl))
    File.mkdir_p!(Path.dirname(@aggregate))

    total_ops = Enum.sum(Enum.map(rows, & &1.n)) + dr.count * 2

    for r <- rows do
      rec = %{
        lane: @lane,
        surface: "dataplane",
        op: to_string(r.op),
        n: r.n,
        ops_per_sec: fl(r.ops_per_sec),
        p50_ms: fl(r.p50),
        p95_ms: fl(r.p95),
        p99_ms: fl(r.p99),
        errors: r.errors,
        machine: machine
      }

      line = Jason.encode!(rec)
      File.write!(@jsonl, line <> "\n", [:append])
      IO.puts("[b42] " <> line)
    end

    drain_rec = %{
      lane: @lane,
      surface: "dataplane",
      op: "amqp_dequeue_complete_batch",
      n: dr.count,
      ops_per_sec: fl(drain_ops_sec),
      p50_ms: fl(d50),
      p95_ms: fl(d95),
      p99_ms: fl(d99),
      errors: dr.count - dr.bodies_ok,
      machine: machine
    }

    drain_line = Jason.encode!(drain_rec)
    File.write!(@jsonl, drain_line <> "\n", [:append])
    IO.puts("[b42] " <> drain_line)

    aggregate = %{
      lane: @lane,
      surface: "dataplane-saturation",
      total_requests: total_ops,
      storm_ms: storm_ms,
      headline_iops: fl((total_ops) / (storm_ms / 1000)),
      families:
        Enum.map(rows, fn r ->
          %{
            op: to_string(r.op),
            n: r.n,
            ops_per_sec: fl(r.ops_per_sec),
            p50_ms: fl(r.p50),
            p99_ms: fl(r.p99),
            errors: r.errors
          }
        end) ++
          [
            %{
              op: "amqp_dequeue_complete_batch",
              n: dr.count,
              ops_per_sec: fl(drain_ops_sec),
              p50_ms: fl(d50),
              p99_ms: fl(d99),
              errors: dr.count - dr.bodies_ok
            }
          ],
      ets_lock_contention_ratio: fl(contention),
      ets_lock_max_queue: max_q,
      contention_metric:
        "fraction of 20ms samples where Smalt.Store GenServer mailbox non-empty (serialized CAS/next_seq path)",
      dropped_connections: dropped(),
      read_your_write_violations: rww_violations(),
      consistency_verdict: if(rww_violations() == 0, do: "PASS", else: "FAIL"),
      bad_units: bad_units,
      machine: machine
    }

    File.write!(@aggregate, Jason.encode!(aggregate, pretty: true) <> "\n")
    IO.puts("[b42] aggregate: " <> Jason.encode!(aggregate))
  end

  defp lat_list(op) do
    :ets.tab2list(:b42_lat)
    |> Enum.filter(fn {o, _, _} -> o == op end)
    |> Enum.map(fn {_, v, _} -> v end)
  end

  defp pcts(lats) do
    case Enum.sort(lats) do
      [] ->
        {0.0, 0.0, 0.0}

      v ->
        at = fn p -> Enum.fetch!(v, round(p / 100.0 * (length(v) - 1))) end
        {fl(at.(50)), fl(at.(95)), fl(at.(99))}
    end
  end

  defp fl(x), do: Float.round(x * 1.0, 3)

  defp machine_spec do
    {cpu, 0} = System.cmd("sysctl", ["-n", "machdep.cpu.brand_string"])
    cores = :erlang.system_info(:logical_processors_available)
    otp = :erlang.system_info(:otp_release) |> to_string()
    elixir = System.version()
    {darwin, 0} = System.cmd("sw_vers", ["-productVersion"])

    %{
      "cpu" => String.trim(cpu),
      "cores" => cores,
      "elixir" => elixir,
      "otp" => otp,
      "darwin" => String.trim(darwin)
    }
  end
end

Bench.B42.run()
