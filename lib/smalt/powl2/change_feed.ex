defmodule Smalt.POWL2.ChangeFeed do
  @batch_limit 50
  @moduledoc """
  POWL-7 (v26.10.19): in-memory CAS document store + zero-lease change feed
  (DFLSS FR-3.1).

  Layout: an ETS `:set` of documents (`{{pk, id}, etag, seq, body}`), an ETS
  `:ordered_set` CDC log (`{seq, op, pk, id, etag}`), and an `:atomics`
  sequence counter. `put_item/5` implements If-Match CAS semantics (201
  create / 200 upsert-or-match / 412 stale precondition carrying the current
  etag / 404 missing-with-If-Match). Every mutation pushes
  `{:cdc_watermark, seq}` to the subscriber; a `:gen_statem`
  (`:idle`/`:draining`, backpressure pause flag) drains
  `{:cdc_batch, from, to, events}` of at most #{@batch_limit} events in seq
  order by offset — push, never polling.

  The etag renderer is the repo's existing dashed RFC-4122 v4 GUID minter
  (`Smalt.Egress.KvRoutes.guid_version/0`) — no duplicated GUID dialect.
  """

  @behaviour :gen_statem

  alias Smalt.Egress.KvRoutes

  @default_base :powl2_change_feed
    @seq_index 1

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Starts a store + feed pair on private (unnamed) heir'd tables; `base` names the statem."
  def start_link(opts \\ []) do
    base = Keyword.get(opts, :base, @default_base)
    :gen_statem.start_link({:local, base}, __MODULE__, base, [])
  end

  @doc """
  CAS put. `opts[:if_match]` is `nil` (create/upsert) or an etag string.

  Returns `{:ok, 201, etag}` (create), `{:ok, 200, etag}` (upsert/match),
  `{:error, 412, current_etag}` (stale etag), or `{:error, 404, nil}`
  (if_match on a missing doc).
  """
  def put_item(server, pk, id, body, opts \\ []) do
    :gen_statem.call(server, {:put, pk, id, body, Keyword.get(opts, :if_match)})
  end

  @doc "Current doc etag, or nil when absent."
  @spec etag(pid() | atom(), term(), term()) :: String.t() | nil
  def etag(server, pk, id) do
    case :gen_statem.call(server, {:get_etag, pk, id}) do
      nil -> nil
      etag when is_binary(etag) -> etag
    end
  end

  @doc "Subscribes `pid` (default self()) to watermark pushes + CDC batches."
  def subscribe(server, pid \\ self()) do
    :gen_statem.call(server, {:subscribe, pid})
  end

  @doc "Backpressure: hold CDC batch delivery (watermarks still push)."
  def pause(server), do: :gen_statem.call(server, :pause)

  @doc "Release a paused feed; held batches drain on resume."
  def resume(server), do: :gen_statem.call(server, :resume)

  @doc "Monotonic CDC sequence (high watermark)."
  def watermark(server), do: :gen_statem.call(server, :watermark)

  @doc "Maximum entries per drained CDC batch."
  def batch_limit, do: @batch_limit

  # ---------------------------------------------------------------------------
  # :gen_statem callbacks (handle_event_function; states :idle / :draining)
  # ---------------------------------------------------------------------------

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(_base) do
    # SPOF-B / A-4d + A-6: tables are UNNAMED (tids held in the statem state).
    # Previously atom-minting interpolation of the caller `base` produced the
    # table names (unfiled exception to the frame_codec atom law). No external
    # surface reads these tables by name (all access rides the statem API /
    # the tid in state), so named tables carried atom-mint risk with zero
    # reachability benefit. Zero new atoms minted, ever.
    docs =
      :ets.new(:smalt_powl2_change_feed_docs, [
        :set,
        :public,
        read_concurrency: true,
        heir: Process.whereis(:init) || self()
      ])

    cdc =
      :ets.new(:smalt_powl2_change_feed_cdc, [
        :ordered_set,
        :public,
        read_concurrency: true,
        heir: Process.whereis(:init) || self()
      ])

    seq = :atomics.new(1, signed: false)
    data = cdc_meta(docs, cdc, seq)
    {:ok, :idle, data}
  end

  # Heir law for a per-instance (non-singleton) service: the heir saves the
  # tables only from CRASH deaths (:kill / raise — terminate/3 does not run).
  # On a NORMAL stop, terminate/3 deletes the tables first, so no :init-heir
  # transfer leaks a stopped instance's tables for the node lifetime.
  @impl true
  def terminate(_reason, _state, data) do
    :ets.delete(data.docs)
    :ets.delete(data.cdc)
    :ok
  end

  defp cdc_meta(docs, cdc, seq) do
    %{docs: docs, cdc: cdc, seq: seq, sub: nil, paused: false, last_sent: 0}
  end

  # -- CAS put (serialized through the statem: race-free check-then-write) ----

  @impl true
  def handle_event({:call, from}, {:put, pk, id, body, if_match}, _state, data) do
    case cas_put(data, pk, id, body, if_match) do
      {:mutated, reply, _etag, seq} ->
        notify_watermark(data.sub, seq)
        {:keep_state_and_data, [{:reply, from, reply}, {:next_event, :internal, :drain}]}

      {:unchanged, reply} ->
        {:keep_state_and_data, [{:reply, from, reply}]}
    end
  end

  @impl true
  def handle_event({:call, from}, {:get_etag, pk, id}, _state, data) do
    reply =
      case :ets.lookup(data.docs, {pk, id}) do
        [{{^pk, ^id}, etag, _seq, _body}] -> etag
        [] -> nil
      end

    {:keep_state_and_data, [{:reply, from, reply}]}
  end

  @impl true
  def handle_event({:call, from}, {:subscribe, pid}, _state, data) when is_pid(pid) do
    Process.monitor(pid)
    {:keep_state, %{data | sub: pid}, [{:reply, from, :ok}, {:next_event, :internal, :drain}]}
  end

  @impl true
  def handle_event({:call, from}, :pause, _state, data) do
    {:keep_state, %{data | paused: true}, [{:reply, from, :ok}]}
  end

  @impl true
  def handle_event({:call, from}, :resume, _state, data) do
    {:keep_state, %{data | paused: false}, [{:reply, from, :ok}, {:next_event, :internal, :drain}]}
  end

  @impl true
  def handle_event({:call, from}, :watermark, _state, data) do
    {:keep_state_and_data, [{:reply, from, :atomics.get(data.seq, @seq_index)}]}
  end

  # -- Drain loop: ordered_set select, limit 50, offset-advanced last_sent ----

  @impl true
  def handle_event(:internal, :drain, _state, %{paused: true} = data) do
    # Backpressure pause flag: hold delivery (do not advance last_sent).
    {:next_state, :idle, data}
  end

  def handle_event(:internal, :drain, _state, %{sub: nil} = data) do
    {:next_state, :idle, data}
  end

  def handle_event(:internal, :drain, _state, data) do
    ms = [
      {{:"$1", :"$2", :"$3", :"$4", :"$5"},
       [{:is_integer, :"$1"}, {:">", :"$1", data.last_sent}],
       [{{:"$1", :"$2", :"$3", :"$4", :"$5"}}]}
    ]

    case :ets.select(data.cdc, ms, @batch_limit) do
      {events, _cont} when events != [] ->
        from = events |> hd() |> elem(0)
        to = events |> List.last() |> elem(0)
        send(data.sub, {:cdc_batch, from, to, events})
        data2 = %{data | last_sent: to}

        if to < :atomics.get(data.seq, @seq_index) do
          {:next_state, :draining, data2, [{:next_event, :internal, :drain}]}
        else
          {:next_state, :idle, data2}
        end

      _ ->
        {:next_state, :idle, data}
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp cas_put(data, pk, id, body, nil) do
    key = {pk, id}

    case :ets.lookup(data.docs, key) do
      [] ->
        {etag, seq} = insert_doc(data, key, etag_new(), body)
        {:mutated, {:ok, 201, etag}, etag, seq}

      [{{^pk, ^id}, _old_etag, _old_seq, _old_body}] ->
        {etag, seq} = insert_doc(data, key, etag_new(), body)
        {:mutated, {:ok, 200, etag}, etag, seq}
    end
  end

  defp cas_put(data, pk, id, body, if_match) do
    key = {pk, id}

    case :ets.lookup(data.docs, key) do
      [] ->
        {:unchanged, {:error, 404, nil}}

      [{{^pk, ^id}, current_etag, _seq, _body}] ->
        if current_etag == if_match do
          {etag, seq} = insert_doc(data, key, etag_new(), body)
          {:mutated, {:ok, 200, etag}, etag, seq}
        else
          {:unchanged, {:error, 412, current_etag}}
        end
    end
  end

  defp insert_doc(data, key, etag, body) do
    seq = :atomics.add_get(data.seq, @seq_index, 1)
    :ets.insert(data.docs, {key, etag, seq, body})
    :ets.insert(data.cdc, {seq, :put, elem(key, 0), elem(key, 1), etag})
    {etag, seq}
  end

  defp notify_watermark(sub, seq) when is_pid(sub), do: send(sub, {:cdc_watermark, seq})
  defp notify_watermark(_sub, _seq), do: :ok

  # Reuses the canonical dashed-36 RFC-4122 v4 renderer from the KV surface.
  defp etag_new, do: KvRoutes.guid_version()
end
