defmodule Smalt.AWS.S3 do
  @moduledoc """
  S3 dialect core (AS1): pure functions over an immutable state map, plus
  `Smalt.AWS.S3.Server` (Agent) owning state. Errors:
  `{:error, %{status, code, message}}` using S3 error codes.
  """

  def new, do: %{buckets: %{}, objects: %{}, uploads: %{}, seq: 0}
  def err(status, code, msg), do: {:error, %{status: status, code: code, message: msg}}

  def etag(body), do: "\"" <> (:crypto.hash(:md5, body) |> Base.encode16(case: :lower)) <> "\""
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  def valid_bucket?(n), do: is_binary(n) and Regex.match?(~r/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/, n)

  def create_bucket(st, n) do
    cond do
      not valid_bucket?(n) -> err(400, "InvalidBucketName", "The specified bucket is not valid.")
      st.buckets[n] -> err(409, "BucketAlreadyOwnedByYou", "Your previous request to create the named bucket succeeded and you already own it.")
      true -> {:ok, put_in(st.buckets[n], %{created: now()})}
    end
  end

  def head_bucket(st, n), do: if(st.buckets[n], do: :ok, else: err(404, "NoSuchBucket", "The specified bucket does not exist"))

  def delete_bucket(st, n) do
    with :ok <- head_bucket(st, n) do
      if Enum.any?(st.objects, fn {{b, _}, _} -> b == n end),
        do: err(409, "BucketNotEmpty", "The bucket you tried to delete is not empty"),
        else: {:ok, %{st | buckets: Map.delete(st.buckets, n)}}
    end
  end

  def list_buckets(st), do: st.buckets |> Enum.map(fn {n, b} -> {n, b.created} end) |> Enum.sort()

  @doc "opts: if_match, if_none_match (\"*\" or etag), content_type, meta"
  def put_object(st, b, k, body, opts \\ %{}) do
    with :ok <- head_bucket(st, b),
         :ok <- precondition(st.objects[{b, k}], opts) do
      o = %{body: body, etag: etag(body), size: byte_size(body), modified: now(),
            content_type: opts[:content_type] || "binary/octet-stream", meta: opts[:meta] || %{}}
      {:ok, put_in(st.objects[{b, k}], o), o}
    end
  end

  defp precondition(cur, opts) do
    cond do
      opts[:if_none_match] == "*" and cur != nil -> err(412, "PreconditionFailed", "At least one of the pre-conditions you specified did not hold")
      opts[:if_match] && (cur == nil or cur.etag != opts[:if_match]) ->
        if cur == nil, do: err(404, "NoSuchKey", "The specified key does not exist."), else: err(412, "PreconditionFailed", "At least one of the pre-conditions you specified did not hold")
      true -> :ok
    end
  end

  def get_object(st, b, k) do
    with :ok <- head_bucket(st, b) do
      case st.objects[{b, k}] do
        nil -> err(404, "NoSuchKey", "The specified key does not exist.")
        o -> {:ok, o}
      end
    end
  end

  def delete_object(st, b, k, opts \\ %{}) do
    with :ok <- head_bucket(st, b),
         :ok <- if(opts[:if_match], do: precondition(st.objects[{b, k}], opts), else: :ok) do
      {:ok, %{st | objects: Map.delete(st.objects, {b, k})}}
    end
  end

  @doc "ListObjectsV2: opts prefix, delimiter, max_keys, start_after (continuation token = last key)."
  def list_objects(st, b, opts \\ %{}) do
    with :ok <- head_bucket(st, b) do
      prefix = opts[:prefix] || ""
      after_k = opts[:start_after] || ""
      max = opts[:max_keys] || 1000

      keys =
        for({{^b, k}, o} <- st.objects, String.starts_with?(k, prefix), k > after_k, do: {k, o}) |> Enum.sort_by(&elem(&1, 0))

      {entries, _} =
        Enum.map_reduce(keys, MapSet.new(), fn {k, o}, seen ->
          rest = binary_part(k, byte_size(prefix), byte_size(k) - byte_size(prefix))
          with d when d != nil and d != "" <- opts[:delimiter],
               [head, _] <- String.split(rest, d, parts: 2) do
            cp = prefix <> head <> d
            if MapSet.member?(seen, cp), do: {nil, seen}, else: {{:prefix, cp}, MapSet.put(seen, cp)}
          else
            _ -> {{:object, k, o}, seen}
          end
        end)

      entries = Enum.reject(entries, &is_nil/1)
      truncated = length(entries) > max
      page = Enum.take(entries, max)
      last = case List.last(page) do {:prefix, p} -> p; {:object, k, _} -> k; nil -> nil end
      {:ok, %{entries: page, truncated: truncated, next: if(truncated, do: last)}}
    end
  end

  # ---- multipart ---------------------------------------------------------

  def create_multipart(st, b, k, opts \\ %{}) do
    with :ok <- head_bucket(st, b) do
      id = "upl-" <> Integer.to_string(st.seq + 1)
      {:ok, %{st | seq: st.seq + 1, uploads: Map.put(st.uploads, id, %{b: b, k: k, parts: %{}, opts: opts})}, id}
    end
  end

  def upload_part(st, id, n, body) do
    case st.uploads[id] do
      nil -> err(404, "NoSuchUpload", "The specified upload does not exist.")
      _ when n not in 1..10_000 -> err(400, "InvalidArgument", "Part number must be an integer between 1 and 10000")
      _ -> {:ok, put_in(st.uploads[id].parts[n], body), etag(body)}
    end
  end

  @doc "parts: [{n, etag}] ascending. Non-final parts must be >= 5 MiB unless min_part: 0."
  def complete_multipart(st, id, parts, opts \\ %{}) do
    min_part = Map.get(opts, :min_part, 5 * 1024 * 1024)

    case st.uploads[id] do
      nil -> err(404, "NoSuchUpload", "The specified upload does not exist.")
      u ->
        ns = Enum.map(parts, &elem(&1, 0))

        cond do
          parts == [] or ns != Enum.sort(ns) -> err(400, "InvalidPartOrder", "The list of parts was not in ascending order.")
          Enum.any?(parts, fn {n, e} -> u.parts[n] == nil or etag(u.parts[n]) != e end) -> err(400, "InvalidPart", "One or more of the specified parts could not be found.")
          Enum.any?(Enum.drop(ns, -1), fn n -> byte_size(u.parts[n]) < min_part end) -> err(400, "EntityTooSmall", "Your proposed upload is smaller than the minimum allowed object size.")
          true ->
            body = Enum.map_join(ns, "", &u.parts[&1])
            digest = ns |> Enum.map(fn n -> :crypto.hash(:md5, u.parts[n]) end) |> IO.iodata_to_binary() |> then(&:crypto.hash(:md5, &1)) |> Base.encode16(case: :lower)
            o = %{body: body, etag: "\"#{digest}-#{length(ns)}\"", size: byte_size(body), modified: now(),
                  content_type: u.opts[:content_type] || "binary/octet-stream", meta: %{}}
            {:ok, %{st | objects: Map.put(st.objects, {u.b, u.k}, o), uploads: Map.delete(st.uploads, id)}, o}
        end
    end
  end

  def abort_multipart(st, id) do
    if st.uploads[id], do: {:ok, %{st | uploads: Map.delete(st.uploads, id)}}, else: err(404, "NoSuchUpload", "The specified upload does not exist.")
  end

  defmodule Server do
    @moduledoc "Agent owning S3 state; `update/2` runs a state->{:ok,st,v}|{:error,_} fn atomically."
    use Agent
    def start_link(opts), do: Agent.start_link(&Smalt.AWS.S3.new/0, name: Keyword.fetch!(opts, :name))
    def child_spec(opts), do: %{id: Keyword.fetch!(opts, :name), start: {__MODULE__, :start_link, [opts]}}
    def read(s, f), do: Agent.get(s, f)

    def update(s, f) do
      Agent.get_and_update(s, fn st ->
        case f.(st) do
          {:ok, st2, v} -> {{:ok, v}, st2}
          {:ok, st2} -> {{:ok, nil}, st2}
          {:error, _} = e -> {e, st}
        end
      end)
    end
  end
end
