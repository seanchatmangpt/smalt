defmodule Smalt.DataPlane.ResourceGraph do
  @moduledoc """
  Azure Resource Graph (`POST /providers/Microsoft.ResourceGraph/resources`) query
  engine over the Store resource inventory `:smalt_resources`, with opaque
  `$skipToken` pagination backed by `:smalt_resource_graph_tokens`.

  Wire surface (route handler in `EgressRouter` mounts on 8443):
  `POST /providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01` -> `query/3`
  """

  alias Smalt.DataPlane.KQL
  alias Smalt.Store

  @api_version "2022-10-01"
  @default_top 100
  # Real Resource Graph server cap: resultTruncated=true means "results may be
  # incomplete due to server limits" — only a hit on this cap truncates.
  @server_cap 1000

  @doc """
  Runs a Resource Graph query over the resource inventory for `subscriptions`
  (list of subscription ids; `nil` = all).

  Returns `{:ok, 200, body}`; body carries `count`, `data`, `totalRecords`,
  `resultTruncated: true` only when the filtered set exceeds the server record
  cap (results are then truncated to the cap), and `$skipToken` only when more
  pages remain (normal pagination does NOT truncate).
  `{:error, 400, body}` when the api-version is wrong.
  """
  def query(subscriptions, body, @api_version) do
    try do
      do_query(subscriptions, body)
    catch
      {:bad_query, msg} ->
        {:error, 400, %{"error" => %{"code" => "BadQuery", "message" => msg}}}
    end
  end

  def query(_subscriptions, _body, _other) do
    {:error, 400,
     %{"error" => %{"code" => "InvalidApiVersion", "message" => "api-version must be #{@api_version}"}}}
  end

  defp do_query(subscriptions, body) do
    body = body || %{}
    options = Map.get(body, "options") || %{}
    top = options |> Map.get("$top") |> parse_int() |> Kernel.||(Map.get(body, "$top")) |> parse_int() |> Kernel.||(@default_top) |> max(1)
    skip = options |> Map.get("$skip") |> parse_int() |> Kernel.||(Map.get(body, "$skip")) |> parse_int() |> Kernel.||(0)

    {offset, facets_subscriptions} =
      case skip_token(body, options) do
        nil ->
          {skip, subscriptions}

        token when is_binary(token) ->
          case Store.get(:smalt_resource_graph_tokens, token) do
            {:ok, %{"offset" => offset, "subscriptions" => subs}} -> {offset, subs}
            :error -> {skip, subscriptions}
          end

        _ ->
          {skip, subscriptions}
      end

    all =
      facets_subscriptions
      |> matching_resources()
      |> apply_kql(Map.get(body, "query"))

    truncated = length(all) > @server_cap
    all = if truncated, do: Enum.take(all, @server_cap), else: all
    total = length(all)

    page = Enum.slice(all, offset, top)
    remaining = total - (offset + length(page))

    response =
      %{
        "count" => length(page),
        "data" => page,
        "totalRecords" => total,
        "resultTruncated" => truncated
      }

    response =
      if remaining > 0 do
        token = new_token(offset + length(page), facets_subscriptions)
        Map.put(response, "$skipToken", token)
      else
        response
      end

    {:ok, 200, response}
  end

  # Real API carries the token in options.$skipToken; the flat "skiptoken"
  # form is kept as a fallback.
  defp skip_token(body, options) do
    options["$skipToken"] || body["skiptoken"] || body["$skipToken"]
  end

  # Applies the optional KQL `where`/`order by`/`project` pipeline from the
  # request's `query` field to the resource rows, before pagination. A bare
  # `where ...` (no leading `|`, the Resource Graph convention) is normalized.
  # Parse/limit errors surface as `{:error, 400, BadQuery}`.
  defp apply_kql(rows, query) when is_binary(query) and query != "" do
    case normalize_pipeline(query) do
      nil ->
        rows

      pipeline ->
        case KQL.run(rows, pipeline) do
          {:ok, rows} -> rows
          {:error, {_kind, msg}} -> throw({:bad_query, msg})
        end
    end
  end

  defp apply_kql(rows, _query), do: rows

  # A bare pipeline ("| where ...") is passed through; a bare query starting
  # with a pipeline keyword is normalized ("where x" -> "| where x"); any
  # other bare word is a table reference (e.g. "Resources") and filters
  # nothing — previously it was force-prefixed with "|", making KQL reject it
  # as an unknown pipeline keyword (400 BadQuery regression).
  defp normalize_pipeline(query) do
    if String.contains?(query, "|") do
      query
    else
      first = query |> String.split() |> List.first()

      if first in ["where", "order", "project", "take"] do
        "| " <> query
      else
        nil
      end
    end
  end

  defp matching_resources(nil), do: Store.list(:smalt_resources)

  defp matching_resources(subscriptions) when is_list(subscriptions) do
    subs = MapSet.new(subscriptions)

    Store.list(:smalt_resources)
    |> Enum.filter(fn r -> MapSet.member?(subs, subscription_of(r)) end)
  end

  # The subscription filter is derived from the resource id itself
  # (`/subscriptions/{sub}/...`) when the stored record carries no explicit
  # "subscriptionId" — the router's resource PUT stores no such field, and a
  # missing value would otherwise silently empty every subscription-filtered
  # query.
  defp subscription_of(%{"subscriptionId" => sub}) when is_binary(sub), do: sub

  defp subscription_of(%{"id" => "/subscriptions/" <> rest}) do
    [sub | _] = String.split(rest, "/")
    String.downcase(sub)
  end

  defp subscription_of(_), do: nil

  defp parse_int(nil), do: nil

  defp parse_int(v) when is_integer(v), do: v

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  defp new_token(offset, subscriptions) do
    token =
      :crypto.strong_rand_bytes(12)
      |> Base.encode16(case: :lower)

    Store.put(:smalt_resource_graph_tokens, token, %{
      "offset" => offset,
      "subscriptions" => subscriptions,
      "created" => DateTime.utc_now() |> DateTime.to_iso8601()
    })

    token
  end
end
