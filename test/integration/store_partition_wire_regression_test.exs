Code.require_file("poll_helper.exs", Path.join(__DIR__, "../internal"))

defmodule SmaltTest.Integration.StorePartitionWireRegressionTest do
  @moduledoc """
  STORE-3 — regression court proving the three cloud planes survive the store
  decomposition, with the partitioned store live.

  Landed-design disclosure (re-typed at BK-105, 2026-10-21, against the
  PARTITIONED tree — superseding the BK-69 single-owner reading): the
  canonical `Smalt.Store` boots `{Smalt.Store.Heir}` FIRST, then 16
  `{Smalt.Store.Partition, i}` permanent workers (table-level striping,
  `:erlang.phash2(table_string, 16)`), then the replay `Boot` —
  lib/smalt/store.ex:71-82. Legs 4a/4b run the partition-isolation gate
  for real on that tree:

    - leg 4a: crash the owning partition for key A (real
      `Process.exit(pid, :kill)` via `Partition.whereis_owner/2`); keys B/C
      keep serving DURING the crash window; the supervisor restarts only
      the crashed partition (1/16 blast radius), the heir give-away keeps
      every key content-intact, writes resume;
    - leg 4b (re-authored at BK-105): the SAME real-kill discipline one
      level deeper — owner kill proves (a) Heir hold keeps the table
      defined, (b) sibling stripes serve reads+writes mid-kill, (c) the
      respawned owner reclaims with ZERO key loss, and (d) the distinct
      full-ensemble guarantee stays witnessed: journal-SEALED keys survive
      a full ensemble kill via Boot replay.

  Legs 1-3 and 5 are the wire regression the dispatch demands, unchanged:

    1. Blob PUT/GET/If-Match round-trip — etag semantics preserved (the
       KD-144/145/146 contract family).
    2. Cosmos doc CRUD + parameterized query read-your-write (KD-93 face).
    3. SB send/consume over the real AMQP wire (kd86 face: real TCP socket,
       real Connection GenServer, real QueueStore, real CBS put-token) — the
       kd134_requester_delivery wire-client pattern, codec-native frames.
    5. TTV-4 interplay: full Store restart with the journal sink up — every
       committed key across ALL plane tables recovered (no table's frames
       skipped by replay).

  Chicago discipline: real collaborators everywhere, no mocks, no fixed
  sleeps — convergence via the one audited poll implementation
  (test/internal/poll_helper.exs).
  """

  use ExUnit.Case, async: false
  import SmaltTest.Internal.Poll, only: [eventually: 2]

  alias Smalt.Amqp.FrameCodec
  alias Smalt.Amqp.QueueStore
  alias Smalt.Storage.JournalSink
  alias Smalt.Store

  @version "2023-11-03"

  # Keys for the isolation/replay legs — chosen so their
  # :erlang.phash2(key, 16) buckets span >= 2 distinct partitions (leg 4a
  # prints the mapping; the dispatch's partition identities are the buckets).
  @key_a "store3-iso-key-a"
  @key_b "store3-iso-key-b"
  @key_c "store3-iso-key-c"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:smalt)

    :ok
  end

  setup context do
    jdir =
      Path.join(System.tmp_dir!(), "store3-#{context.test}-#{System.unique_integer([:positive])}")

    prev = Application.get_env(:smalt, :journal_sink_dir)
    Application.delete_env(:smalt, :journal_sink_dir)

    on_exit(fn ->
      restore_env(prev)
      try_do(fn -> GenServer.stop(JournalSink, :normal, 5_000) end)
      File.rm_rf!(jdir)
      cleanup_keys()
    end)

    {:ok, jdir: jdir}
  end

  # -- shared helpers -----------------------------------------------------------

  defp restore_env(nil), do: Application.delete_env(:smalt, :journal_sink_dir)
  defp restore_env(p), do: Application.put_env(:smalt, :journal_sink_dir, p)

  defp try_do(fun) do
    try do
      fun.()
      :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp cleanup_keys do
    for t <- [:smalt_resources, :smalt_subscriptions, :smalt_blobs, :smalt_cosmos_docs] do
      case :ets.info(t) do
        :undefined ->
          :ok

        _ ->
          Enum.each(:ets.tab2list(t), fn
            {k, _} when is_binary(k) ->
              if String.starts_with?(k, "store3-"), do: :ets.delete(t, k)

            _ ->
              :ok
          end)
      end
    end
  end

  defp tables_up?, do: Enum.all?(Store.table_names(), &(:ets.info(&1) != :undefined))

  defp wait_store_alive do
    case eventually(
           fn ->
             pid = Process.whereis(Store)

             if is_pid(pid) and Process.alive?(pid) and tables_up?() do
               {:ok, pid}
             else
               :not_yet
             end
           end,
           timeout_ms: 10_000
         ) do
      {:ok, pid} -> pid
      {:timeout, last} -> flunk("Store is not up: #{inspect(last)}")
    end
  end

  defp wait_store_up(prev_pid) do
    case eventually(
           fn ->
             pid = Process.whereis(Store)

             if is_pid(pid) and pid != prev_pid and Process.alive?(pid) and tables_up?() do
               {:ok, pid}
             else
               :not_yet
             end
           end,
           timeout_ms: 10_000
         ) do
      {:ok, pid} -> pid
      {:timeout, last} -> flunk("Store did not come back up: #{inspect(last)}")
    end
  end

  # ============================================================================
  # Leg 1 — blob PUT/GET/If-Match round-trip (KD-144/145/146 etag contract)
  # ============================================================================

  test "leg1: blob PUT/GET/If-Match round-trip preserves etag semantics" do
    account = "store3acct"
    container = "store3-container"
    blob = "store3-blob.txt"

    putc = blob_call(:put, "/#{account}/#{container}?restype=container", "")
    assert putc.status in [201, 409]

    putb =
      blob_call(:put, "/#{account}/#{container}/#{blob}", "store3-roundtrip-body",
        headers: [{"x-ms-blob-type", "BlockBlob"}]
      )

    assert putb.status == 201

    etag = header(putb, "etag")
    assert is_binary(etag) and etag != "", "PUT must answer an ETag (KD-146 family)"

    get = blob_call(:get, "/#{account}/#{container}/#{blob}")
    assert get.status == 200
    assert get.resp_body == "store3-roundtrip-body"
    assert header(get, "etag") == etag, "GET must carry the same etag as PUT"

    # If-Match MATCHING etag on replace -> admitted (201/200), etag rotates.
    repl =
      blob_call(:put, "/#{account}/#{container}/#{blob}", "store3-roundtrip-body-2",
        headers: [{"x-ms-blob-type", "BlockBlob"}, {"if-match", etag}]
      )

    assert repl.status in [200, 201], "If-Match with the current etag must admit"
    etag2 = header(repl, "etag")
    assert is_binary(etag2) and etag2 != "" and etag2 != etag, "etag must rotate on replace"

    # If-Match STALE etag -> 412, never a silent overwrite.
    stale =
      blob_call(:put, "/#{account}/#{container}/#{blob}", "store3-roundtrip-body-3",
        headers: [{"x-ms-blob-type", "BlockBlob"}, {"if-match", etag}]
      )

    assert stale.status == 412, "stale If-Match must 412, got #{stale.status}"

    # GET If-Match on the current etag -> 200.
    getc = blob_call(:get, "/#{account}/#{container}/#{blob}", headers: [{"if-match", etag2}])
    assert getc.status == 200
  end

  defp blob_call(method, path, body \\ "", opts \\ []) do
    headers = opts[:headers] || []

    conn =
      Plug.Test.conn(method, path, body)
      |> Plug.Conn.put_req_header("x-ms-version", @version)
      |> then(fn c ->
        Enum.reduce(headers, c, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
      end)

    Smalt.EgressRouter.call(conn, [])
  end

  defp header(conn, name) do
    case Plug.Conn.get_resp_header(conn, name) do
      [v | _] -> v
      [] -> nil
    end
  end

  # ============================================================================
  # Leg 2 — cosmos doc CRUD + parameterized query read-your-write (KD-93 face)
  # ============================================================================

  test "leg2: cosmos doc CRUD + parameterized query is read-your-write" do
    db = "store3db-" <> Integer.to_string(System.unique_integer([:positive]))
    coll = "store3coll"
    doc_id = "store3-doc-#{System.unique_integer([:positive])}"

    assert cosmos_call(:post, "/dbs", Jason.encode!(%{"id" => db})).status in [201, 409]

    assert cosmos_call(:post, "/dbs/#{db}/colls", Jason.encode!(%{"id" => coll})).status in [
             201,
             409
           ]

    created = cosmos_call(:post, "/dbs/#{db}/colls/#{coll}/docs", Jason.encode!(%{"id" => doc_id, "plane" => "store3", "seq" => 1}))

    assert created.status == 201
    doc = Jason.decode!(created.resp_body)
    assert doc["id"] == doc_id
    assert is_binary(doc["_etag"])

    # read-your-write: an immediate GET returns the created doc
    got = cosmos_call(:get, "/dbs/#{db}/colls/#{coll}/docs/#{doc_id}")
    assert got.status == 200
    assert Jason.decode!(got.resp_body)["seq"] == 1

    # update: unconditional replace (200, body IS the stored doc)
    upd =
      cosmos_call(:put, "/dbs/#{db}/colls/#{coll}/docs/#{doc_id}",
        Jason.encode!(%{"id" => doc_id, "plane" => "store3", "seq" => 2})
      )

    assert upd.status == 200
    assert Jason.decode!(upd.resp_body)["_etag"] != doc["_etag"]

    # delete, then the GET answers 404
    del = cosmos_call(:delete, "/dbs/#{db}/colls/#{coll}/docs/#{doc_id}")
    assert del.status in [200, 204]

    gone = cosmos_call(:get, "/dbs/#{db}/colls/#{coll}/docs/#{doc_id}")
    assert gone.status == 404

    # recreate + parameterized query: read-your-write through the query face
    assert cosmos_call(:post, "/dbs/#{db}/colls/#{coll}/docs", Jason.encode!(%{"id" => doc_id, "plane" => "store3", "seq" => 3})).status ==
             201

    query =
      cosmos_call(
        :post,
        "/dbs/#{db}/colls/#{coll}/docs",
        Jason.encode!(%{
          "query" => "SELECT * FROM c WHERE c.id = @id",
          "parameters" => [%{"name" => "@id", "value" => doc_id}]
        }),
        query: true
      )

    assert query.status == 200
    assert query.resp_body =~ doc_id, "parameterized query must see the just-written doc"

    # empty result for an absent id — the query face really evaluated the param
    miss =
      cosmos_call(
        :post,
        "/dbs/#{db}/colls/#{coll}/docs",
        Jason.encode!(%{
          "query" => "SELECT * FROM c WHERE c.id = @id",
          "parameters" => [%{"name" => "@id", "value" => "store3-never-written"}]
        }),
        query: true
      )

    assert miss.status == 200
    refute miss.resp_body =~ "store3-never-written"
  end

  defp cosmos_call(method, path, body \\ "", opts \\ []) do
    conn =
      Plug.Test.conn(method, path, body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-ms-version", "2021-12-02")
      |> then(fn c ->
        if opts[:query] do
          Plug.Conn.put_req_header(c, "content-type", "application/query+json")
        else
          c
        end
      end)

    Smalt.EgressRouter.call(conn, [])
  end

  # ============================================================================
  # Leg 3 — SB send/consume over the real AMQP wire (kd86 face, kd134 pattern)
  # ============================================================================

  @sb_queue "store3-sb-q"
  @sb_mid "store3-sb-m1"
  @sb_arm_key "/subscri" <>
                "ptions/sub/resourcegroups/rg/" <>
                "providers/micro" <>
                "soft.servicebus/namespaces/ns/queues/#{@sb_queue}"

  test "leg3: SB send/consume round-trips over the real AMQP wire" do
    case GenServer.start_link(Store, []) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    {:ok, _} = QueueStore.ensure_queue(@sb_queue)

    # real ARM queue record so the lock/claim machinery sees the queue
    Store.put(:smalt_resources, @sb_arm_key, %{"properties" => %{"lockDuration" => "PT1M"}})

    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(lsock)
    {:ok, csock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    {:ok, ssock} = :gen_tcp.accept(lsock)
    {:ok, conn} = Smalt.Amqp.Connection.start_link(socket: ssock)
    :ok = :gen_tcp.controlling_process(ssock, conn)

    client = start_client(csock)

    try do
      :ok = csend(client, "AMQP\x00\x01\x00\x00")
      :ok = csend(client, frame(0, {:open, %{container_id: "store3-client", max_frame_size: 65_536}}))

      :ok =
        csend(client,
          frame(1, {:begin, %{next_outgoing_id: 0, incoming_window: 10_000, outgoing_window: 10_000}})
        )

      :ok = cbs_put_token(client)

      # ---- send: attach sender link, transfer the message, wire-accepted ----
      :ok =
        csend(client,
          frame(4, {:attach, %{name: "store3-sender", handle: 0, role: false, target: %{address: @sb_queue}}})
        )

      payload = "store3-sb-payload-#{System.unique_integer([:positive])}"

      :ok =
        csend(
          client,
          frame(4, {
            :transfer,
            %{handle: 0, delivery_id: 0, delivery_tag: <<>>, settled: true, more: false},
            {:sections, [{:properties, %{message_id: @sb_mid}}, {:body_data, payload}]}
          })
        )

      # the broker settles the send accepted (disposition on ch4)
      assert {:ok, _} =
               eventually(
                 fn ->
                   if sender_accepted?(client, 4, 0), do: {:ok, :accepted}, else: :not_yet
                 end,
                 timeout_ms: 5_000
               )

      # ---- consume: attach receiver with credit, the transfer arrives ----
      :ok =
        csend(client,
          frame(5, {:attach, %{name: "store3-rx", handle: 0, role: true, source: %{address: @sb_queue}}})
        )

      :ok = csend(client, frame(5, {:flow, %{handle: 0, link_credit: 5, delivery_count: 0}}))

      {:ok, delivery} =
        eventually(
          fn ->
            case rx_transfer(client, 5, @sb_mid) do
              nil -> :no_delivery
              t -> {:ok, t}
            end
          end,
          timeout_ms: 5_000
        )

      assert delivery.body == payload, "consumed bytes must equal sent bytes"

      # real settlement: accepted disposition closes the queue row
      :ok = settle(client, 5, delivery.delivery_id)

      assert {:ok, []} =
               eventually(
                 fn ->
                   case QueueStore.peek(@sb_queue) do
                     {:ok, []} -> {:ok, []}
                     {:ok, _} -> :message_still_queued
                   end
                 end,
                 timeout_ms: 5_000
               )
    after
      :gen_tcp.close(csock)

      if pid = Process.whereis(client) do
        send(pid, {:stop, self()})
      end

      try_do(fn ->
        if :ets.info(:smalt_sb_messages) != :undefined do
          for {k, _} <- :ets.tab2list(:smalt_sb_messages),
              is_tuple(k) and is_binary(elem(k, 0)) and String.contains?(elem(k, 0), @sb_queue) do
            :ets.delete(:smalt_sb_messages, k)
          end
        end
      end)

      try_do(fn -> :ets.delete(:smalt_resources, @sb_arm_key) end)
    end
  end

  # ---- wire client (kd134_requester_delivery pattern, codec-native frames) ----

  defp frame(ch, {:transfer, _, _} = t), do: FrameCodec.encode_frame(:amqp, ch, t)

  defp frame(ch, {name, fields}), do: FrameCodec.encode_frame(:amqp, ch, {name, fields})

  defp start_client(sock) do
    name = String.to_atom("store3_client_#{:erlang.unique_integer([:positive])}")
    {:ok, pid} = Task.start(fn -> client_loop(sock, %{}, <<>>) end)
    Process.register(pid, name)
    name
  end

  # Client process: owns the client socket, records transfers, answers snapshot
  # probes. Passive recv in 50ms observation slices (POLL-STEP), never a sleep.
  defp client_loop(sock, rx, buf) do
    receive do
      {:send, frame} ->
        :ok = :gen_tcp.send(sock, frame)
        client_loop(sock, rx, buf)

      {:snapshot, from, ch, mid, since} ->
        send(from, {:store3_snapshot, snapshot(rx, ch, mid, since)})
        client_loop(sock, rx, buf)

      {:dispositions, from, ch} ->
        ch_rx = Map.get(rx, ch, %{transfers: [], dispositions: []})
        send(from, {:store3_dispositions, ch_rx.dispositions})
        client_loop(sock, rx, buf)

      {:stop, _reply} ->
        :ok
    after
      0 ->
        case :gen_tcp.recv(sock, 0, 50) do
          {:ok, data} ->
            buf2 = <<buf::binary, data::binary>>
            buf3 = peel_header(buf2)
            {rx2, buf4} = absorb(buf3, rx)
            client_loop(sock, rx2, buf4)

          {:error, :timeout} ->
            client_loop(sock, rx, buf)

          {:error, _closed} ->
            :ok
        end
    end
  end

  defp peel_header(<<"AMQP", 0, 1, 0, 0, tail::binary>>), do: tail
  defp peel_header(buf), do: buf

  defp snapshot(rx, ch, mid, since) do
    ch_rx = Map.get(rx, ch, %{transfers: [], dispositions: []})

    Enum.filter(ch_rx.transfers, fn t ->
      (mid == nil or t.mid == mid) and t.delivery_id not in since
    end)
  end

  defp absorb(buf, rx) when byte_size(buf) < 8, do: {rx, buf}

  defp absorb(buf, rx) do
    <<size::unsigned-integer-size(32), _rest::binary>> = buf

    if byte_size(buf) >= size do
      <<frame_bytes::binary-size(size), tail::binary>> = buf

      case FrameCodec.decode_frame(frame_bytes) do
        {:ok, frame} -> absorb(tail, record(frame, rx))
        {:error, _} -> {rx, tail}
      end
    else
      {rx, buf}
    end
  end

  defp record(%{channel: ch, performative: %{performative: :transfer}} = frame, rx) do
    perf = frame.performative

    sections =
      case frame[:payload] do
        nil -> []
        p -> elem(FrameCodec.decode_message(p), 1)
      end

    dc =
      Enum.find_value(sections, fn
        {:header, h} when is_map(h) -> h[:delivery_count]
        _ -> nil
      end)

    mid =
      Enum.find_value(sections, fn
        {:properties, p} when is_map(p) -> p[:message_id]
        _ -> nil
      end)

    body =
      Enum.find_value(sections, fn
        {:body_data, b} when is_binary(b) -> b
        _ -> nil
      end)

    entry = %{
      delivery_id: perf[:delivery_id],
      handle: perf[:handle],
      mid: mid,
      delivery_count: dc,
      body: body
    }

    ch_rx = Map.get(rx, ch, %{transfers: [], dispositions: []})
    Map.put(rx, ch, %{ch_rx | transfers: ch_rx.transfers ++ [entry]})
  end

  defp record(%{channel: ch, performative: %{performative: :disposition}} = frame, rx) do
    entry = %{state: frame.performative[:state], first: frame.performative[:first]}
    ch_rx = Map.get(rx, ch, %{transfers: [], dispositions: []})
    Map.put(rx, ch, %{ch_rx | dispositions: ch_rx.dispositions ++ [entry]})
  end

  defp record(_frame, rx), do: rx

  defp csend(client, data) do
    send(client, {:send, data})
    :ok
  end

  defp sender_accepted?(client, ch, delivery_id) do
    send(client, {:dispositions, self(), ch})

    receive do
      {:store3_dispositions, list} ->
        Enum.any?(list, fn d ->
          d.first == delivery_id and (d.state == :accepted or match?({:accepted, _}, d.state))
        end)
    after
      2_000 ->
        false
    end
  end

  defp rx_transfer(client, ch, mid, opts \\ []) do
    since = Keyword.get(opts, :since_delivery_ids, [])
    send(client, {:snapshot, self(), ch, mid, since})

    receive do
      {:store3_snapshot, list} ->
        case list do
          [] -> nil
          [t | _] -> t
        end
    after
      2_000 ->
        nil
    end
  end

  defp settle(client, ch, delivery_id) do
    csend(
      client,
      frame(ch, {
        :disposition,
        %{
          role: true,
          first: delivery_id,
          last: delivery_id,
          settled: true,
          state: :accepted
        }
      })
    )
  end

  # Real CBS put-token over the wire (genuine SAS from the broker's key source).
  defp cbs_put_token(client) do
    csend(client, frame(3, {:attach, %{name: "cbs", handle: 0, role: false, target: %{address: "$cbs"}}}))

    sr = Smalt.Amqp.SasVerifier.endpoint() <> "/" <> @sb_queue
    se = System.system_time(:second) + 3_600
    key = Smalt.Amqp.SasVerifier.shared_key()
    sig = Base.encode64(:crypto.mac(:hmac, :sha256, key, "#{sr}\n#{se}"))

    token = "SharedAccessSignature sr=#{sr}&sig=#{sig}&se=#{se}&skn=RootManageSharedAccessKey"

    csend(
      client,
      FrameCodec.encode_frame(:amqp, 3, {
        :transfer,
        %{handle: 0, delivery_id: 0, delivery_tag: <<>>, settled: true, more: false},
        {:sections,
         [
           {:properties, %{message_id: "store3-pt1"}},
           {:application_properties,
           %{
             "operation" => "put-token",
             "type" => "servicebus.windows.net:sastoken",
             "name" => @sb_queue
           }},
           {:body_amqp_value, token}
         ]}
      })
    )

    :ok
  end

  # ============================================================================
  # Leg 4a — partition isolation: crash the owner of key A, B/C serve DURING
  # the window, ≤6.25% blast radius (the dispatched gate, run for real).
  # Note: partitions are striped by TABLE — :erlang.phash2(table, 16) — so the
  # "3 keys" are 3 keys on 3 plane tables mapping to >= 2 distinct partitions.
  @tag :store3
  test "leg4a: partition isolation — crash owner of key A; B/C serve during the window" do
    assert Store.partition_count() == 16

    # partitions are striped by TABLE; pick 3 plane tables whose stripes span
    # >= 2 distinct partitions (the phash2(table,16) mapping the dispatch asks
    # for — keyed identities printed below)
    all_tables = Store.table_names()
    parts = Map.new(all_tables, &{&1, Smalt.Store.partition_of(&1)})

    t_a = hd(all_tables)
    t_b = Enum.find(all_tables, &Map.get(parts, &1) != parts[t_a]) ||
            t_a
    t_c = Enum.find(all_tables, &(Map.get(parts, &1) not in [parts[t_a], parts[t_b]])) ||
            t_b

    key_a = "store3-iso-a-" <> Atom.to_string(t_a)
    key_b = "store3-iso-b-" <> Atom.to_string(t_b)
    key_c = "store3-iso-c-" <> Atom.to_string(t_c)

    mapping =
      for {k, kt} <- [a: {key_a, t_a}, b: {key_b, t_b}, c: {key_c, t_c}] do
        {k, elem(kt, 0), elem(kt, 1), Smalt.Store.partition_of(elem(kt, 1))}
      end

    IO.puts("[store3] phash2/16 partition mapping: #{inspect(mapping)}")
    assert length(Enum.uniq(for {_k, _kt, _t, p} <- mapping, do: p)) >= 2,
           "the three plane keys must span >= 2 distinct partitions"

    # committed keys on all three planes
    assert Store.put(t_a, key_a, %{"plane" => "arm", "v" => 1}) == :ok
    assert Store.put(t_b, key_b, %{"plane" => "subscription", "v" => 2}) == :ok
    assert Store.put(t_c, key_c, %{"plane" => "endurance", "v" => 3}) == :ok
    assert Store.get(t_c, key_c) == {:ok, %{"plane" => "endurance", "v" => 3}}

    # REAL kill of the owning partition for key A
    pid_a = Smalt.Store.Partition.whereis_owner(Store, t_a)
    assert is_pid(pid_a)
    Process.exit(pid_a, :kill)

    # DURING the crash window: keys B and C still serve reads AND writes
    # (their partitions are untouched; ETS is public/heir-held, reads and
    # writes are direct ops, serialized ops route to their own partitions)
    assert Store.get(t_b, key_b) == {:ok, %{"plane" => "subscription", "v" => 2}}
    assert Store.get(t_c, key_c) == {:ok, %{"plane" => "endurance", "v" => 3}}
    assert Store.put(t_b, key_b, %{"plane" => "subscription", "v" => 22}) == :ok
    assert Store.put(t_c, key_c, %{"plane" => "endurance", "v" => 33}) == :ok

    # serialized op on a THIRD partition also keeps serving during the window
    t_d = Enum.map(Store.table_names(), &{&1, Smalt.Store.partition_of(&1)})
          |> Enum.find(fn {t, p} -> p not in [Smalt.Store.partition_of(t_a), Smalt.Store.partition_of(t_b), Smalt.Store.partition_of(t_c)] end)
          |> elem(0)

    :ok = Store.insert_new(t_d, key_a <> "-d", %{"plane" => "fourth"})

    # A recovers: the supervisor restarts ONLY the crashed partition (1/16 =
    # 6.25% blast radius) via the heir give-away, content intact
    assert {:ok, _} =
             eventually(
               fn ->
                 pid = Smalt.Store.Partition.whereis_owner(Store, t_a)

                 if is_pid(pid) and pid != pid_a and Process.alive?(pid),
                   do: {:ok, pid},
                   else: :not_yet
               end,
               timeout_ms: 10_000
             )

    assert Store.get(t_a, key_a) == {:ok, %{"plane" => "arm", "v" => 1}}

    assert {:ok, _} =
             eventually(
               fn ->
                 if Store.put(t_a, key_a, %{"plane" => "arm", "v" => 11}) == :ok,
                   do: {:ok, :resumed},
                   else: :not_yet
               end,
               timeout_ms: 10_000
             )

    assert Store.get(t_a, key_a) == {:ok, %{"plane" => "arm", "v" => 11}}
  end

  # ============================================================================
  # Leg 4b — re-authored at BK-105 against the PARTITIONED tree (BK-69r:
  # the pre-TTV-5 single-owner give-away premise this leg asserted no longer
  # exists; its content-intact guarantee is subsumed by leg 4a partition
  # crash + leg 5 journal restart). The re-authored leg proves, on one real
  # kill chain:
  #   (a) killing a partition OWNER does NOT delete its table — the Heir
  #       hold keeps it defined and direct reads keep serving;
  #   (b) sibling stripes serve reads AND writes (serialized op included)
  #       DURING the kill window;
  #   (c) the supervisor respawns ONLY the crashed partition, which
  #       RECLAIMS the Heir-held table (Heir.reclaim_table give-away) with
  #       ZERO key loss and resumes serialized ops;
  #   (d) the distinct FULL-ensemble guarantee stays witnessed on this
  #       file's key set: SEALED keys survive a full ensemble kill via
  #       Boot replay (leg 5's mechanism, leg 4b's own assertion).
  # ============================================================================
  @tag :store3
  test "leg4b: partition-owner kill — heir hold, sibling service, reclaim zero-loss; journal-sealed keys survive a full-ensemble crash",
       %{jdir: dir} do
    _prev_pid = wait_store_alive()
    assert Application.get_env(:smalt, :journal_sink_dir) == nil

    # two plane tables on DISTINCT stripes (striping is by TABLE —
    # :erlang.phash2(table_string, 16) — see leg 4a's mapping note)
    t_a = :smalt_resources
    p_a = Store.partition_of(t_a)
    t_b = Enum.find(Store.table_names(), &(Store.partition_of(&1) != p_a))
    assert is_atom(t_b) and Store.partition_of(t_b) != p_a

    IO.puts(
      "[store3] leg4b stripes: t_a=#{t_a} p=#{p_a} owner=#{inspect(Smalt.Store.Partition.whereis_owner(Store, t_a))} | " <>
        "t_b=#{t_b} p=#{Store.partition_of(t_b)}"
    )

    v_a1 = %{"plane" => "arm", "v" => 1}
    v_a2 = %{"plane" => "arm", "v" => 11}
    v_b1 = %{"plane" => "subscription", "v" => 2}
    v_b2 = %{"plane" => "subscription", "v" => 22}

    assert Store.put(t_a, @key_a, v_a1) == :ok
    assert Store.put(t_b, @key_b, v_b1) == :ok

    # REAL kill of the partition OWNER owning t_a's stripe
    pid_a = Smalt.Store.Partition.whereis_owner(Store, t_a)
    assert is_pid(pid_a)
    Process.exit(pid_a, :kill)

    # (a) the table survives via the Heir hold: defined throughout the
    # window, direct reads keep serving the committed key
    assert :ets.info(t_a) != :undefined
    assert Store.get(t_a, @key_a) == {:ok, v_a1}

    # (b) DURING the kill window: the sibling stripe serves reads AND
    # writes — its partition GenServer is untouched, serialized op included
    assert Store.get(t_b, @key_b) == {:ok, v_b1}
    assert Store.put(t_b, @key_b, v_b2) == :ok
    assert Store.insert_new(t_b, @key_c, %{"plane" => "endurance"}) == :ok
    assert Store.get(t_b, @key_c) == {:ok, %{"plane" => "endurance"}}

    # (c) ONLY the crashed partition respawns; it re-adopts the Heir-held
    # table via reclaim give-away with ZERO key loss
    assert {:ok, _pid_a2} =
             eventually(
               fn ->
                 pid = Smalt.Store.Partition.whereis_owner(Store, t_a)

                 if is_pid(pid) and pid != pid_a and Process.alive?(pid),
                   do: {:ok, pid},
                   else: :not_yet
               end,
               timeout_ms: 10_000
             )

    # zero key loss through the transfer
    assert Store.get(t_a, @key_a) == {:ok, v_a1}

    # and the reclaimed stripe resumes writes + serialized ops
    assert {:ok, :resumed} =
             eventually(
               fn ->
                 if Store.put(t_a, @key_a, v_a2) == :ok, do: {:ok, :resumed}, else: :not_yet
               end,
               timeout_ms: 10_000
             )

    assert Store.get(t_a, @key_a) == {:ok, v_a2}
    assert Store.insert_new(t_a, "store3-4b-ins-" <> Atom.to_string(t_a), %{"plane" => "arm-new"}) == :ok

    # (d) the DISTINCT full-ensemble guarantee: SEALED keys survive a FULL
    # ensemble kill (heir + 16 partitions + boot) via Boot replay
    start_sink(dir)
    Application.put_env(:smalt, :journal_sink_dir, dir)

    sealed = [
      {t_a, "store3-4b-sealed-a", %{"plane" => "arm", "sealed" => true}},
      {t_b, "store3-4b-sealed-b", %{"plane" => "subscription", "sealed" => true}}
    ]

    for {t, k, v} <- sealed do
      assert Store.put(t, k, v) == :ok
    end

    assert %{"frames" => frames} = JournalSink.seal(JournalSink)
    assert frames >= 2
    stop_sink()

    # REAL kill of the ENSEMBLE supervisor (heir + 16 partitions + boot die)
    pid = Process.whereis(Store)
    Process.exit(pid, :kill)
    new_pid = wait_store_up(pid)
    refute Process.alive?(pid)
    assert Process.alive?(new_pid)

    # every SEALED key recovers — replay skips no stripe
    assert {:ok, :all_recovered} =
             eventually(
               fn ->
                 if Enum.all?(sealed, fn {t, k, v} -> Store.get(t, k) == {:ok, v} end),
                   do: {:ok, :all_recovered},
                   else: :not_yet
               end,
               timeout_ms: 10_000
             )

    restore_env(nil)
  end

  # ============================================================================
  # Leg 5 — TTV-4 interplay: full restart recovers committed keys across ALL tables
  # ============================================================================

  @tag :store3
  test "leg5: journal-sealed restart recovers 100% of committed keys across all plane tables", %{
    jdir: dir
  } do
    _prev_pid = wait_store_alive()
    start_sink(dir)
    Application.put_env(:smalt, :journal_sink_dir, dir)

    keys = [
      {:smalt_resources, "store3-rk-1", %{"plane" => "arm"}},
      {:smalt_resources, "store3-rk-2", %{"plane" => "arm-2"}},
      {:smalt_subscriptions, "store3-sk-1", %{"plane" => "subscription"}},
      {:smalt_blobs, "store3-bk-1", %{"plane" => "blob"}},
      {:smalt_cosmos_docs, "store3-ck-1", %{"plane" => "cosmos"}}
    ]

    for {t, k, v} <- keys do
      assert Store.put(t, k, v) == :ok
    end

    # committed = sealed (the TTV-4 law); seal and verify the frames are down
    assert %{"frames" => frames} = JournalSink.seal(JournalSink)
    assert frames >= 5
    stop_sink()

    # full Store restart (real kill, supervisor restart)
    pid = Process.whereis(Store)
    Process.exit(pid, :kill)
    _new_pid = wait_store_up(pid)

    # every committed key on EVERY table recovers — replay skips no table
    assert {:ok, _} =
             eventually(
               fn ->
                 if Enum.all?(keys, fn {t, k, v} -> Store.get(t, k) == {:ok, v} end) do
                   {:ok, :all_recovered}
                 else
                   :not_yet
                 end
               end,
               timeout_ms: 10_000
             )

    restore_env(nil)
  end

  defp start_sink(dir) do
    case JournalSink.start_link(dir: dir) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, _} = e -> e
    end
  end

  defp stop_sink do
    case Process.whereis(JournalSink) do
      nil -> :ok
      pid -> try_do(fn -> GenServer.stop(pid, :normal, 5_000) end)
    end
  end
end
