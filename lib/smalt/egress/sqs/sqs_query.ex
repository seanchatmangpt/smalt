defmodule Smalt.Egress.Sqs.SqsQuery do
  @moduledoc """
  SQS query-protocol form parsing (lane K-SQ).

  - Body-only: boto3 posts `application/x-www-form-urlencoded` bodies with
    `Action=` and `Version=` in the BODY (never the query string), so the
    raw request body is the only parse surface.
  - RFC3986 percent-decoding: botocore encodes per RFC3986 (`%20` for space,
    `%2B` for `+`); a literal `+` in a value stays a plus, never a space
    (unlike `URI.decode_www_form`).
  - Dotted-index lists: SQS query protocol flattens lists as
    `Name.1`, `Name.2`, ... — `list_param/3` gathers and orders them.
  - Nested dotted-index entries (`SendMessageBatchRequestEntry.1.MessageBody`)
    via `entries/2`.
  - `Version=2012-11-05` gate: any other (or missing) version is a typed
    `{:error, :version}` refusal (HTTP 400 envelope).
  """

  @accepted_version "2012-11-05"

  @doc "Parse a raw query-protocol body into a decoded flat map."
  @spec parse(binary()) :: {:ok, map()} | {:error, :version}
  def parse(body) when is_binary(body) do
    params =
      body
      |> String.split("&", trim: true)
      |> Enum.reduce(%{}, fn pair, acc ->
        case String.split(pair, "=", parts: 2) do
          [k, v] -> Map.put(acc, decode(k), decode(v))
          [k] -> Map.put(acc, decode(k), "")
        end
      end)

    case Map.get(params, "Version") do
      @accepted_version -> {:ok, params}
      _ -> {:error, :version}
    end
  end

  def parse(_), do: {:error, :version}

  # RFC3986 percent-decode: `%XX` bytes, `+` literal.
  defp decode(s) when is_binary(s) do
    s
    |> :binary.split("%", [:global])
    |> decode_segments()
  end

  defp decode_segments([first | rest]) do
    Enum.reduce(rest, first, fn seg, acc ->
      case seg do
        <<hex::binary-size(2), tail::binary>> ->
          decoded_hex =
            case Integer.parse(hex, 16) do
              {n, ""} -> <<n>>
              _ -> "%" <> hex
            end

          <<acc::binary, decoded_hex::binary, tail::binary>>

        # trailing bare "%" — keep literally (botocore never sends this)
        _ ->
          <<acc::binary, "%", seg::binary>>
      end
    end)
  end

  @doc """
  Gather a dotted-index list: `list_param(params, "AttributeName")` returns
  `["All"]` for `AttributeName.1=All`, and `[a, b]` for
  `AttributeName.1=a&AttributeName.2=b`. A bare (un-indexed) `Name` key is
  accepted as a one-element list.
  """
  @spec list_param(map(), String.t()) :: [String.t()] | nil
  def list_param(params, base) when is_binary(base) do
    bare = Map.get(params, base)

    indexed =
      params
      |> Enum.filter(fn {k, _} -> dotted_index?(k, base) end)
      |> Enum.sort_by(fn {k, _} -> index_of(k, base) end)
      |> Enum.map(fn {_k, v} -> v end)

    cond do
      indexed != [] -> indexed
      is_binary(bare) and bare != "" -> [bare]
      true -> nil
    end
  end

  @doc """
  Nested dotted-index entries: `entries(params, "SendMessageBatchRequestEntry")`
  returns `[%{"Id" => .., "MessageBody" => ..}, ..]` ordered by index. Entries
  without an `Id` are dropped (typed partial-failure contract decides errors).
  """
  @spec entries(map(), String.t()) :: [map()]
  def entries(params, prefix) when is_binary(prefix) do
    dot = prefix <> "."

    params
    |> Enum.flat_map(fn {k, v} ->
      if String.starts_with?(k, dot) do
        rest = String.slice(k, byte_size(dot)..-1//1)

        case String.split(rest, ".", parts: 2) do
          [i, suffix] -> [{parse_index(i), suffix, v}]
          _ -> []
        end
      else
        []
      end
    end)
    |> Enum.group_by(fn {i, _s, _v} -> i end)
    |> Enum.sort_by(fn {i, _} -> i end)
    |> Enum.map(fn {_i, kvs} ->
      Map.new(kvs, fn {_i, suffix, v} -> {suffix, v} end)
    end)
    |> Enum.reject(&is_nil(&1["Id"]))
  end

  @doc ~S(Raw param fetch with integer parse: `{n, ""}` else nil.)
  @spec int_param(map(), String.t()) :: non_neg_integer() | nil
  def int_param(params, key) do
    case Map.get(params, key) do
      v when is_binary(v) ->
        case Integer.parse(v) do
          {n, ""} -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp dotted_index?(k, base) do
    String.starts_with?(k, base <> ".") and
      match?({_n, ""}, Integer.parse(String.slice(k, byte_size(base) + 1..-1//1)))
  end

  defp index_of(k, base), do: parse_index(String.slice(k, byte_size(base) + 1..-1//1))

  defp parse_index(i) do
    case Integer.parse(i) do
      {n, ""} -> n
      _ -> 0
    end
  end
end
