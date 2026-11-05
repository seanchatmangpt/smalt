defmodule Smalt.Messaging.Kafka.GroupManager do
  @moduledoc """
  KD-190 — Kafka consumer-group coordinator face. Serves the group family:
  FindCoordinator 10, JoinGroup 11, Heartbeat 12, LeaveGroup 13, SyncGroup 14,
  OffsetCommit 8, OffsetFetch 9 — real keys verified from the vendored
  client's own protocol module (tmp/kafkalib/kafka/protocol/commit.py and
  group.py).

  One serialized GenServer owning two ETS tables:

  - :smalt_kafka_groups — {group, group_record}
  - :smalt_kafka_group_offsets — {{group, topic, partition}, offset}
    (in-memory only — the honest KD-190 divergence: offsets vanish across a
    GroupManager restart; close condition = journaled offsets)

  Group state machine: :empty -> :preparing -> :completing -> :stable.
  Generation bumps on every completed rebalance. JoinGroup and follower
  SyncGroup from rebalance-blocking members are PARKED (real broker
  semantics) — the owning Conn keeps reading the socket meanwhile.

  Typed refusals (in-band, never crash-only):
  - protocol_type != "consumer" -> error 23 INCONSISTENT_GROUP_PROTOCOL
  - cooperative-sticky protocols -> error 23 (typed refusal per the plan)
  - session_timeout <= 0 -> error 26 INVALID_SESSION_TIMEOUT
  - static membership: group_instance_id exists only at JoinGroup v5+,
    above our advertised cap (0..2), so a static-membership attempt arrives
    out-of-matrix and takes the crash-only face — that IS the typed
    refusal at this face.

  Error codes verified from the vendored client's errors.py: 22
  ILLEGAL_GENERATION, 23 INCONSISTENT_GROUP_PROTOCOL, 25 UNKNOWN_MEMBER_ID,
  26 INVALID_SESSION_TIMEOUT, 27 REBALANCE_IN_PROGRESS. (The plan text
  pinned "16 REBALANCE_IN_PROGRESS" — premise rot; the real code is 27.)
  """

  use GenServer
  require Logger

  alias Smalt.Messaging.Kafka.Conn
  alias Smalt.Messaging.Kafka.Log

  @groups_table :smalt_kafka_groups
  @offsets_table :smalt_kafka_group_offsets

  # Process.send_after sweeper — SLEEP-CLASS: SCHEDULING (evicts members
  # past session timeout).
  @sweep_interval_ms 1_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "ETS tables owned by this face."
  def tables, do: [@groups_table, @offsets_table]

  @doc "Snapshot reader over the public groups ETS."
  def groups do
    :ets.tab2list(@groups_table) |> Map.new(fn {g, rec} -> {g, rec} end)
  end

  @doc "Offset snapshot reader over the public offsets ETS."
  def offsets do
    :ets.tab2list(@offsets_table) |> Map.new(fn {{g, t, p}, off} -> {{g, t, p}, off} end)
  end

  # -- Conn-side entry points (run in the Conn process) ----------------------

  def handle_find_coordinator(ver, corr, body, sock, port) do
    case parse_string(body) do
      {:ok, _key, _rest} ->
        # KD-COVERS: KD-HC-2 — v1 field order is
        # {throttle_time_ms, error_code, error_message, coordinator_id, host,
        # port} per KIP-113 / the Apache protocol guide (FindCoordinator v1
        # adds a throttle_time_ms i32 head). Premise-rot disclosure: the
        # vendored tmp/kafkalib commit.py GroupCoordinatorResponse_v1 omits
        # the throttle head (kafka-python fork divergence); librdkafka
        # (witnessed _UNDERFLOW on the 23-byte response) and kafkajs follow
        # the guide, so the guide is law here — 27 bytes total. v0 keeps the
        # bare shape (no throttle, no error_message).
        throttle = if ver >= 1, do: [<<0::signed-integer-size(32)>>], else: []
        err_message = if ver >= 1, do: [<<-1::signed-16>>], else: []

        Conn.send_response(sock, corr, [
          throttle,
          <<0::signed-16>>,
          err_message,
          <<0::signed-32, 9::unsigned-16, "127.0.0.1", port::signed-32>>
        ])

        :ok

      :error ->
        :kill
    end
  end

  def handle_join(ver, corr, body, sock, _port) do
    case parse_join(ver, body) do
      {:ok, j} ->
        cond do
          j.protocol_type != "consumer" ->
            join_error(sock, corr, ver, 23)

          Enum.all?(j.protocols, fn {n, _} -> String.contains?(n, "cooperative") end) ->
            join_error(sock, corr, ver, 23)

          j.session_timeout <= 0 ->
            join_error(sock, corr, ver, 26)

          true ->
            args = {j.group, j.member_id, j.session_timeout, j.rebalance_timeout, j.protocol_type, j.protocols, {sock, corr, ver}}
            GenServer.call(__MODULE__, {:join, args}, 15_000)
        end

      :error ->
        :kill
    end
  end

  def handle_sync(ver, corr, body, sock, _port) do
    case parse_sync(body) do
      {:ok, s} ->
        args = {s.group, s.generation, s.member_id, s.assignment, {sock, corr, ver}}
        GenServer.call(__MODULE__, {:sync, args}, 15_000)

      :error ->
        :kill
    end
  end

  def handle_heartbeat(ver, corr, body, sock, _port) do
    case parse_heartbeat(body) do
      {:ok, h} ->
        err = GenServer.call(__MODULE__, {:heartbeat, h.group, h.generation, h.member_id}, 15_000)
        head = if ver >= 1, do: [<<0::signed-32>>], else: []
        Conn.send_response(sock, corr, [head, <<err::signed-16>>])
        :ok

      :error ->
        :kill
    end
  end

  def handle_leave(ver, corr, body, sock, _port) do
    case parse_leave(body) do
      {:ok, l} ->
        err = GenServer.call(__MODULE__, {:leave, l.group, l.member_id}, 15_000)
        head = if ver >= 1, do: [<<0::signed-32>>], else: []
        Conn.send_response(sock, corr, [head, <<err::signed-16>>])
        :ok

      :error ->
        :kill
    end
  end

  def handle_commit(ver, corr, body, sock, _port) do
    case parse_commit(ver, body) do
      {:ok, c} ->
        err = GenServer.call(__MODULE__, {:commit, c.group, c.generation, c.member_id, c.entries}, 15_000)
        head = if ver >= 1, do: [<<0::signed-32>>], else: []

        blocks =
          Enum.map(c.entries, fn {topic, parts} ->
            pblocks = Enum.map(parts, fn {p, _o, _m} -> <<p::signed-32, err::signed-16>> end)
            [str(topic), <<length(pblocks)::signed-32>> | pblocks]
          end)

        Conn.send_response(sock, corr, [head, <<length(blocks)::signed-32>> | blocks])
        :ok

      :error ->
        :kill
    end
  end

  def handle_fetch_offsets(_ver, corr, body, sock, _port) do
    case parse_fetch_offsets(body) do
      {:ok, %{group: g, topics: :all}} ->
        blocks = all_offset_blocks(g)
        Conn.send_response(sock, corr, [<<length(blocks)::signed-32>> | blocks])
        :ok

      {:ok, %{group: g, topics: topics}} ->
        blocks =
          Enum.map(topics, fn {topic, parts} ->
            pblocks =
              Enum.map(parts, fn p ->
                off = offset_for(g, topic, p)
                <<p::signed-32, off::signed-64, 0::unsigned-16, 0::signed-16>>
              end)

            [str(topic), <<length(pblocks)::signed-32>> | pblocks]
          end)

        Conn.send_response(sock, corr, [<<length(blocks)::signed-32>> | blocks])
        :ok

      :error ->
        :kill
    end
  end

  # -- GenServer ----------------------------------------------------------------

  @impl true
  def init(_opts) do
    Process.set_label(%{service: :kafka, role: :group_manager})

    for t <- [@groups_table, @offsets_table] do
      if :ets.whereis(t) == :undefined, do: :ets.new(t, [:set, :named_table, :public])
    end

    # Restore persisted offsets from OffsetJournal (crash recovery)
    try do
      if Code.ensure_loaded?(Smalt.Messaging.OffsetJournal) and Process.whereis(Smalt.Messaging.OffsetJournal) != nil do
        for {key, off} <- Smalt.Messaging.OffsetJournal.restore_kafka_offsets() do
          :ets.insert(@offsets_table, {key, off})
        end
      end
    rescue
      _ -> :ok
    end

    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:join, args}, _from, state) do
    {group, mid, st, rt, ptype, protos, conn} = args
    g = get_group(group)

    cond do
      g.protocol_type != nil and g.protocol_type != ptype ->
        {:reply, reply_join_error(conn, 23), state}

      mid != "" and not Map.has_key?(g.members, mid) ->
        {:reply, reply_join_error(conn, 25), state}

      Enum.all?(protos, fn {n, _} -> String.contains?(n, "cooperative") end) ->
        {:reply, reply_join_error(conn, 23), state}

      true ->
        {_, g2} = register_member(g, mid, st, rt, ptype, protos, conn)
        g3 = maybe_complete(g2)
        put_group(group, g3)
        {:reply, :ok, state}
    end
  end

  def handle_call({:sync, args}, _from, state) do
    {group, gen, mid, assignment, conn} = args
    g = get_group(group)
    member = g.members[mid]

    cond do
      is_nil(member) ->
        {:reply, reply_sync_error(conn, 25), state}

      gen != g.generation ->
        {:reply, reply_sync_error(conn, 22), state}

      g.state == :preparing ->
        {:reply, reply_sync_error(conn, 27), state}

      g.state == :completing and mid == g.leader ->
        g2 = complete_sync(g, assignment, conn)
        put_group(group, g2)
        {:reply, :ok, state}

      g.state == :completing ->
        # follower: park the reply until the leader's SyncGroup lands
        m = Map.put(member, :sync_conn, conn)
        g2 = %{g | members: Map.put(g.members, mid, m)}
        put_group(group, g2)
        {:reply, :ok, state}

      g.state == :stable ->
        {:reply, sync_response(conn, 0, member.assignment), state}
    end
  end

  def handle_call({:heartbeat, group, gen, mid}, _from, state) do
    g = get_group(group)
    member = g.members[mid]

    cond do
      is_nil(member) ->
        {:reply, 25, state}

      gen != g.generation ->
        {:reply, 22, state}

      true ->
        # Real-broker semantics: ANY member request refreshes session liveness —
        # including a heartbeat answered 27 REBALANCE_IN_PROGRESS, else the
        # sweeper evicts members mid-rebalance (witnessed: kafka-python
        # rejoin latency > session timeout during a 2-member rebalance).
        m = Map.put(member, :last, now_ms())
        put_group(group, %{g | members: Map.put(g.members, mid, m)})
        err = if g.state == :preparing, do: 27, else: 0
        {:reply, err, state}
    end
  end

  def handle_call({:leave, group, mid}, _from, state) do
    g = get_group(group)

    if Map.has_key?(g.members, mid) do
      put_group(group, remove_member(g, mid))
      {:reply, 0, state}
    else
      {:reply, 25, state}
    end
  end

  def handle_call({:commit, group, gen, mid, entries}, _from, state) do
    g = get_group(group)

    err =
      cond do
        is_nil(gen) or gen == -1 -> 0
        not Map.has_key?(g.members, mid) -> 25
        gen != g.generation -> 22
        true -> 0
      end

    if err == 0 do
      for {topic, parts} <- entries, {p, off, _m} <- parts do
        :ets.insert(@offsets_table, {{group, topic, p}, off})
        try do
          if Process.whereis(Smalt.Messaging.OffsetJournal) != nil do
            Smalt.Messaging.OffsetJournal.commit(:kafka, group, topic, p, off)
          end
        rescue
          _ -> :ok
        end
      end
    end

    {:reply, err, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    for {group, g} <- :ets.tab2list(@groups_table) do
      evicted = Enum.filter(g.members, fn {_id, m} -> now_ms() - m.last > m.session_timeout end)

      case evicted do
        [] -> :ok
        list ->
          g2 = Enum.reduce(list, g, fn {id, _m}, acc -> remove_member(acc, id) end)
          put_group(group, g2)
          Logger.info("[kafka] group #{group}: evicted #{length(list)} timed-out member(s)")
      end
    end

    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # -- group transitions ----------------------------------------------------------

  defp get_group(group) do
    case :ets.lookup(@groups_table, group) do
      [{_, g}] ->
        g

      [] ->
        %{state: :empty, generation: 0, protocol_type: nil, protocol: nil, leader: nil,
          members: %{}, order: []}
    end
  end

  defp put_group(group, g), do: :ets.insert(@groups_table, {group, g})

  defp register_member(g, "", st, rt, ptype, protos, conn) do
    mid = "smalt-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
    register_member(g, mid, st, rt, ptype, protos, conn)
  end

  defp register_member(g, mid, st, rt, ptype, protos, conn) do
    {name, meta} =
      case protos do
        [{n, m} | _] -> {n, m}
        [] -> {"roundrobin", <<>>}
      end

    member = %{
      session_timeout: st,
      rebalance_timeout: rt,
      protocol_type: ptype,
      protocol: name,
      subscription: meta,
      conn: conn,
      assignment: nil,
      sync_conn: nil,
      joined: true,
      last: now_ms()
    }

    # A join during an in-flight rebalance marks ONLY the joiner rejoined
    # (everyone else's rejoin flag persists); a join that flips the group
    # out of :empty/:stable resets everyone.
    base =
      if g.state == :preparing do
        g
      else
        %{g | state: :preparing, members: reset_joined(g.members)}
      end

    order = if mid in base.order, do: base.order, else: Enum.sort([mid | base.order])
    members = Map.put(base.members, mid, member)

    g2 = %{base | protocol_type: ptype, leader: hd(order), members: members, order: order}
    {mid, g2}
  end

  defp reset_joined(members) do
    Map.new(members, fn {id, m} -> {id, Map.put(m, :joined, false)} end)
  end

  defp maybe_complete(g) do
    if g.state == :preparing and Enum.all?(g.members, fn {_id, m} -> m.joined end) do
      complete_rebalance(g)
    else
      g
    end
  end

  defp complete_rebalance(g) do
    gen = g.generation + 1
    order = g.order
    leader = hd(order)
    protocol = pick_protocol(g, order)
    g = %{g | state: :completing, generation: gen, leader: leader, protocol: protocol}

    for {id, m} <- g.members do
      members_payload =
        if id == leader do
          for mid2 <- order do
            mem = g.members[mid2]
            [str(mid2), <<byte_size(mem.subscription)::signed-32>> | mem.subscription]
          end
        else
          []
        end

      payload = [
        <<0::signed-16, gen::signed-32>>,
        str(protocol),
        str(leader),
        str(id),
        <<length(members_payload)::signed-32>> | members_payload
      ]

      join_response(m.conn, payload)
    end

    g
  end

  defp pick_protocol(g, order) do
    names = Enum.map(order, fn id -> g.members[id].protocol end)
    hd(Enum.uniq(names))
  end

  defp complete_sync(g, assignment, leader_conn) do
    assigns =
      if assignment == [] do
        compute_assignment(g)
      else
        Map.new(assignment)
      end

    g = store_assignments(g, assigns)
    g = %{g | state: :stable}

    # deliver: leader gets this conn, parked followers get their parked conn
    for {id, m} <- g.members do
      conn = if id == g.leader, do: leader_conn, else: Map.get(m, :sync_conn)
      if conn, do: sync_response(conn, 0, m.assignment)
    end

    members = Map.new(g.members, fn {id, m} -> {id, Map.put(m, :sync_conn, nil)} end)
    %{g | members: members}
  end

  defp store_assignments(g, assigns) do
    Enum.reduce(assigns, g, fn {mid, bytes}, acc ->
      if Map.has_key?(acc.members, mid) do
        m = Map.put(acc.members[mid], :assignment, bytes)
        %{acc | members: Map.put(acc.members, mid, m)}
      else
        acc
      end
    end)
  end

  defp remove_member(g, mid) do
    member = g.members[mid]

    if is_map(member) and member.sync_conn do
      sync_response(member.sync_conn, 27, nil)
    end

    members = Map.delete(g.members, mid)

    if members == %{} do
      %{g | state: :empty, leader: nil, protocol: nil, protocol_type: nil, members: %{}, order: []}
    else
      order = Enum.reject(g.order, fn id -> id == mid end)
      %{g | state: :preparing, members: reset_joined(members), order: order, leader: hd(order)}
    end
  end

  defp compute_assignment(g) do
    case g.protocol do
      "range" -> range_assignment(g)
      _ -> roundrobin_assignment(g)
    end
  end

  defp member_ids(g), do: g.members |> Map.keys() |> Enum.sort()

  defp roundrobin_assignment(g) do
    ids = member_ids(g)
    n = length(ids)
    topics = subscription_topics(g) |> Enum.sort()
    count = Log.partition_count()

    acc =
      Enum.reduce(Enum.with_index(topics), %{}, fn {topic, ti}, acc ->
        Enum.reduce(0..(count - 1), acc, fn p, acc2 ->
          id = Enum.at(ids, rem(ti * count + p, n))
          Map.update(acc2, id, %{topic => [p]}, fn m -> Map.update(m, topic, [p], &(&1 ++ [p])) end)
        end)
      end)

    Map.new(ids, fn id -> {id, encode_assignment(Map.get(acc, id, %{}))} end)
  end

  defp range_assignment(g) do
    ids = member_ids(g)
    n = length(ids)
    topics = subscription_topics(g) |> Enum.sort()
    count = Log.partition_count()

    Enum.reduce(topics, %{}, fn topic, acc ->
      per = div(count, n)
      extra = rem(count, n)

      {tmap, _} =
        Enum.map_reduce(ids, 0, fn id, cursor ->
          take = per + if rem(count, n) != 0 and cursor < extra * (per + 1), do: 1, else: 0
          take = min(take, count - cursor)
          {{id, Enum.to_list(cursor..(cursor + take - 1))}, cursor + take}
        end)

      Enum.reduce(tmap, acc, fn {id, parts}, acc2 ->
        Map.update(acc2, id, %{topic => parts}, fn m -> Map.update(m, topic, parts, &(&1 ++ parts)) end)
      end)
    end)
    |> then(fn map -> Map.new(ids, fn id -> {id, encode_assignment(Map.get(map, id, %{}))} end) end)
  end

  defp subscription_topics(g) do
    g.members
    |> Map.values()
    |> Enum.flat_map(fn m -> decode_sub_topics(m.subscription) end)
    |> Enum.uniq()
  end

  # ConsumerProtocolSubscription v0: version i16 | topics array | userdata bytes
  defp decode_sub_topics(<<0::signed-16, n::signed-32, rest::binary>>) when n >= 0,
    do: do_sub_topics(rest, n, [])

  defp decode_sub_topics(_), do: []

  defp do_sub_topics(<<len::unsigned-16, t::binary-size(len)-unit(8), rest::binary>>, n, acc)
       when n > 0,
       do: do_sub_topics(rest, n - 1, [t | acc])

  defp do_sub_topics(<<-1::signed-32, _::binary>>, 0, acc), do: Enum.reverse(acc)
  defp do_sub_topics(<<len::signed-32, _::binary-size(len)-unit(8), _::binary>>, 0, acc) when len >= 0,
    do: Enum.reverse(acc)

  defp do_sub_topics(_, _, _), do: []

  # MemberAssignment v0: version i16=0 | {topic, partitions[]} array | userdata bytes
  defp encode_assignment(topic_map) do
    entries =
      topic_map
      |> Enum.sort()
      |> Enum.map(fn {topic, parts} ->
        pblocks = Enum.map(Enum.sort(parts), fn p -> <<p::signed-32>> end)
        [str(topic), <<length(pblocks)::signed-32>> | pblocks]
      end)

    ([<<0::signed-16, map_size(topic_map)::signed-32>> | entries] ++ [<<-1::signed-32>>])
    |> IO.iodata_to_binary()
  end

  # -- response encoders ------------------------------------------------------------

  defp join_response({sock, corr, ver}, payload) do
    head = if ver >= 2, do: [<<0::signed-32>>], else: []
    Conn.send_response(sock, corr, [head | payload])
  end

  defp join_error(sock, corr, ver, err) do
    payload = [
      <<err::signed-16, 0::signed-32>>,
      str(""),
      str(""),
      str(""),
      <<0::signed-32>>
    ]

    head = if ver >= 2, do: [<<0::signed-32>>], else: []
    Conn.send_response(sock, corr, [head | payload])
    :ok
  end

  defp reply_join_error(conn, err) do
    {sock, corr, ver} = conn
    join_error(sock, corr, ver, err)
    :ok
  end

  defp sync_response({sock, corr, ver}, err, assignment) do
    head = if ver >= 1, do: [<<0::signed-32>>], else: []

    assignment_part =
      if assignment do
        <<byte_size(assignment)::signed-32>> |> then(fn l -> [l | assignment] end)
      else
        [<<-1::signed-32>>]
      end

    Conn.send_response(sock, corr, [head, <<err::signed-16>> | assignment_part])
    :ok
  end

  defp reply_sync_error(conn, err), do: sync_response(conn, err, nil)

  defp offset_for(group, topic, p) do
    case :ets.lookup(@offsets_table, {group, topic, p}) do
      [{{_, _, _}, off}] -> off
      [] -> -1
    end
  end

  defp all_offset_blocks(group) do
    @offsets_table
    |> :ets.tab2list()
    |> Enum.filter(fn {{g, _t, _p}, _off} -> g == group end)
    |> Enum.group_by(fn {{_g, t, _p}, _} -> t end, fn {{_g, _t, p}, off} -> {p, off} end)
    |> Enum.sort()
    |> Enum.map(fn {topic, parts} ->
      pblocks =
        Enum.sort(parts)
        |> Enum.map(fn {p, off} ->
          <<p::signed-32, off::signed-64, 0::unsigned-16, 0::signed-16>>
        end)

      [str(topic), <<length(pblocks)::signed-32>> | pblocks]
    end)
  end

  defp str(b), do: <<byte_size(b)::unsigned-16>> |> then(fn l -> [l | b] end)

  defp now_ms, do: System.convert_time_unit(:erlang.monotonic_time(), :native, :millisecond)

  # -- request parsers ----------------------------------------------------------------

  defp parse_string(<<len::signed-16, b::binary-size(len)-unit(8), rest::binary>>) when len >= 0,
    do: {:ok, b, rest}

  defp parse_string(_), do: :error

  defp parse_bytes(<<len::signed-32, b::binary-size(len)-unit(8), rest::binary>>) when len >= 0,
    do: {:ok, b, rest}

  defp parse_bytes(_), do: :error

  defp parse_join(ver, body) do
    with {:ok, group, r1} <- parse_string(body),
         {:ok, st, r2} <- parse_i32(r1),
         {:ok, rt, r3} <- if(ver >= 1, do: parse_i32(r2), else: {:ok, 0, r2}),
         {:ok, mid, r4} <- parse_string(r3),
         {:ok, ptype, r5} <- parse_string(r4),
         {:ok, protos, _} <- parse_protocols(r5) do
      {:ok,
       %{group: group, session_timeout: st, rebalance_timeout: rt, member_id: mid,
         protocol_type: ptype, protocols: protos}}
    else
      _ -> :error
    end
  end

  defp parse_i32(<<v::signed-32, rest::binary>>), do: {:ok, v, rest}
  defp parse_i32(_), do: :error

  defp parse_protocols(<<n::signed-32, rest::binary>>) when n >= 0, do: do_protocols(rest, n, [])
  defp parse_protocols(_), do: :error

  defp do_protocols(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp do_protocols(rest, n, acc) when n > 0 do
    with {:ok, name, r1} <- parse_string(rest),
         {:ok, meta, r2} <- parse_bytes(r1) do
      do_protocols(r2, n - 1, [{name, meta} | acc])
    else
      _ -> :error
    end
  end

  defp do_protocols(_, _, _), do: :error

  defp parse_sync(body) do
    with {:ok, group, r1} <- parse_string(body),
         {:ok, gen, r2} <- parse_i32(r1),
         {:ok, mid, r3} <- parse_string(r2),
         {:ok, assigns, _} <- parse_assign_list(r3) do
      {:ok, %{group: group, generation: gen, member_id: mid, assignment: assigns}}
    else
      _ -> :error
    end
  end

  defp parse_assign_list(<<n::signed-32, rest::binary>>) when n >= 0, do: do_assigns(rest, n, [])
  defp parse_assign_list(_), do: :error

  defp do_assigns(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp do_assigns(rest, n, acc) when n > 0 do
    with {:ok, mid, r1} <- parse_string(rest),
         {:ok, bytes, r2} <- parse_bytes(r1) do
      do_assigns(r2, n - 1, [{mid, bytes} | acc])
    else
      _ -> :error
    end
  end

  defp do_assigns(_, _, _), do: :error

  defp parse_heartbeat(body) do
    with {:ok, group, r1} <- parse_string(body),
         {:ok, gen, r2} <- parse_i32(r1),
         {:ok, mid, _} <- parse_string(r2) do
      {:ok, %{group: group, generation: gen, member_id: mid}}
    else
      _ -> :error
    end
  end

  defp parse_leave(body) do
    with {:ok, group, r1} <- parse_string(body),
         {:ok, mid, _} <- parse_string(r1) do
      {:ok, %{group: group, member_id: mid}}
    else
      _ -> :error
    end
  end

  defp parse_commit(ver, body) do
    with {:ok, group, r1} <- parse_string(body),
         {:ok, gen, r2} <- if(ver >= 1, do: parse_i32(r1), else: {:ok, nil, r1}),
         {:ok, mid, r3} <- if(ver >= 1, do: parse_string(r2), else: {:ok, nil, r2}),
         {:ok, r4} <- if(ver >= 2, do: skip_i64(r3), else: {:ok, r3}),
         {:ok, entries, _} <- parse_commit_topics(r4, ver) do
      {:ok, %{group: group, generation: gen, member_id: mid, entries: entries}}
    else
      _ -> :error
    end
  end

  defp skip_i64(<<_::signed-64, rest::binary>>), do: {:ok, rest}
  defp skip_i64(_), do: :error

  defp parse_commit_topics(<<n::signed-32, rest::binary>>, ver) when n >= 0,
    do: do_commit_topics(rest, n, [], ver)

  defp parse_commit_topics(_, _), do: :error

  defp do_commit_topics(rest, 0, acc, _ver), do: {:ok, Enum.reverse(acc), rest}

  defp do_commit_topics(rest, n, acc, ver) when n > 0 do
    with {:ok, topic, r1} <- parse_string(rest),
         {:ok, np, r2} <- parse_i32(r1),
         {:ok, parts, r3} <- do_commit_parts(r2, np, [], ver) do
      do_commit_topics(r3, n - 1, [{topic, parts} | acc], ver)
    else
      _ -> :error
    end
  end

  defp do_commit_topics(_, _, _, _), do: :error

  defp do_commit_parts(rest, 0, acc, _ver), do: {:ok, Enum.reverse(acc), rest}

  defp do_commit_parts(rest, n, acc, ver) when n > 0 do
    with {:ok, p, r1} <- parse_i32(rest),
         {:ok, off, r2} <- parse_i64(r1),
         {:ok, r3} <- if(ver >= 2, do: {:ok, r2}, else: skip_i64(r2)),
         {:ok, meta, r4} <- parse_string(r3) do
      do_commit_parts(r4, n - 1, [{p, off, meta} | acc], ver)
    else
      _ -> :error
    end
  end

  defp do_commit_parts(_, _, _, _), do: :error

  defp parse_i64(<<v::signed-64, rest::binary>>), do: {:ok, v, rest}
  defp parse_i64(_), do: :error

  defp parse_fetch_offsets(body) do
    with {:ok, group, r1} <- parse_string(body),
         {:ok, topics, _} <- parse_fetch_topics(r1) do
      {:ok, %{group: group, topics: topics}}
    else
      _ -> :error
    end
  end

  # v1 allows a null topics array (-1) meaning "all offsets for this group".
  defp parse_fetch_topics(<<-1::signed-32, rest::binary>>), do: {:ok, :all, rest}

  defp parse_fetch_topics(<<n::signed-32, rest::binary>>) when n >= 0,
    do: do_fetch_topics(rest, n, [])

  defp parse_fetch_topics(_), do: :error

  defp do_fetch_topics(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp do_fetch_topics(rest, n, acc) when n > 0 do
    with {:ok, topic, r1} <- parse_string(rest),
         {:ok, np, r2} <- parse_i32(r1),
         {:ok, parts, r3} <- do_fetch_parts(r2, np, []) do
      do_fetch_topics(r3, n - 1, [{topic, parts} | acc])
    else
      _ -> :error
    end
  end

  defp do_fetch_topics(_, _, _), do: :error

  defp do_fetch_parts(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp do_fetch_parts(<<p::signed-32, rest::binary>>, n, acc) when n > 0,
    do: do_fetch_parts(rest, n - 1, [p | acc])

  defp do_fetch_parts(_, _, _), do: :error
end
