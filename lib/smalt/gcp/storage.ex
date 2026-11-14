defmodule Smalt.GCP.Storage do
  @moduledoc """
  Google Cloud Storage dialect core (GS1): pure functions over an immutable
  state map. No process, no I/O. `Smalt.GCP.Storage.Server` owns the state;
  `Smalt.GCP.Storage.Router` is the wire face.

  Errors are typed: `{:error, %{status: int, reason: String.t(), message: String.t()}}`
  with GCS reason vocabulary (`notFound`, `conflict`, `conditionNotMet`, `invalid`).
  """

  @type state :: %{
          gen: non_neg_integer(),
          buckets: map(),
          objects: map(),
          uploads: map()
        }

  def new, do: %{gen: 0, buckets: %{}, objects: %{}, uploads: %{}}

  def err(status, reason, message), do: {:error, %{status: status, reason: reason, message: message}}

  # ---- buckets -----------------------------------------------------------

  def create_bucket(st, name, opts \\ %{}) do
    cond do
      not valid_bucket?(name) -> err(400, "invalid", "Invalid bucket name: #{inspect(name)}")
      Map.has_key?(st.buckets, name) -> err(409, "conflict", "You already own this bucket. Please select another name.")
      true ->
        {st, g} = bump(st)
        b = %{"kind" => "storage#bucket", "id" => name, "name" => name,
              "location" => Map.get(opts, "location", "US"),
              "storageClass" => Map.get(opts, "storageClass", "STANDARD"),
              "timeCreated" => now_iso(), "metageneration" => "1",
              "etag" => "CAE=", "generation_seed" => g}
        {:ok, put_in(st.buckets[name], Map.delete(b, "generation_seed")), Map.delete(b, "generation_seed")}
    end
  end

  def get_bucket(st, name) do
    case st.buckets do
      %{^name => b} -> {:ok, b}
      _ -> err(404, "notFound", "The specified bucket does not exist.")
    end
  end

  def list_buckets(st), do: {:ok, st.buckets |> Map.values() |> Enum.sort_by(& &1["name"])}

  def delete_bucket(st, name) do
    with {:ok, _} <- get_bucket(st, name) do
      if Enum.any?(st.objects, fn {{b, _}, _} -> b == name end) do
        err(409, "conflict", "The bucket you tried to delete was not empty.")
      else
        {:ok, %{st | buckets: Map.delete(st.buckets, name)}}
      end
    end
  end

  def valid_bucket?(n) when is_binary(n), do: Regex.match?(~r/^[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]$/, n)
  def valid_bucket?(_), do: false

  # ---- objects -----------------------------------------------------------

  @doc "Insert an object. `pre` is a map of precondition query params (binary keys)."
  def put_object(st, bucket, name, data, meta \\ %{}, pre \\ %{}) when is_binary(data) do
    with {:ok, _} <- get_bucket(st, bucket),
         :ok <- valid_name(name),
         cur = st.objects[{bucket, name}],
         :ok <- check_pre(cur, pre) do
      {st, g} = bump(st)
      obj = %{
        bucket: bucket, name: name, data: data, generation: g,
        metageneration: 1,
        content_type: Map.get(meta, "contentType", "application/octet-stream"),
        metadata: Map.get(meta, "metadata", %{}),
        md5: Base.encode64(:crypto.hash(:md5, data)),
        crc32c: Base.encode64(<<:erlang.crc32(data)::32>>),
        updated: now_iso()
      }
      {:ok, put_in(st.objects[{bucket, name}], obj), obj}
    end
  end

  def get_object(st, bucket, name, pre \\ %{}) do
    with {:ok, _} <- get_bucket(st, bucket) do
      case st.objects[{bucket, name}] do
        nil -> err(404, "notFound", "No such object: #{bucket}/#{name}")
        obj ->
          with :ok <- check_pre(obj, pre), do: {:ok, obj}
      end
    end
  end

  def delete_object(st, bucket, name, pre \\ %{}) do
    with {:ok, _} <- get_bucket(st, bucket),
         {:ok, _} <- get_object(st, bucket, name, pre) do
      {:ok, %{st | objects: Map.delete(st.objects, {bucket, name})}}
    end
  end

  @doc "List objects with prefix/delimiter. Returns {:ok, %{items, prefixes}}."
  def list_objects(st, bucket, opts \\ %{}) do
    with {:ok, _} <- get_bucket(st, bucket) do
      prefix = Map.get(opts, "prefix", "")
      delim = Map.get(opts, "delimiter")

      names =
        st.objects
        |> Enum.filter(fn {{b, n}, _} -> b == bucket and String.starts_with?(n, prefix) end)
        |> Enum.sort_by(fn {{_, n}, _} -> n end)

      {items, prefixes} =
        Enum.reduce(names, {[], MapSet.new()}, fn {{_, n}, o}, {i, p} ->
          rest = String.replace_prefix(n, prefix, "")
          case delim not in [nil, ""] and :binary.match(rest, delim) do
            {pos, len} -> {i, MapSet.put(p, prefix <> binary_part(rest, 0, pos + len))}
            _ -> {[o | i], p}
          end
        end)

      {:ok, %{items: Enum.reverse(items), prefixes: prefixes |> MapSet.to_list() |> Enum.sort()}}
    end
  end

  @doc "Compose up to 32 source objects (by name, optional generation) into destination."
  def compose(st, bucket, dest, sources, meta \\ %{}, pre \\ %{}) do
    cond do
      sources == [] -> err(400, "invalid", "You must provide at least one source component.")
      length(sources) > 32 -> err(400, "invalid", "The number of source components provided (#{length(sources)}) exceeds the maximum (32)")
      true ->
        sources
        |> Enum.reduce_while({:ok, []}, fn s, {:ok, acc} ->
          name = s["name"]
          spre = if s["generation"], do: %{"ifGenerationMatch" => to_string(s["generation"])}, else: %{}
          case get_object(st, bucket, name, spre) do
            {:ok, o} -> {:cont, {:ok, [o.data | acc]}}
            e -> {:halt, e}
          end
        end)
        |> case do
          {:ok, parts} -> put_object(st, bucket, dest, parts |> Enum.reverse() |> IO.iodata_to_binary(), meta, pre)
          e -> e
        end
    end
  end

  def valid_name(n) when is_binary(n) and byte_size(n) in 1..1024, do: :ok
  def valid_name(_), do: err(400, "invalid", "Invalid object name")

  # ---- preconditions -----------------------------------------------------

  def check_pre(cur, pre) do
    gen = if cur, do: cur.generation, else: 0
    meta = if cur, do: cur.metageneration, else: 0

    checks = [
      {"ifGenerationMatch", &(&1 == gen)},
      {"ifGenerationNotMatch", &(&1 != gen)},
      {"ifMetagenerationMatch", &(&1 == meta)},
      {"ifMetagenerationNotMatch", &(&1 != meta)}
    ]

    Enum.find_value(checks, :ok, fn {k, f} ->
      case pre[k] do
        nil -> nil
        v ->
          case Integer.parse(to_string(v)) do
            {n, ""} -> if f.(n), do: nil, else: precondition_failed()
            _ -> err(400, "invalid", "Invalid #{k}")
          end
      end
    end)
  end

  defp precondition_failed, do: err(412, "conditionNotMet", "At least one of the pre-conditions you specified did not hold.")

  # ---- resumable uploads -------------------------------------------------

  def start_resumable(st, bucket, name, meta, pre) do
    with {:ok, _} <- get_bucket(st, bucket), :ok <- valid_name(name) do
      {st, g} = bump(st)
      id = "smalt-gcs-" <> Integer.to_string(g) <> "-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
      up = %{bucket: bucket, name: name, meta: meta, pre: pre, buf: ""}
      {:ok, put_in(st.uploads[id], up), id}
    end
  end

  @doc """
  Apply a chunk to a resumable session. `range` is the parsed Content-Range:
  `{first, last, total}` with total `:unknown` or integer, or `{:status, total}`
  for a `bytes */N` query. Returns `{:incomplete, st, committed_size}` or
  `{:ok, st, obj}`.
  """
  def upload_chunk(st, id, chunk, range) do
    case st.uploads[id] do
      nil -> err(404, "notFound", "Upload session not found")
      up ->
        size = byte_size(up.buf)

        case range do
          {:status, _} -> {:incomplete, st, size}
          {first, _last, total} when first == size ->
            buf = up.buf <> chunk
            cond do
              is_integer(total) and byte_size(buf) == total -> finalize(st, id, %{up | buf: buf})
              is_integer(total) and byte_size(buf) > total -> err(400, "invalid", "Content-Range exceeds total")
              true -> {:incomplete, put_in(st.uploads[id], %{up | buf: buf}), byte_size(buf)}
            end
          {first, _, _} -> err(400, "invalid", "Expected offset #{size}, got #{first}")
        end
    end
  end

  defp finalize(st, id, up) do
    st = %{st | uploads: Map.delete(st.uploads, id)}
    put_object(st, up.bucket, up.name, up.buf, up.meta, up.pre)
  end

  def parse_content_range("bytes */" <> t), do: {:status, parse_total(t)}
  def parse_content_range("bytes " <> rest) do
    with [rng, t] <- String.split(rest, "/", parts: 2),
         [f, l] <- String.split(rng, "-", parts: 2),
         {f, ""} <- Integer.parse(f), {l, ""} <- Integer.parse(l) do
      {f, l, parse_total(t)}
    else
      _ -> :error
    end
  end
  def parse_content_range(_), do: :error
  defp parse_total("*"), do: :unknown
  defp parse_total(t), do: (case Integer.parse(t), do: ({n, ""} -> n; _ -> :unknown))

  # ---- signed URLs (V4-shaped, emulator key) -----------------------------

  @doc "Build V4-style signed URL query for `method` on `/bucket/object`."
  def sign_url(method, bucket, object, opts) do
    key = Keyword.fetch!(opts, :key)
    email = Keyword.get(opts, :email, "emulator@smalt.iam.gserviceaccount.com")
    expires = Keyword.get(opts, :expires, 3600)
    date = Keyword.get(opts, :date, DateTime.utc_now())
    stamp = Calendar.strftime(date, "%Y%m%dT%H%M%SZ")
    cred = "#{email}/#{Calendar.strftime(date, "%Y%m%d")}/auto/storage/goog4_request"

    q = [{"X-Goog-Algorithm", "GOOG4-HMAC-SHA256"}, {"X-Goog-Credential", cred},
         {"X-Goog-Date", stamp}, {"X-Goog-Expires", to_string(expires)}, {"X-Goog-SignedHeaders", "host"}]

    sig = sig(key, method, "/#{bucket}/#{object}", q)
    "/#{bucket}/#{object}?" <> URI.encode_query(q ++ [{"X-Goog-Signature", sig}], :rfc3986)
  end

  @doc "Verify a signed URL given method, path and decoded query map."
  def verify_signed(method, path, query, key, now \\ DateTime.utc_now()) do
    with %{"X-Goog-Signature" => given, "X-Goog-Date" => stamp, "X-Goog-Expires" => exp} <- query,
         {:ok, ndt} <- parse_stamp(stamp),
         {e, ""} <- Integer.parse(exp) do
      q = query |> Map.delete("X-Goog-Signature") |> Enum.sort()
      cond do
        DateTime.diff(now, ndt) > e -> err(403, "expired", "Signed URL expired")
        not Plug.Crypto.secure_compare(sig(key, method, path, q), given) -> err(403, "forbidden", "SignatureDoesNotMatch")
        true -> :ok
      end
    else
      _ -> err(403, "forbidden", "Missing or malformed signed URL parameters")
    end
  end

  # parse 20260101T000000Z
  defp parse_stamp(<<y::binary-4, m::binary-2, d::binary-2, "T", h::binary-2, mi::binary-2, s::binary-2, "Z">>) do
    with {:ok, nd} <- NaiveDateTime.new(String.to_integer(y), String.to_integer(m), String.to_integer(d),
                                        String.to_integer(h), String.to_integer(mi), String.to_integer(s)) do
      DateTime.from_naive(nd, "Etc/UTC")
    end
  rescue
    _ -> :error
  end
  defp parse_stamp(_), do: :error

  defp sig(key, method, path, q) do
    canon = q |> Enum.sort() |> URI.encode_query(:rfc3986)
    :crypto.mac(:hmac, :sha256, key, Enum.join([String.upcase(method), path, canon], "\n")) |> Base.encode16(case: :lower)
  end

  # ---- representation ----------------------------------------------------

  def object_json(o) do
    %{"kind" => "storage#object", "id" => "#{o.bucket}/#{o.name}/#{o.generation}", "name" => o.name,
      "bucket" => o.bucket, "generation" => to_string(o.generation),
      "metageneration" => to_string(o.metageneration), "contentType" => o.content_type,
      "size" => to_string(byte_size(o.data)), "md5Hash" => o.md5, "crc32c" => o.crc32c,
      "etag" => Base.encode64(to_string(o.generation)), "updated" => o.updated,
      "timeCreated" => o.updated, "storageClass" => "STANDARD", "metadata" => o.metadata}
  end

  def error_json(%{status: s, reason: r, message: m}),
    do: %{"error" => %{"code" => s, "message" => m, "errors" => [%{"message" => m, "domain" => "global", "reason" => r}]}}

  defp bump(st), do: {%{st | gen: st.gen + 1}, System.os_time(:microsecond) * 1000 + st.gen + 1}
  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
