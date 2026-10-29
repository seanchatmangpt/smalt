defmodule Smalt.DataPlane.CosmosFeeds do
  @moduledoc """
  Cosmos DB read-feed option parity (lane w6ai, wave-6 v26.10.20): additive
  wrappers over the existing cosmos query-engine result sets — the engine
  itself is untouched.

  Surface:

    - `x-ms-max-item-count` — page size cap (Azure caps at 1000; the surface
      refuses values outside 1..1000 with a typed 400; this module clamps
      for internal callers).
    - `x-ms-continuation` — opaque, version-tagged base64url token encoding
      `{version, index}`. Echo `x-ms-continuation-continuation` on the
      response when more items remain; absent when exhausted (Azure parity).
      A garbage/stale token is a typed refusal (400), never a silent feed
      restart.
    - `If-Modified-Since` — RFC1123 date filter on doc `_ts` (docs changed
      AT-or-AFTER the instant are kept, per Azure); malformed header →
      `{:error, :bad_request}` (typed 400 at the surface).

  Pure module-level functions; no routes here. Surface exposure (post
  router-split) is 3-5 lines at the query/list arms.
  """

  @max_item_count_cap 1000
  @token_version 3

  @type continuation :: String.t() | nil

  @doc """
  Paginate an already-materialized doc set. Returns
  `{:ok, page, next_continuation}` — `next_continuation` is `nil` when the
  feed is exhausted. `max_item_count` is clamped to 1..1000 for internal
  callers.
  """
  @spec paginate_doc_set([map()], integer() | nil, continuation()) ::
          {:ok, [map()], continuation()} | {:error, :invalid_continuation}
  def paginate_doc_set(docs, max_item_count, continuation) do
    max = clamp_count(max_item_count)

    case decode_continuation(continuation) do
      {:error, :invalid} ->
        {:error, :invalid_continuation}

      start_index ->
        page = Enum.slice(docs, start_index, max)
        consumed = start_index + length(page)

        next =
          if consumed < length(docs) do
            encode_continuation({@token_version, consumed})
          else
            nil
          end

        {:ok, page, next}
    end
  end

  @doc """
  Filter docs changed AT-or-AFTER `since` (`_ts >= instant`, Azure parity).
  """
  @spec mod_since_filter([map()], DateTime.t()) :: [map()]
  def mod_since_filter(docs, %DateTime{} = since) do
    cutoff = DateTime.to_unix(since, :second)
    Enum.filter(docs, fn doc -> doc_ts(doc) >= cutoff end)
  end

  @doc """
  Parse an If-Modified-Since request header (RFC1123). `{:ok, nil}` for
  absent/empty; `{:error, :bad_request}` on malformed.
  """
  @spec mod_since(String.t() | nil) :: {:ok, DateTime.t() | nil} | {:error, :bad_request}
  def mod_since(nil), do: {:ok, nil}

  def mod_since(header) when is_binary(header) do
    trimmed = String.trim(header)

    if trimmed == "" do
      {:ok, nil}
    else
      case :httpd_util.convert_request_date(String.to_charlist(trimmed)) do
        {{_y, _mo, _d}, {_h, _mi, _s}} = date ->
          parse_ok(date)

        :bad_date ->
          {:error, :bad_request}
      end
    end
  end

  defp parse_ok({{y, mo, d}, {h, mi, s}}) do
    case DateTime.new(Date.new!(y, mo, d), Time.new!(h, mi, s), "Etc/UTC") do
      {:ok, dt} -> {:ok, dt}
      _ -> {:error, :bad_request}
    end
  end

  defp doc_ts(doc) when is_map(doc) do
    case doc["_ts"] do
      ts when is_integer(ts) -> ts
      _ -> 0
    end
  end

  defp clamp_count(nil), do: @max_item_count_cap
  defp clamp_count(n) when is_integer(n) and n > @max_item_count_cap, do: @max_item_count_cap
  defp clamp_count(n) when is_integer(n) and n < 1, do: 1
  defp clamp_count(n) when is_integer(n), do: n
  defp clamp_count(_), do: @max_item_count_cap

  defp encode_continuation({v, i}) do
    :erlang.term_to_binary({v, i})
    |> Base.url_encode64(padding: false)
  end

  defp decode_continuation(nil), do: 0

  defp decode_continuation(token) when is_binary(token) do
    with {:ok, bin} <- Base.url_decode64(token, padding: false),
         {:ok, {v, i}} when is_integer(i) and i >= 0 <-
           try_safe_term(bin) do
      if v == @token_version, do: i, else: {:error, :invalid}
    else
      _ -> {:error, :invalid}
    end
  end

  defp try_safe_term(bin) do
    try do
      {:ok, :erlang.binary_to_term(bin, [:safe])}
    rescue
      _ -> :error
    end
  end

  @doc "Capped max-item-count for a raw header value (w6ai probe helper)."
  def max_item_count_cap, do: @max_item_count_cap
end
