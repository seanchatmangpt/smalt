defmodule Smalt.Monitor.AppInsights do
  require Logger
  @moduledoc """
  Azure Application Insights Breeze ingest emulation (v26.10.20 wave-6, lane w6s).

  Wire surface (route handlers in `EgressRouter` on 8443):
  - `POST /v2/track` — Breeze endpoint accepting `{"items": [...]}` where each
    item is `{ver, name, time, iKey?, data: {baseType, baseData}}`. Real AI
    answers 200 with `{"itemsReceived": N, "itemsAccepted": M}` — mirrored
    here (itemsAccepted < itemsReceived when some items are invalid, matching
    the real partial-acceptance semantics; all-invalid -> 400 whole-batch
    refusal, matching the real endpoint's refusal of fully-invalid batches).
  - `GET /v2/track/summary` — emulator-only query face returning recent
    ingested counts by `baseType` (real Breeze has no query face; this is the
    observability witness surface).

  Validation mirrors the real endpoint's minimal contract:
  - missing/non-list `items` -> 400.
  - an item missing `name` or `time` -> that item rejected; if EVERY item is
    invalid the whole batch is a 400 (no partial-write lie).
  - `iKey`: any non-empty string accepted (item-level or envelope-level);
    empty string, or absent at both levels -> item rejected; all-rejected
    batch -> 400 (real AI rejects empty iKey).

  Storage: a private ETS capped ring (cap 10k) with a 3-tuple `:heir` so the
  lazily-created table survives its creating request process (the shadow-table
  silent-disarm class witnessed in v26.10.19).

  r18 (lane S5) additions:
  - `parse_connection_string/1` — the real AI connection-string grammar
    (`InstrumentationKey=...;IngestionEndpoint=https://...;...`) with the
    derived `/v2/track` URL, so a client can wire end-to-end exactly like an
    AI SDK: parse -> POST {IngestionEndpoint}/v2/track.
  - every ACCEPTED item additionally lands in the Log Analytics workspace
    store via `Smalt.Monitor.AppInsightsLa.land/2` (real Sentinel ingest
    face), making Breeze telemetry KQL-queryable at
    `POST /v1/workspaces/:iKey/query`. The landing is a POST-ACK sideband:
    a landing failure logs loudly and leaves the Breeze ack byte-identical
    (real Breeze acks at ingest; the workspace pipeline is async) — absence
    is wire-visible as a KQL query answering zero rows, never a fake ack.
  """

  @table :smalt_ai_items
  @max_items 10_000

  # ---------------------------------------------------------------------------
  # Wire faces
  # ---------------------------------------------------------------------------

  @doc """
  Breeze `POST /v2/track`. Body is the decoded JSON map. Returns
  `{:ok, 200, body_map}` or `{:error, 400, body.message}`.
  """
  @spec track(map()) :: {:ok, 200, map()} | {:error, 400, map()}
  def track(body) when is_map(body) do
    items = Map.get(body, "items")

    if is_list(items) do
      ikey_envelope = ikey_of(body)

      {valid, rejected} = Enum.split_with(items, &valid_item?(&1, ikey_envelope))

      cond do
        items == [] ->
          # Empty items list: real AI answers 200 zero-accept.
          {:ok, 200, ack(length(items), 0, 0)}

        valid == [] ->
          # Every item invalid — real AI rejects the batch outright.
          {:error, 400, bad_request("all items invalid (name/time/iKey required)")}

        true ->
          now = System.system_time(:millisecond)
          Enum.each(valid, &insert(&1, now))
          land_sideband(valid, ikey_envelope)
          {:ok, 200, ack(length(items), length(valid), length(rejected))}
      end
    else
      {:error, 400, bad_request("items array required")}
    end
  end

  def track(_body), do: {:error, 400, bad_request("items array required")}

  # Accepts the track call once the ring insert is done: accepted items land
  # in the Log Analytics workspace store (KQL-queryable). POST-ACK sideband —
  # a failure is logged loudly and NEVER alters the Breeze ack (real Breeze
  # acks at ingest; the workspace pipeline is async). Absence stays
  # wire-visible: the KQL face answers zero rows for the failed landing.
  defp land_sideband(valid, ikey_envelope) do
    case Smalt.Monitor.AppInsightsLa.land(valid, ikey_envelope) do
      {:ok, _stats} ->
        :ok

      {:error, reason} ->
        Logger.warning("AppInsights->LA landing failed (ack unaffected): #{inspect(reason)}")

        :ok
    end
  rescue
    e ->
      Logger.warning(
        "AppInsights->LA landing crashed (ack unaffected): " <> Exception.format(:error, e)
      )

      :ok
  end

  # ---------------------------------------------------------------------------
  # Connection string (real AI SDK grammar)
  # ---------------------------------------------------------------------------

  @doc """
  Parses the real Application Insights connection string:
  `InstrumentationKey=<guid>;IngestionEndpoint=https://...;LiveEndpoint=...;...`
  Semicolon-separated `Key=Value` pairs; `InstrumentationKey` is REQUIRED
  (real SDKs refuse a connection string without it — there is no telemetry
  identity); `IngestionEndpoint` optional (defaults to the public Breeze
  endpoint). Returns `{:ok, %{instrumentation_key, ingestion_endpoint,
  track_url, location}}` or `{:error, message}`.

  `track_url` is the derived POST target `{IngestionEndpoint}v2/track` —
  the exact derivation the real SDKs perform before POSTing Breeze items.
  """
  @spec parse_connection_string(String.t()) :: {:ok, map()} | {:error, String.t()}
  def parse_connection_string(cs) when is_binary(cs) do
    pairs =
      cs
      |> String.split(";", trim: true)
      |> Enum.reduce_while(%{}, fn pair, acc ->
        case :binary.split(pair, "=") do
          [k, v] -> {:cont, Map.put(acc, k, v)}
          _ -> {:halt, :bad_pair}
        end
      end)

    with %{} = pairs <- pairs,
         ikey when is_binary(ikey) and ikey != "" <- pairs["InstrumentationKey"] do
      ingestion = pairs["IngestionEndpoint"] || "https://dc.applicationinsights.microsoft.com/"
      ingestion = if String.ends_with?(ingestion, "/"), do: ingestion, else: ingestion <> "/"

      {:ok,
       %{
         instrumentation_key: ikey,
         ingestion_endpoint: ingestion,
         track_url: ingestion <> "v2/track",
         location: pairs["Location"]
       }}
    else
      :bad_pair -> {:error, "connection string pair without '=': " <> inspect(cs)}
      nil -> {:error, "connection string missing InstrumentationKey"}
      _ -> {:error, "connection string missing InstrumentationKey"}
    end
  end

  def parse_connection_string(_other), do: {:error, "connection string must be a string"}

  @doc "Emulator query face: total + counts of recently ingested items by baseType."
  @spec summary() :: {:ok, map()}
  def summary do
    items = ring_items()

    {:ok,
     %{
       "total" => length(items),
       "counts" => Enum.frequencies_by(items, fn {_k, _ts, item} -> base_type(item) end)
     }}
  end

  @doc "Test/ops helper: number of items currently in the ring."
  @spec size() :: non_neg_integer()
  def size do
    ensure_table()
    :ets.info(@table, :size)
  end

  # ---------------------------------------------------------------------------
  # Storage: private ETS capped ring
  # ---------------------------------------------------------------------------

  defp ring_items do
    ensure_table()

    :ets.tab2list(@table)
    # most recent first
    |> Enum.sort_by(fn {_k, ts, _item} -> ts end, :desc)
  end

  defp ensure_table do
    case :ets.info(@table) do
      :undefined ->
        # 3-tuple heir form: table survives its creating process (shadow-table
        # silent-disarm class, v26.10.19).
        :ets.new(@table, [:set, :named_table, :public, {:heir, Process.whereis(:init), []}])

      _ ->
        :ok
    end
  end

  defp insert(item, now) do
    ensure_table()

    key = {System.unique_integer([:positive, :monotonic]), now}
    :ets.insert(@table, {key, now, item})
    trim_ring()
  end

  defp trim_ring do
    case :ets.info(@table, :size) do
      n when n > @max_items ->
        # Drop the oldest entries past the 10k cap.
        :ets.tab2list(@table)
        |> Enum.sort_by(fn {_k, ts, _} -> ts end)
        |> Enum.take(n - @max_items)
        |> Enum.each(fn {k, _ts, _item} -> :ets.delete(@table, k) end)

      _ ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Validation helpers
  # ---------------------------------------------------------------------------

  defp ack(received, accepted, rejected) do
    %{
      "itemsReceived" => received,
      "itemsAccepted" => accepted,
      "itemsRejected" => rejected
    }
  end

  defp valid_item?(item, ikey_envelope) when is_map(item) do
    is_binary(Map.get(item, "name")) and is_binary(Map.get(item, "time")) and
      (ikey_of(item) || ikey_envelope) not in [nil, ""]
  end

  defp valid_item?(_item, _ikey_envelope), do: false

  # Item-level iKey wins; envelope-level fills in; both absent/empty -> invalid.
  defp ikey_of(item) when is_map(item) do
    case Map.get(item, "iKey") do
      k when is_binary(k) and k != "" -> k
      _ -> nil
    end
  end


  defp base_type(item) do
    case get_in(item, ["data", "baseType"]) do
      t when is_binary(t) and t != "" -> t
      _ -> "trace"
    end
  end

  defp bad_request(msg), do: %{"error" => %{"code" => "BadRequest", "message" => msg}}
end
