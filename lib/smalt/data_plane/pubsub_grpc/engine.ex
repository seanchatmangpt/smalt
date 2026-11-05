defmodule Smalt.PubSubGrpc.Engine do
  @moduledoc """
  Pub/Sub engine (lane K-GC): registry + durable delivery over the AoQ log.

  ## Topology

    * One Engine GenServer serializes registry CRUD + delivery state
      (emulator-grade; the wire face is the concurrency boundary).
    * Topics/subscriptions registry persists via DETS
      (`tmp/pubsub_registry.dets`, config `:smalt, :pubsub_registry_dir`),
      restart-persistent across Engine restarts. KD row: the registry is
      DETS, not a Store-ensemble table — `store_tables.ex` is
      ontology-generated (DO NOT EDIT; replay-identity-fenced), so this
      lane cannot mint Store tables without an ontology row.
    * Messages store via `Smalt.Aoq.Storage.append(0x50, frame)` under the
      shared AoQ log topic (`:smalt, :aoq_log_topic`), partition byte
      0x50. The stored frame wraps the client bytes:
      `<<topic_len::16, topic, wire-encoded PubsubMessage>>` — the client
      `data` bytes ride field 1 byte-exact (F-P1 parity court).
    * Per-subscription durable cursor = `Smalt.Aoq.Cursor` +
      `Smalt.Aoq.CursorPersist` composition (read-only composition, per
      lane law): `tail` = committed (acked) count, checkpointed to the
      journal so offsets survive restart (F-P3).
  """

  use GenServer

  alias Smalt.Aoq.Cursor
  alias Smalt.Aoq.CursorPersist
  alias Smalt.Aoq.Storage
  alias Smalt.PubSubGrpc.Wire

  @pubsub_frame_type 0x50
  @dets "pubsub_registry.dets"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  ## ── client API ─────────────────────────────────────────────────────

  def publish(topic_name, messages) when is_binary(topic_name) and is_list(messages) do
    GenServer.call(__MODULE__, {:publish, topic_name, messages}, 15_000)
  end

  def pull(sub_name, max_messages, return_immediately) do
    GenServer.call(__MODULE__, {:pull, sub_name, max_messages, return_immediately}, 15_000)
  end

  def acknowledge(sub_name, ack_ids) do
    GenServer.call(__MODULE__, {:ack, sub_name, ack_ids}, 15_000)
  end

  def modify_ack_deadline(sub_name, ack_ids, 0 = _deadline) do
    GenServer.call(__MODULE__, {:nack, sub_name, ack_ids}, 15_000)
  end

  def modify_ack_deadline(sub_name, ack_ids, deadline)
      when is_integer(deadline) and deadline > 0 do
    # Lease extension beyond 0 is a graded deferral (KD row): the emulator
    # pins deadline 0 (nack) and refuses extensions UNIMPLEMENTED(12).
    {:grpc_error, 12, "ack deadline > 0 (lease extension) is not implemented"}
  end

  def modify_ack_deadline(_sub, _acks, deadline) when is_integer(deadline) do
    {:grpc_error, 3, "invalid ack_deadline_seconds"}
  end

  def create_topic(name), do: GenServer.call(__MODULE__, {:create_topic, name}, 15_000)
  def get_topic(name), do: GenServer.call(__MODULE__, {:get_topic, name}, 15_000)
  def get_subscription(name), do: GenServer.call(__MODULE__, {:get_subscription, name}, 15_000)

  ## ── GenServer ─────────────────═════════════════════════════════════

  @impl true
  def init(_opts) do
    dir = registry_dir()
    File.mkdir_p!(dir)
    {:ok, dets} = :dets.open_file(String.to_charlist(Path.join(dir, @dets)), repair: true)

    subs =
      :dets.match_object(dets, {:sub, :"$1", :"$2"})
      |> Enum.map(fn {:sub, name, topic} -> {name, new_sub(name, topic)} end)
      |> Map.new()

    topics =
      :dets.match_object(dets, {:topic, :"$1"})
      |> Enum.map(fn {:topic, name} -> {name, %{name: name}} end)
      |> Map.new()

    {:ok, %{dets: dets, subs: subs, topics: topics}}
  end

  defp new_sub(name, topic) do
    cursor = Cursor.new()
    dir = Path.join(registry_dir(), "sub-" <> name)
    sink_name = {:global, {:pubsub_sink, dir}}
    persist_name = {:global, {:pubsub_cp, dir}}

    # per-sub journal sink (matter scope "aoq" under the sub's dir) —
    # unique :global names so subs never collide and the sink outlives
    # no one: it is stopped with the persist (Engine.terminate).
    sink =
      case Smalt.Storage.JournalSink.start_link(name: sink_name, dir: dir) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    persist =
      case CursorPersist.start_link(cursor: cursor, dir: dir, sink: sink_name) do
        {:ok, pid} ->
          pid

        {:error, {:already_started, old}} ->
          GenServer.stop(old, :normal)
          {:ok, pid} = CursorPersist.start_link(cursor: cursor, dir: dir, sink: sink_name)
          pid
      end

    %{name: name, topic: topic, cursor: cursor, persist: persist, sink: sink}
  end

  defp registry_dir do
    Application.get_env(:smalt, :pubsub_registry_dir, "tmp/pubsub")
  end

  ## ── handle_call ────────────────────────────────────────────────────

  @impl true
  def handle_call({:create_topic, name}, _from, st) when is_binary(name) and name != "" do
    case st.topics do
      %{^name => _} ->
        {:reply, {:grpc_error, 6, "topic already exists"}, st}

      _ ->
        :dets.insert(st.dets, {:topic, name})
        :dets.sync(st.dets)
        {:reply, {:ok, %{name: name}}, %{st | topics: Map.put(st.topics, name, %{name: name})}}
    end
  end

  def handle_call({:get_topic, name}, _from, st) do
    case st.topics do
      %{^name => _} -> {:reply, {:ok, %{name: name}}, st}
      _ -> {:reply, {:grpc_error, 5, "topic not found"}, st}
    end
  end

  def handle_call({:get_subscription, name}, _from, st) do
    case st.subs do
      %{^name => sub} -> {:reply, {:ok, %{name: sub.name, topic: sub.topic}}, st}
      _ -> {:reply, {:grpc_error, 5, "subscription not found"}, st}
    end
  end

  # Auto-create the subscription when referenced (grpcio's Subscriber
  # client requires an existing subscription; tests create via the admin
  # API helper below).
  def handle_call({:ensure_sub, name, topic}, _from, st) do
    cond do
      not Map.has_key?(st.topics, topic) ->
        {:reply, {:grpc_error, 5, "topic not found"}, st}

      Map.has_key?(st.subs, name) ->
        {:reply, {:ok, %{name: name, topic: topic}}, st}

      true ->
        sub = new_sub(name, topic)
        :dets.insert(st.dets, {:sub, name, topic})
        :dets.sync(st.dets)
        {:reply, {:ok, %{name: name, topic: topic}},
         %{st | subs: Map.put(st.subs, name, sub)}}
    end
  end

  @impl true
  def handle_call({:publish, topic_name, messages}, _from, st) do
    case st.topics do
      %{^topic_name => _} ->
        ids = Enum.map(messages, fn _ -> new_message_id() end)
        now = publish_time()

        frames =
          Enum.zip(messages, ids)
          |> Enum.map(fn {msg, id} ->
            wire_msg =
              Wire.encode_pubsub_message(%{
                data: msg[:data] || <<>>,
                attributes: msg[:attributes] || %{},
                message_id: id,
                publish_time: now,
                ordering_key: msg[:ordering_key]
              })

            topic_bin = topic_name
            <<byte_size(topic_bin)::size(16), topic_bin::binary, wire_msg::binary>>
          end)

        results =
          Enum.map(frames, fn frame ->
            case Storage.append(@pubsub_frame_type, frame) do
              {:ok, _offset} -> :ok
              {:error, reason} -> {:error, reason}
            end
          end)

        case Enum.find(results, &match?({:error, _}, &1)) do
          nil ->
            {:reply, {:ok, ids}, st}

          {:error, reason} ->
            {:reply, {:grpc_error, 13, "storage append failed: #{inspect(reason)}"}, st}
        end
    end
  end

  defp new_message_id do
    "pubsub-" <> node_str() <> "-" <> Integer.to_string(:erlang.unique_integer([:monotonic, :positive]))
  end

  defp node_str, do: node() |> :erlang.atom_to_binary() |> Base.encode16(case: :lower) |> binary_part(0, 8)

  defp publish_time do
    now = System.system_time(:second)
    {now, 0}
  end

  ## ── delivery ───────────────────────────────────────────────────────

  # Pull delivers from the COMMITTED count (cursor tail): unacked messages
  # are redelivered on the next pull (F-P1), the durable cursor advances
  # ONLY on Acknowledge (F-P3). `return_immediately` is accepted and
  # ignored (pinned in the wire spec; KD row).
  def handle_call({:pull, sub_name, max_messages, _return_immediately}, _from, st) do
    case st.subs do
      %{^sub_name => sub} ->
        tail = Cursor.tail(sub.cursor)
        n = if max_messages <= 0, do: 10, else: max_messages

        received =
          topic_frames(sub.topic)
          |> Enum.drop(tail)
          |> Enum.take(n)
          |> Enum.with_index(tail)
          |> Enum.map(fn {frame, idx} ->
            %{ack_id: ack_id(sub_name, idx), message: frame}
          end)

        # head claims = deliveries (lease bookkeeping)
        Enum.each(1..length(received), fn _ -> Cursor.claim_head(sub.cursor) end)

        {:reply, {:ok, received}, st}

      _ ->
        {:reply, {:grpc_error, 5, "subscription not found"}, st}
    end
  end

  # Acknowledge: validate + commit the contiguous acked prefix into the
  # durable cursor (release_tail), checkpointed by CursorPersist (note_
  # release). Offsets are sub-local delivery indices, not storage offsets.
  def handle_call({:ack, sub_name, ack_ids}, _from, st) do
    case st.subs do
      %{^sub_name => sub} ->
        offsets =
          ack_ids
          |> Enum.map(&decode_ack_id/1)
          |> Enum.map(fn
            {:ok, {^sub_name, idx}} -> idx
            _ -> :bad
          end)

        if :bad in offsets do
          {:reply, {:grpc_error, 3, "invalid ack_id"}, st}
        else
          commit_acks(sub, Enum.sort(Enum.uniq(offsets)))
          {:reply, :ok, st}
        end

      _ ->
        {:reply, {:grpc_error, 5, "subscription not found"}, st}
    end
  end

  # deadline 0 → nack: return-to-delivery. Delivery comes from the tail,
  # so a nack is a no-op on committed state — the message is redelivered
  # on the next pull by construction.
  def handle_call({:nack, _sub_name, _ack_ids}, _from, st), do: {:reply, :ok, st}

  defp commit_acks(_sub, []), do: :ok

  # Commit the contiguous acked run starting at the tail (in-order ack
  # commit law — KD row: out-of-order acks stay pending, redelivered).
  defp commit_acks(sub, sorted_offsets) do
    actual = count_contiguous_prefix(sorted_offsets, Cursor.tail(sub.cursor))

    if actual > 0 do
      Enum.each(1..actual, fn _ -> Cursor.release_tail(sub.cursor) end)
      CursorPersist.note_release(sub.persist, actual)
      # sync flush: ack is the durability point for this face
      _ = CursorPersist.flush(sub.persist)
    end

    :ok
  end

  defp count_contiguous_prefix(sorted, tail) do
    sorted
    |> Enum.reduce_while(tail, fn idx, expect ->
      if idx == expect, do: {:cont, expect + 1}, else: {:halt, expect}
    end)
    |> then(&(&1 - tail))
  end

  # All frames of one pubsub topic in delivery order: {offset, msg}.
  defp topic_frames(topic_name) do
    case Storage.fetch(Storage.topic(), 0) do
      {:ok, entries} ->
        for %{frame_type: @pubsub_frame_type, payload: payload} <- entries,
            frame = decode_frame(payload),
            frame != nil,
            frame.topic == topic_name do
          frame
        end

      _ ->
        []
    end
  end

  defp decode_frame(<<len::size(16), topic::binary-size(len), wire_msg::binary>>) do
    case Wire.decode_pubsub_message(wire_msg) do
      {:ok, msg, _} -> Map.put(msg, :topic, topic)
      _ -> nil
    end
  end

  defp decode_frame(_), do: nil

  defp ack_id(sub_name, idx) do
    :erlang.term_to_binary({sub_name, idx})
    |> Base.url_encode64(padding: false)
  end

  defp decode_ack_id(b64) do
    case Base.url_decode64(b64, padding: false) do
      {:ok, bin} ->
        {:ok, :erlang.binary_to_term(bin, [:safe])}

      _ ->
        :bad
    end
  end

  @impl true
  def terminate(_reason, st) do
    # graceful restart path: flush + seal per-sub journals so the next boot
    # folds the durable tails (CursorPersist folds sealed segments only).
    Enum.each(st.subs, fn {_name, sub} ->
      _ = CursorPersist.flush(sub.persist)
      _ = Smalt.Storage.JournalSink.seal(sub.sink)
      GenServer.stop(sub.persist, :normal)
      GenServer.stop(sub.sink, :normal)
    end)

    :ok
  end

  ## ── test/admin helpers ─────────────────────────────────────────────

  @doc "Admin/test helper: create `sub` on `topic` (auto-create law)."
  def ensure_subscription(name, topic), do: GenServer.call(__MODULE__, {:ensure_sub, name, topic}, 15_000)
end
