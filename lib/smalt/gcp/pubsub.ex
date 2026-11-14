defmodule Smalt.Gcp.PubSub do
  @moduledoc """
  Cloud Pub/Sub REST v1 dialect (lane GS2) over the Queue Storage substrate
  (`Smalt.DataPlane.QueueStorage`, tables `:smalt_q_*`).

  One subscription = one substrate queue (account = project id, queue =
  `ps-<sha256(subscription name)[0..39]>`). Publish fans out to every
  subscription of the topic. Delivery state (ack ids, leases, ordering
  in-flight keys, attempts, snapshots) lives in this GenServer; message
  bytes live in the substrate. Emulator-grade: one serialized process.

  Surface: topics create/get/delete/list/publish; subscriptions
  create/get/delete/list/pull/acknowledge/modifyAckDeadline; ordering keys
  (`enableMessageOrdering`: one in-flight message per key, FIFO per key);
  dead-letter (`deadLetterPolicy`, forwarded after `maxDeliveryAttempts`
  deliveries); snapshots create/get/delete/list; seek to snapshot / time.

  Time seam: every call accepts `opts` with `"now_ms"` so ack-deadline
  expiry is driven by the observable clock input, never by sleeping.

  Errors are `{:error, http_status, grpc_status, message}`.
  """

  use GenServer

  alias Smalt.DataPlane.QueueStorage

  @max_pull 1000
  @substrate_batch 32

  # ---- lifecycle ------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok), do: {:ok, new_state()}

  defp new_state do
    %{topics: %{}, subs: %{}, snaps: %{}, acks: %{}, attempts: %{}, logs: %{}, unacked: %{}, seq: 0}
  end

  @doc "Drop all registry state (substrate queues are deleted too)."
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset, 30_000)

  # ---- client API -----------------------------------------------------

  def create_topic(name, server \\ __MODULE__), do: call(server, {:create_topic, name})
  def get_topic(name, server \\ __MODULE__), do: call(server, {:get_topic, name})
  def delete_topic(name, server \\ __MODULE__), do: call(server, {:delete_topic, name})
  def list_topics(project, server \\ __MODULE__), do: call(server, {:list_topics, project})

  def publish(topic, messages, opts \\ %{}, server \\ __MODULE__),
    do: call(server, {:publish, topic, messages, opts})

  def create_subscription(name, body, server \\ __MODULE__),
    do: call(server, {:create_sub, name, body})

  def get_subscription(name, server \\ __MODULE__), do: call(server, {:get_sub, name})
  def delete_subscription(name, server \\ __MODULE__), do: call(server, {:delete_sub, name})
  def list_subscriptions(project, server \\ __MODULE__), do: call(server, {:list_subs, project})

  def pull(sub, body, opts \\ %{}, server \\ __MODULE__), do: call(server, {:pull, sub, body, opts})

  def acknowledge(sub, ack_ids, opts \\ %{}, server \\ __MODULE__),
    do: call(server, {:ack, sub, ack_ids, opts})

  def modify_ack_deadline(sub, ack_ids, seconds, opts \\ %{}, server \\ __MODULE__),
    do: call(server, {:modack, sub, ack_ids, seconds, opts})

  def create_snapshot(name, body, server \\ __MODULE__), do: call(server, {:create_snap, name, body})
  def get_snapshot(name, server \\ __MODULE__), do: call(server, {:get_snap, name})
  def delete_snapshot(name, server \\ __MODULE__), do: call(server, {:delete_snap, name})
  def list_snapshots(project, server \\ __MODULE__), do: call(server, {:list_snaps, project})

  def seek(sub, body, opts \\ %{}, server \\ __MODULE__), do: call(server, {:seek, sub, body, opts})

  defp call(server, msg), do: GenServer.call(server, msg, 30_000)

  # ---- server ---------------------------------------------------------

  @impl true
  def handle_call(:reset, _from, st) do
    for {name, _} <- st.subs, do: drop_queue(name)
    {:reply, :ok, new_state()}
  end

  def handle_call(msg, _from, st) do
    if QueueStorage.store_ready?() do
      {reply, st2} = handle(msg, st)
      {:reply, reply, st2}
    else
      {:reply, {:error, 503, "UNAVAILABLE", "queue substrate not ready"}, st}
    end
  end

  # topics
  defp handle({:create_topic, name}, st) do
    with :ok <- valid_name(name, "topics") do
      if Map.has_key?(st.topics, name) do
        {err(409, "ALREADY_EXISTS", "Resource already exists: #{name}"), st}
      else
        t = %{"name" => name}
        {{:ok, t}, put_in(st.topics[name], t)}
      end
    else
      e -> {e, st}
    end
  end

  defp handle({:get_topic, name}, st), do: {fetch(st.topics, name, "Topic"), st}

  defp handle({:delete_topic, name}, st) do
    case st.topics do
      %{^name => _} ->
        # Subscriptions survive as detached, per Pub/Sub semantics.
        subs = for {k, s} <- st.subs, into: %{}, do: {k, detach(s, name)}
        {{:ok, %{}}, %{st | topics: Map.delete(st.topics, name), subs: subs}}

      _ ->
        {not_found("Topic", name), st}
    end
  end

  defp handle({:list_topics, project}, st) do
    {{:ok, %{"topics" => listing(st.topics, "projects/#{project}/")}}, st}
  end

  # publish
  defp handle({:publish, topic, messages, opts}, st) do
    cond do
      not Map.has_key?(st.topics, topic) ->
        {not_found("Topic", topic), st}

      not is_list(messages) or messages == [] ->
        {err(400, "INVALID_ARGUMENT", "The value for message_count is too small. You passed 0."), st}

      true ->
        now = now(opts)

        case build_messages(messages, now, st) do
          {:error, _, _, _} = e ->
            {e, st}

          {:ok, recs, st1} ->
            targets = for {n, s} <- st1.subs, s["topic"] == topic, do: n
            st2 = Enum.reduce(targets, st1, fn sub, acc -> Enum.reduce(recs, acc, &enqueue(&2, sub, &1)) end)
            {{:ok, %{"messageIds" => Enum.map(recs, & &1["messageId"])}}, st2}
        end
    end
  end

  # subscriptions
  defp handle({:create_sub, name, body}, st) do
    topic = body["topic"]
    dlp = body["deadLetterPolicy"]

    cond do
      valid_name(name, "subscriptions") != :ok -> {valid_name(name, "subscriptions"), st}
      Map.has_key?(st.subs, name) -> {err(409, "ALREADY_EXISTS", "Resource already exists: #{name}"), st}
      not Map.has_key?(st.topics, topic || "") -> {not_found("Topic", topic || ""), st}
      bad_dlp?(dlp) -> {err(400, "INVALID_ARGUMENT", "deadLetterPolicy.maxDeliveryAttempts must be 5..100"), st}
      true ->
        deadline = body["ackDeadlineSeconds"] || 10

        if not is_integer(deadline) or deadline < 10 or deadline > 600 do
          {err(400, "INVALID_ARGUMENT", "ackDeadlineSeconds must be 10..600"), st}
        else
          {:ok, 201, _} = QueueStorage.create_queue(project_of(name), queue_name(name))

          sub =
            %{
              "name" => name,
              "topic" => topic,
              "ackDeadlineSeconds" => deadline,
              "enableMessageOrdering" => body["enableMessageOrdering"] == true,
              "state" => "ACTIVE"
            }
            |> put_if("deadLetterPolicy", dlp)

          {{:ok, sub}, %{st | subs: Map.put(st.subs, name, sub)}}
        end
    end
  end

  defp handle({:get_sub, name}, st), do: {fetch(st.subs, name, "Subscription"), st}

  defp handle({:delete_sub, name}, st) do
    case st.subs do
      %{^name => _} ->
        drop_queue(name)

        {{:ok, %{}},
         %{
           st
           | subs: Map.delete(st.subs, name),
             acks: Map.reject(st.acks, fn {_, a} -> a.sub == name end),
             logs: Map.delete(st.logs, name),
             unacked: Map.delete(st.unacked, name)
         }}

      _ ->
        {not_found("Subscription", name), st}
    end
  end

  defp handle({:list_subs, project}, st) do
    {{:ok, %{"subscriptions" => listing(st.subs, "projects/#{project}/")}}, st}
  end

  # pull
  defp handle({:pull, sub, body, opts}, st) do
    case st.subs do
      %{^sub => s} ->
        max = body["maxMessages"]

        if not is_integer(max) or max < 1 do
          {err(400, "INVALID_ARGUMENT", "maxMessages must be a positive integer"), st}
        else
          do_pull(st, s, min(max, @max_pull), now(opts))
        end

      _ ->
        {not_found("Subscription", sub), st}
    end
  end

  defp handle({:ack, sub, ids, opts}, st) do
    with_sub(st, sub, fn st ->
      now = now(opts)

      Enum.reduce(ids, st, fn id, acc ->
        case acc.acks do
          %{^id => %{sub: ^sub} = a} ->
            case QueueStorage.delete_message(project_of(sub), queue_name(sub), a.qid, a.pr, %{"now_ms" => now}) do
              {:ok, 204, _} -> settle(acc, sub, id, a)
              _ -> %{acc | acks: Map.delete(acc.acks, id)}
            end

          _ ->
            acc
        end
      end)
    end)
  end

  defp handle({:modack, sub, ids, secs, opts}, st) do
    cond do
      not is_integer(secs) or secs < 0 or secs > 600 ->
        {err(400, "INVALID_ARGUMENT", "ackDeadlineSeconds must be 0..600"), st}

      true ->
        with_sub(st, sub, fn st ->
          now = now(opts)

          Enum.reduce(ids, st, fn id, acc ->
            case acc.acks do
              %{^id => %{sub: ^sub} = a} -> modack_one(acc, sub, id, a, secs, now)
              _ -> acc
            end
          end)
        end)
    end
  end

  # snapshots
  defp handle({:create_snap, name, body}, st) do
    sub = body["subscription"]

    cond do
      valid_name(name, "snapshots") != :ok -> {valid_name(name, "snapshots"), st}
      Map.has_key?(st.snaps, name) -> {err(409, "ALREADY_EXISTS", "Resource already exists: #{name}"), st}
      not Map.has_key?(st.subs, sub || "") -> {not_found("Subscription", sub || ""), st}
      true ->
        recs = st.unacked |> Map.get(sub, %{}) |> Map.values() |> Enum.sort_by(& &1["_seq"])
        snap = %{"name" => name, "topic" => st.subs[sub]["topic"], "expireTime" => expire_iso()}
        entry = %{pub: snap, sub: sub, recs: recs, at: System.os_time(:millisecond)}
        {{:ok, snap}, put_in(st.snaps[name], entry)}
    end
  end

  defp handle({:get_snap, name}, st) do
    case st.snaps do
      %{^name => e} -> {{:ok, e.pub}, st}
      _ -> {not_found("Snapshot", name), st}
    end
  end

  defp handle({:delete_snap, name}, st) do
    if Map.has_key?(st.snaps, name),
      do: {{:ok, %{}}, %{st | snaps: Map.delete(st.snaps, name)}},
      else: {not_found("Snapshot", name), st}
  end

  defp handle({:list_snaps, project}, st) do
    prefix = "projects/#{project}/"
    snaps = for {n, e} <- st.snaps, String.starts_with?(n, prefix), do: e.pub
    {{:ok, %{"snapshots" => Enum.sort_by(snaps, & &1["name"])}}, st}
  end

  # seek
  defp handle({:seek, sub, body, opts}, st) do
    with_sub_result(st, sub, fn s ->
      case body do
        %{"snapshot" => snap} ->
          case st.snaps do
            %{^snap => e} -> {:ok, reseed(st, s["name"], e.recs, now(opts))}
            _ -> not_found("Snapshot", snap)
          end

        %{"time" => t} when is_binary(t) ->
          case DateTime.from_iso8601(t) do
            {:ok, dt, _} ->
              ms = DateTime.to_unix(dt, :millisecond)
              recs = st.logs |> Map.get(sub, []) |> Enum.filter(&(&1["_pub_ms"] >= ms))
              {:ok, reseed(st, sub, recs, now(opts))}

            _ ->
              err(400, "INVALID_ARGUMENT", "invalid seek time")
          end

        _ ->
          err(400, "INVALID_ARGUMENT", "seek requires snapshot or time")
      end
    end)
  end

  # ---- pull engine ----------------------------------------------------

  defp do_pull(st, s, max, now) do
    sub = s["name"]
    ordered? = s["enableMessageOrdering"]
    vt = s["ackDeadlineSeconds"]
    acct = project_of(sub)
    q = queue_name(sub)
    held = in_flight_keys(st, sub, now)

    {:ok, 200, _, xml} =
      QueueStorage.get_messages(acct, q, %{
        "visibilitytimeout" => Integer.to_string(vt),
        "numofmessages" => Integer.to_string(@substrate_batch),
        "now_ms" => now
      })

    parsed = parse_xml(xml)

    {delivered, st2, _held} =
      Enum.reduce(parsed, {[], st, held}, fn m, {out, acc, hk} ->
        rec = decode_rec(m.text)
        key = rec["orderingKey"] || ""
        seen = Map.get(acc.attempts, {sub, m.id}, 0)
        dlp = s["deadLetterPolicy"]

        cond do
          dlp && seen >= dlp["maxDeliveryAttempts"] ->
            QueueStorage.delete_message(acct, q, m.id, m.pr, %{"now_ms" => now})
            {out, dead_letter(acc, sub, dlp, rec, m.id), hk}

          length(out) >= max ->
            release(acct, q, m, now)
            {out, acc, hk}

          ordered? and key != "" and MapSet.member?(hk, key) ->
            release(acct, q, m, now)
            {out, acc, hk}

          true ->
            ack_id = new_ack_id(acc)
            attempts = seen + 1

            a = %{sub: sub, qid: m.id, pr: m.pr, key: if(ordered?, do: key, else: ""), lease_until: now + vt * 1000, rid: rec["messageId"]}

            acc2 = %{acc | acks: Map.put(acc.acks, ack_id, a), seq: acc.seq + 1, attempts: Map.put(acc.attempts, {sub, m.id}, attempts)}

            out_rec = %{
              "ackId" => ack_id,
              "message" => Map.take(rec, ["data", "attributes", "messageId", "publishTime", "orderingKey"]),
              "deliveryAttempt" => attempts
            }

            {[out_rec | out], acc2, MapSet.put(hk, key)}
        end
      end)

    # DLQ-less subs never expose deliveryAttempt (Pub/Sub only sets it with a policy).
    out =
      delivered
      |> Enum.reverse()
      |> Enum.map(fn r -> if s["deadLetterPolicy"], do: r, else: Map.delete(r, "deliveryAttempt") end)

    {{:ok, %{"receivedMessages" => out}}, st2}
  end

  defp release(acct, q, m, now) do
    QueueStorage.update_message(acct, q, m.id, m.pr, nil, %{"visibilitytimeout" => "0", "now_ms" => now})
  end

  defp modack_one(st, sub, id, a, 0, now) do
    case QueueStorage.update_message(project_of(sub), queue_name(sub), a.qid, a.pr, nil, %{"visibilitytimeout" => "0", "now_ms" => now}) do
      {:ok, 200, _, _} -> %{st | acks: Map.delete(st.acks, id)}
      _ -> %{st | acks: Map.delete(st.acks, id)}
    end
  end

  defp modack_one(st, sub, id, a, secs, now) do
    case QueueStorage.update_message(project_of(sub), queue_name(sub), a.qid, a.pr, nil, %{"visibilitytimeout" => Integer.to_string(secs), "now_ms" => now}) do
      {:ok, 200, _, xml} ->
        [m] = parse_xml(xml)
        put_in(st.acks[id], %{a | pr: m.pr, lease_until: now + secs * 1000})

      _ ->
        %{st | acks: Map.delete(st.acks, id)}
    end
  end

  defp settle(st, sub, id, a) do
    unacked = Map.update(st.unacked, sub, %{}, &Map.delete(&1, a.rid))
    %{st | acks: Map.delete(st.acks, id), unacked: unacked, attempts: Map.delete(st.attempts, {sub, a.qid})}
  end

  defp in_flight_keys(st, sub, now) do
    for {_, a} <- st.acks, a.sub == sub, a.key != "", a.lease_until > now, into: MapSet.new(), do: a.key
  end

  defp dead_letter(st, sub, dlp, rec, qid) do
    dlt = dlp["deadLetterTopic"]
    st = %{st | attempts: Map.delete(st.attempts, {sub, qid}), unacked: Map.update(st.unacked, sub, %{}, &Map.delete(&1, rec["messageId"]))}

    if Map.has_key?(st.topics, dlt || "") do
      attrs =
        Map.merge(rec["attributes"] || %{}, %{
          "CloudPubSubDeadLetterSourceSubscription" => sub,
          "CloudPubSubDeadLetterSourceDeliveryCount" => Integer.to_string(dlp["maxDeliveryAttempts"])
        })

      fresh = %{rec | "attributes" => attrs} |> Map.put("messageId", next_id(st)) |> Map.put("_seq", st.seq + 1)
      st = %{st | seq: st.seq + 1}
      targets = for {n, s} <- st.subs, s["topic"] == dlt, do: n
      Enum.reduce(targets, st, &enqueue(&2, &1, fresh))
    else
      st
    end
  end

  # ---- substrate helpers ---------------------------------------------

  defp build_messages(messages, now, st) do
    Enum.reduce_while(messages, {:ok, [], st}, fn m, {:ok, acc, s} ->
      data = m["data"] || ""
      attrs = m["attributes"] || %{}

      cond do
        not is_binary(data) or Base.decode64(data) == :error ->
          {:halt, err(400, "INVALID_ARGUMENT", "message data must be base64")}

        data == "" and attrs == %{} ->
          {:halt, err(400, "INVALID_ARGUMENT", "Messages must contain data or attributes")}

        true ->
          s = %{s | seq: s.seq + 1}

          rec =
            %{
              "messageId" => "#{s.seq}#{:erlang.unique_integer([:positive])}",
              "data" => data,
              "attributes" => attrs,
              "publishTime" => DateTime.to_iso8601(DateTime.from_unix!(now, :millisecond)),
              "_pub_ms" => now,
              "_seq" => s.seq
            }
            |> put_if("orderingKey", m["orderingKey"])

          {:cont, {:ok, [rec | acc], s}}
      end
    end)
    |> case do
      {:ok, recs, s} -> {:ok, Enum.reverse(recs), s}
      other -> other
    end
  end

  defp enqueue(st, sub, rec) do
    text = Base.encode64(Jason.encode!(rec))
    body = "<QueueMessage><MessageText>#{text}</MessageText></QueueMessage>"
    {:ok, 201, _, _} = QueueStorage.put_message(project_of(sub), queue_name(sub), body, %{"messagettl" => "-1"})

    %{
      st
      | logs: Map.update(st.logs, sub, [rec], &(&1 ++ [rec])),
        unacked: Map.update(st.unacked, sub, %{rec["messageId"] => rec}, &Map.put(&1, rec["messageId"], rec))
    }
  end

  defp reseed(st, sub, recs, now) do
    acct = project_of(sub)
    QueueStorage.clear_messages(acct, queue_name(sub))
    st = %{st | acks: Map.reject(st.acks, fn {_, a} -> a.sub == sub end), unacked: Map.put(st.unacked, sub, %{})}
    _ = now
    Enum.reduce(recs, st, fn rec, acc ->
      acc = enqueue(acc, sub, rec)
      # enqueue appends to the log; replays must not duplicate history.
      %{acc | logs: Map.update!(acc.logs, sub, &Enum.drop(&1, -1))}
    end)
  end

  defp drop_queue(sub), do: QueueStorage.delete_queue(project_of(sub), queue_name(sub))

  defp queue_name(sub) do
    "ps-" <> (:crypto.hash(:sha256, sub) |> Base.encode16(case: :lower) |> binary_part(0, 40))
  end

  defp project_of("projects/" <> rest), do: rest |> String.split("/") |> hd()

  defp parse_xml(xml) do
    ~r/<QueueMessage>(.*?)<\/QueueMessage>/s
    |> Regex.scan(xml, capture: :all_but_first)
    |> Enum.map(fn [b] ->
      %{
        id: tag(b, "MessageId"),
        pr: tag(b, "PopReceipt"),
        text: tag(b, "MessageText")
      }
    end)
  end

  defp tag(b, t) do
    case Regex.run(~r/<#{t}>(.*?)<\/#{t}>/s, b, capture: :all_but_first) do
      [v] -> v
      _ -> nil
    end
  end

  defp decode_rec(nil), do: %{}
  defp decode_rec(text), do: text |> Base.decode64!() |> Jason.decode!()

  # ---- small helpers --------------------------------------------------

  defp now(opts), do: Map.get(opts, "now_ms") || System.os_time(:millisecond)

  defp new_ack_id(st), do: "ack-" <> Integer.to_string(st.seq) <> "-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  defp next_id(st), do: "#{st.seq + 1}#{:erlang.unique_integer([:positive])}"

  defp expire_iso, do: DateTime.utc_now() |> DateTime.add(7 * 86_400) |> DateTime.to_iso8601()

  defp put_if(map, _k, nil), do: map
  defp put_if(map, k, v), do: Map.put(map, k, v)

  defp bad_dlp?(nil), do: false

  defp bad_dlp?(%{"deadLetterTopic" => t, "maxDeliveryAttempts" => n}) when is_binary(t) and is_integer(n),
    do: n < 5 or n > 100

  defp bad_dlp?(_), do: true

  defp detach(s, topic), do: if(s["topic"] == topic, do: Map.put(s, "topic", "_deleted-topic_"), else: s)

  defp listing(map, prefix) do
    for {n, v} <- Enum.sort(map), String.starts_with?(n, prefix), do: v
  end

  defp fetch(map, name, kind) do
    case map do
      %{^name => v} -> {:ok, v}
      _ -> not_found(kind, name)
    end
  end

  defp with_sub(st, sub, fun) do
    if Map.has_key?(st.subs, sub), do: {{:ok, %{}}, fun.(st)}, else: {not_found("Subscription", sub), st}
  end

  defp with_sub_result(st, sub, fun) do
    case st.subs do
      %{^sub => s} ->
        case fun.(s) do
          {:ok, st2} -> {{:ok, %{}}, st2}
          {:error, _, _, _} = e -> {e, st}
        end

      _ ->
        {not_found("Subscription", sub), st}
    end
  end

  defp valid_name(name, coll) when is_binary(name) do
    if Regex.match?(~r|^projects/[a-z][a-z0-9\-]{3,29}/#{coll}/[A-Za-z][A-Za-z0-9\-_.~+%]{2,254}$|, name),
      do: :ok,
      else: err(400, "INVALID_ARGUMENT", "Invalid resource name: #{name}")
  end

  defp valid_name(name, _), do: err(400, "INVALID_ARGUMENT", "Invalid resource name: #{inspect(name)}")

  defp not_found(kind, name), do: err(404, "NOT_FOUND", "#{kind} does not exist: #{name}")
  defp err(http, status, msg), do: {:error, http, status, msg}
end
