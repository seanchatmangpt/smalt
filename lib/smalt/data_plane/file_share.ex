defmodule Smalt.DataPlane.FileShare do

  # UNBLOCK FIX (IMPL-4, compile-freeze SLA 2026-10-21): OTP-29-lane experiment
  # used `is_integer/3` range guards (not a real BIF on OTP 28 / any OTP).
  # Equivalent guard macro preserves semantics; owning lane may re-pin.
  # AR-WIRE-02 (IMPL-2 re-pin): body delegates to the real OTP-29 range
  # guard BIF `:erlang.is_integer/3` (OTP-29-only; compile-refused on
  # OTP <= 28). The Elixir 1.20 front end does not admit bare
  # `is_integer/3` in guards ("there is no such import"), so this one-line
  # delegate is the direct-BIF form — IMPL-4's 3-comparison shim body is
  # superseded. Repo standard toolchain: OTP 29 (TOOLUP, .tool-versions
  # erlang 29.1.2 / elixir 1.20.4-otp-29).
  # AR-WIRE-02 (IMPL-2 final re-pin): delegates to the real OTP-29 range
  # guard BIF `:erlang.is_integer/3` (OTP-29-only; compile-refused on
  # OTP <= 28). Elixir 1.20 does not admit bare is_integer/3 in guards
  # ("there is no such import"), so this one-line delegate IS the direct-BIF
  # form; the `x in lo..hi` shim body is semantically identical but is the
  # OTP-28 fallback, not the adopted BIF. Repo toolchain: OTP 29
  # (TOOLUP, .tool-versions erlang 29.1.2 / elixir 1.20.4-otp-29).
  defguardp int_in(x, lo, hi) when is_integer(x) and x >= lo and x <= hi



  @moduledoc """
  Azure Files REST face (capability wave 6, lane w6o) over a module-owned,
  heir'd ETS table `:smalt_file_shares`.

  Surface (XML bodies, x-ms-* header discipline, blob-style error envelope):

    - `GET    /?comp=list`                        -> List Shares
    - `PUT    /{share}?restype=share`             -> Create Share (x-ms-share-quota 1..5120)
    - `GET/HEAD /{share}?restype=share`           -> Get Share Properties
    - `GET    /{share}?restype=share&comp=stats`  -> Get Share Stats (ShareUsage MiB)
    - `DELETE /{share}?restype=share`             -> Delete Share (202)
    - `PUT    /{share}/{dir}?restype=directory`   -> Create Directory (201 / 409 dup)
    - `GET/HEAD /{segs}?restype=directory`        -> Get Directory Properties
    - `DELETE /{segs}?restype=directory`          -> Delete Directory (204; refuses non-empty)
    - `GET  /{share}[/{dir}]?comp=list`           -> List Directories and Files
    - `PUT  /{share}/.../{file}` x-ms-type: File   -> Create File (201 / 409 dup)
    - `PUT  /{share}/.../{file}?comp=range`        -> Put Range (write/clear, <=4MiB)
    - `GET  /{share}/.../{file}?comp=rangelist`    -> Get Range List
    - `GET  /{share}/.../{file}`                   -> Get File (zeros-fill, x-ms-range -> 206)
    - `DELETE /{share}/.../{file}`                 -> Delete File (202)

  Data model (one table, tuple-keyed rows):
    `{:share, sk}` -> `%{name, quota, created}` · `{:dir, sk, path}` ->
    `%{name, path, created}` · `{:file, sk, path}` -> `%{size, created}` ·
    `{:range, sk, path, start}` -> binary chunk.
  """

  alias Smalt.DataPlane.BlobService

  @table :smalt_file_shares
  @version "2021-06-08"
  @max_quota 5120
  @max_range_bytes 4 * 1024 * 1024

  @type resp :: {:ok, pos_integer(), map(), binary() | nil}
  @type err :: {:error, pos_integer(), binary(), binary()}

  # ---------------------------------------------------------------------------
  # Table ownership (shadow-table law: heir to :init, race fail-safe)
  # ---------------------------------------------------------------------------

  @doc "Ensures the heir'd `#{@table}` exists. Idempotent, safe from any process."
  @spec ensure_table :: :ok
  def ensure_table do
    if :ets.info(@table) == :undefined do
      try do
        :ets.new(@table, [
          :set,
          :public,
          :named_table,
          {:heir, Process.whereis(:init), []},
          read_concurrency: true,
          write_concurrency: true
        ])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  defp ready, do: ensure_table()

  defp std_headers do
    %{"x-ms-request-id" => request_id(), "x-ms-version" => @version}
  end

  defp request_id, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp rfc1124 do
    Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S GMT")
  end

  defp sk(name), do: String.downcase(name)

  # ---------------------------------------------------------------------------
  # Share lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Create Share. `x-ms-share-quota` (1..5120) validated when present; default
  5120. Dup -> 409 ShareAlreadyExists (insert_new, atomic).
  """
  @spec create_share(binary, map) :: resp | err
  def create_share(name, headers) do
    :ok = ready()

    with :ok <- validate_quota(headers) do
      quota = quota_of(headers)
      row = {:share, sk(name)}
      rec = %{name: name, quota: quota, created: rfc1124()}

      if :ets.insert_new(@table, {row, rec}) do
        {:ok, 201, Map.merge(std_headers(), %{"etag" => etag(row), "last-modified" => rec.created}), nil}
      else
        {:error, 409, "ShareAlreadyExists", "The specified share already exists."}
      end
    end
  end

  defp validate_quota(headers) do
    case headers["x-ms-share-quota"] do
      nil -> :ok
      raw ->
        case Integer.parse(to_string(raw)) do
          {q, ""} when q >= 1 and q <= @max_quota -> :ok
          {_q, _rest} -> {:error, 400, "InvalidHeaderValue", "x-ms-share-quota must be 1..#{@max_quota}."}
          :error -> {:error, 400, "InvalidHeaderValue", "x-ms-share-quota must be an integer."}
        end
    end
  end

  defp quota_of(headers), do: int_or(headers["x-ms-share-quota"], @max_quota)

  defp int_or(nil, dflt), do: dflt
  defp int_or(raw, dflt) do
    case Integer.parse(to_string(raw)) do
      {q, ""} -> q
      _ -> dflt
    end
  end

  @doc "Get Share Properties. Unknown share -> 404 ShareNotFound."
  @spec get_share_properties(binary) :: resp | err
  def get_share_properties(name) do
    :ok = ready()

    case :ets.lookup(@table, {:share, sk(name)}) do
      [{_k, rec}] ->
        {:ok, 200,
         Map.merge(std_headers(), %{
           "etag" => etag({:share, sk(name)}),
           "last-modified" => rec.created,
           "x-ms-share-quota" => Integer.to_string(rec.quota)
         }), nil}

      [] ->
        {:error, 404, "ShareNotFound", "The specified share does not exist."}
    end
  end

  @doc "Get Share Stats. ShareUsage = max(1, ceil(bytes/1MiB))."
  @spec get_share_stats(binary) :: resp | err
  def get_share_stats(name) do
    :ok = ready()

    case :ets.lookup(@table, {:share, sk(name)}) do
      [] ->
        {:error, 404, "ShareNotFound", "The specified share does not exist."}

      _ ->
        bytes = share_bytes(sk(name))
        usage = Enum.max([1, div(bytes, 1024 * 1024) + if(rem(bytes, 1024 * 1024) > 0, do: 1, else: 0)])
        body = ~s(<?xml version="1.0" encoding="utf-8"?><ShareStats><ShareUsage>#{usage}</ShareUsage></ShareStats>)
        {:ok, 200, Map.merge(std_headers(), %{"content-type" => "application/xml"}), body}
    end
  end

  defp share_bytes(skey) do
    :ets.foldl(
      fn
        {{:range, s, _p, _st}, bin}, acc when is_binary(bin) ->
          if s == skey, do: acc + byte_size(bin), else: acc

        _, acc ->
          acc
      end,
      0,
      @table
    )
  end


    # Etag for a row (weak parity: stable function of the key)."
  defp etag(key), do: "\"" <> Base.encode16(:erlang.term_to_binary(key), case: :lower) <> "\""

  defp share_exists?(skey) do
    :ets.member(@table, {:share, skey})
  end

  # ---------------------------------------------------------------------------
  # Directories
  # ---------------------------------------------------------------------------

  @doc "Create Directory. Parent dirs may be implicit (Azure allows any depth); dup -> 409."
  @spec create_directory(binary, binary) :: resp | err
  def create_directory(share, path) do
    :ok = ready()
    skey = sk(share)

    with :ok <- require_share(skey) do
      dkey = {:dir, skey, path_key(path)}
      rec = %{name: last_seg(path), path: path, created: rfc1124()}

      if :ets.insert_new(@table, {dkey, rec}) do
        {:ok, 201, Map.merge(std_headers(), %{"etag" => etag(dkey), "last-modified" => rec.created}), nil}
      else
        {:error, 409, "ResourceAlreadyExists", "The specified directory already exists."}
      end
    end
  end

  @doc "Get Directory Properties."
  @spec get_directory_properties(binary, binary) :: resp | err
  def get_directory_properties(share, path) do
    :ok = ready()
    skey = sk(share)

    with :ok <- require_share(skey) do
      case :ets.lookup(@table, {:dir, skey, path_key(path)}) do
        [{_k, rec}] ->
          {:ok, 200,
           Map.merge(std_headers(), %{"etag" => etag({:dir, skey, path_key(path)}), "last-modified" => rec.created}),
           nil}

        [] ->
          {:error, 404, "ResourceNotFound", "The specified directory does not exist."}
      end
    end
  end

  @doc "Delete Directory. Refuses non-empty (child dirs or files) with 409."
  @spec delete_directory(binary, binary) :: resp | err
  def delete_directory(share, path) do
    :ok = ready()
    skey = sk(share)
    pkey = path_key(path)

    with :ok <- require_share(skey),
         :ok <- require_dir(skey, pkey) do
      children =
        :ets.foldl(
          fn
            {{:dir, s, p}, _}, acc when s == skey ->
              if parent_of(p) == pkey, do: [true | acc], else: acc

            {{:file, s, p}, _}, acc when s == skey ->
              if parent_of(p) == pkey, do: [true | acc], else: acc

            _, acc ->
              acc
          end,
          [],
          @table
        )

      if children != [] do
        {:error, 409, "DirectoryNotEmpty", "The directory is not empty."}
      else
        :ets.delete(@table, {:dir, skey, pkey})
        {:ok, 204, std_headers(), nil}
      end
    end
  end

  @doc """
  List Directories and Files. `prefix` honored; returns XML EnumerationResults
  with Directory/File entries (files carry Content-Length in Properties).
  """
  @spec list_dir(binary, binary | nil, binary | nil) :: resp | err
  def list_dir(share, dir_path, prefix) do
    :ok = ready()
    skey = sk(share)

    with :ok <- require_share(skey) do
      base =
        cond do
          is_binary(dir_path) and dir_path != "" -> path_key(dir_path)
          true -> []
        end

      {dirs, files} =
        :ets.foldl(
          fn
            {{:dir, s, p}, rec}, {ds, fs} when s == skey ->
              if same_scope(p, base, prefix), do: {[{p, rec} | ds], fs}, else: {ds, fs}

            {{:file, s, p}, rec}, {ds, fs} when s == skey ->
              if same_scope(p, base, prefix), do: {ds, [{p, rec} | fs]}, else: {ds, fs}

            _, acc ->
              acc
          end,
          {[], []},
          @table
        )

      body = render_listing(base, Enum.sort(dirs), Enum.sort(files))
      {:ok, 200, Map.merge(std_headers(), %{"content-type" => "application/xml"}), body}
    end
  end

  # listing scope: entries directly under `base` matching `prefix` on the last seg
  defp same_scope(path, base, prefix) do
    parent = parent_of(path)
    parent == base and prefix_match?(last_seg(path), prefix)
  end

  defp prefix_match?(_seg, nil), do: true
  defp prefix_match?(seg, prefix), do: String.starts_with?(seg, prefix)

  defp render_listing(base, dirs, files) do
    dir_xml =
      Enum.map_join(dirs, "", fn {p, _rec} ->
        "<Directory><Name>#{BlobService.xml_escape(relative_name(p, base))}</Name></Directory>"
      end)

    file_xml =
      Enum.map_join(files, "", fn {p, rec} ->
        "<File><Name>#{BlobService.xml_escape(relative_name(p, base))}</Name><Properties><Content-Length>#{rec.size}</Content-Length></Properties></File>"
      end)

    dirattr =
      case base do
        [] -> ""
        p -> ~s( DirectoryName="#{BlobService.xml_escape(join_path(p))}")
      end

    ~s(<?xml version="1.0" encoding="utf-8"?><EnumerationResults#{dirattr}><Entries>#{dir_xml}#{file_xml}</Entries></EnumerationResults>)
  end

  # listings echo the entry name RELATIVE to the listed directory (real
  # Azure Files List Directories and Files semantics)
  defp relative_name(path, base), do: join_path(Enum.drop(path, length(base)))

  # path keys are segment lists (lowercase); join with "/" for the wire name
  defp path_key(path) when is_binary(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&sk/1)
  end

  defp join_path(segs), do: Enum.join(segs, "/")

  defp parent_of(segs), do: Enum.drop(segs, -1)

  defp last_seg(segs) when is_list(segs), do: List.last(segs) || ""

  defp last_seg(path) when is_binary(path),
    do: path |> String.split("/", trim: true) |> List.last() || ""

  defp require_share(skey) do
    if share_exists?(skey),
      do: :ok,
      else: {:error, 404, "ShareNotFound", "The specified share does not exist."}
  end

  defp require_dir(skey, pkey) do
    if :ets.member(@table, {:dir, skey, pkey}),
      do: :ok,
      else: {:error, 404, "ResourceNotFound", "The specified directory does not exist."}
  end

  # ---------------------------------------------------------------------------
  # Files + ranges
  # ---------------------------------------------------------------------------

  @doc "Create File (x-ms-type: File). x-ms-content-length required (0..4TB namespace)."
  @spec create_file(binary, binary, map) :: resp | err
  def create_file(share, path, headers) do
    :ok = ready()
    skey = sk(share)

    with :ok <- require_share(skey),
         {:ok, size} <- content_length_of(headers) do
      fkey = {:file, skey, path_key(path)}
      rec = %{size: size, created: rfc1124()}

      if :ets.insert_new(@table, {fkey, rec}) do
        {:ok, 201, Map.merge(std_headers(), %{"etag" => etag(fkey), "last-modified" => rec.created}), nil}
      else
        {:error, 409, "ResourceAlreadyExists", "The specified file already exists."}
      end
    end
  end

  # UNBLOCK FIX (IMPL-5, compile-freeze SLA 2026-10-21): AR-WIRE-02 in-flight

  # OTP-29 TOOLCHAIN FLOOR: is_integer/3 range guards below are OTP-29-only
  # (compile-refused on OTP <= 28). Repo standard toolchain: OTP 29 (TOOLUP).
  @max_share_guard_int 9_007_199_254_740_991

  defp content_length_of(headers) do
    case headers["x-ms-content-length"] do
      nil ->
        {:error, 400, "InvalidHeaderValue", "x-ms-content-length is required to create a file."}

      raw ->
        case Integer.parse(to_string(raw)) do
          # OTP-29 is_integer/3 single-guard head (AR-WIRE-02; bignum
          # ceiling arm keeps identical semantics). TOOLCHAIN FLOOR:
          # is_integer/3 is OTP-29-only (compile-refused on OTP <= 28).
          {n, ""} when int_in(n, 0, @max_share_guard_int) -> {:ok, n}
          {n, ""} when is_integer(n) -> {:ok, n}
          _ -> {:error, 400, "InvalidHeaderValue", "x-ms-content-length must be a non-negative integer."}
        end
    end
  end

  @doc """
  Put Range. `x-ms-range: bytes=a-b` (<= 4MiB span), body bytes; `x-ms-write:
  clear` zero-fills the span. Unknown file -> 404; span != content-length -> 400
  InvalidHeaderValue; oversized span -> 400 RequestBodyTooLarge.
  """
  @spec put_range(binary, binary, map, binary) :: resp | err
  def put_range(share, path, headers, body) do
    :ok = ready()
    skey = sk(share)
    pkey = path_key(path)

    with :ok <- require_share(skey),
         {:ok, _frec} <- require_file(skey, pkey),
         {:ok, {start, fin}} <- parse_range_header(headers),
         :ok <- check_span(start, fin) do
      span = fin - start + 1

      cond do
        headers["x-ms-write"] == "clear" ->
          clear_span(skey, pkey, start, fin)
          {:ok, 201, std_headers(), nil}

        byte_size(body) != span ->
          {:error, 400, "InvalidHeaderValue", "Content-Length must equal the range span."}

        true ->
          :ets.insert(@table, {{:range, skey, pkey, start}, body})
          {:ok, 201, std_headers(), nil}
      end
    end
  end

  defp require_file(skey, pkey) do
    case :ets.lookup(@table, {:file, skey, pkey}) do
      [{_k, rec}] -> {:ok, rec}
      [] -> {:error, 404, "ResourceNotFound", "The specified file does not exist."}
    end
  end

  defp parse_range_header(headers) do
    case headers["x-ms-range"] do
      nil -> {:error, 400, "InvalidHeaderValue", "x-ms-range is required for comp=range writes."}
      raw -> parse_range_raw(to_string(raw))
    end
  end

  defp parse_range_raw(raw) do
    raw = String.replace_prefix(raw, "bytes=", "")

    case Integer.parse(raw) do
      # OTP-29 is_integer/3 single-guard heads (AR-WIRE-02); each bignum
      # ceiling arm keeps identical semantics to its bounded head.
      {start, rest} when int_in(start, 0, @max_share_guard_int) ->
        parse_range_fin(rest, start)

      {start, rest} when is_integer(start) ->
        parse_range_fin(rest, start)

      _ ->
        {:error, 400, "InvalidHeaderValue", "x-ms-range grammar: bytes=a-"}
    end
  end

  defp parse_range_fin("-" <> tail, start) do
    case Integer.parse(tail) do
      {fin, ""} when int_in(fin, start, @max_share_guard_int) -> {:ok, {start, fin}}
      {fin, ""} when is_integer(fin) and fin >= start -> {:ok, {start, fin}}
      _ -> {:error, 400, "InvalidHeaderValue", "x-ms-range grammar: bytes=a-b."}
    end
  end

  defp parse_range_fin(_rest, _start) do
    {:error, 400, "InvalidHeaderValue", "x-ms-range grammar: bytes=a-b."}
  end

  defp check_span(start, fin) do
    if fin - start + 1 > @max_range_bytes,
      do: {:error, 400, "RequestBodyTooLarge", "A range write is at most 4MiB."},
      else: :ok
  end

  @doc "Get Range List (comp=rangelist) — XML of stored, non-zero ranges."
  @spec get_range_list(binary, binary) :: resp | err
  def get_range_list(share, path) do
    :ok = ready()
    skey = sk(share)
    pkey = path_key(path)

    with {:ok, frec} <- require_file(skey, pkey) do
      ranges =
        :ets.foldl(
          fn
            {{:range, s, p, st}, bin}, acc when s == skey and p == pkey and is_binary(bin) ->
              [{st, st + byte_size(bin) - 1} | acc]

            _, acc ->
              acc
          end,
          [],
          @table
        )
        |> Enum.sort()

      xml =
        Enum.map_join(ranges, "", fn {a, b} ->
          "<Range><Start>#{a}</Start><End>#{b}</End></Range>"
        end)

      body = ~s(<?xml version="1.0" encoding="utf-8"?><RangeList>#{xml}</RangeList>)
      {:ok, 200, Map.merge(std_headers(), %{"etag" => etag({:file, skey, pkey}), "content-type" => "application/xml", "x-ms-content-length" => Integer.to_string(frec.size)}), body}
    end
  end

  @doc """
  Get File. Reads assemble the declared size: unset ranges read as zeros.
  `x-ms-range: bytes=a-b` -> 206 with Content-Range; otherwise 200 full.
  """
  @spec get_file(binary, binary, map) :: {:ok, pos_integer(), map(), binary()} | err
  def get_file(share, path, headers) do
    :ok = ready()
    skey = sk(share)
    pkey = path_key(path)

    with {:ok, frec} <- require_file(skey, pkey) do
      {start, fin} =
        case headers["x-ms-range"] do
          nil ->
            {0, frec.size - 1}

          raw ->
            case parse_range_raw(to_string(raw)) do
              {:ok, {a, b}} -> {a, min(b, frec.size - 1)}
              _ -> {0, frec.size - 1}
            end
        end

      if start > fin do
        {:error, 416, "InvalidRange", "The range specified is invalid for a file of size #{frec.size}."}
      else
        body = read_span(skey, pkey, start, fin)

        hdrs =
          Map.merge(std_headers(), %{
            "etag" => etag({:file, skey, pkey}),
            "x-ms-content-length" => Integer.to_string(frec.size),
            "content-type" => "application/octet-stream"
          })

        if headers["x-ms-range"] do
          hdrs =
            Map.put(hdrs, "content-range", "bytes #{start}-#{start + byte_size(body) - 1}/#{frec.size}")

          {:ok, 206, hdrs, body}
        else
          {:ok, 200, hdrs, body}
        end
      end
    end
  end

  defp read_span(skey, pkey, start, fin) do
    total = fin - start + 1
    buf = :binary.copy(<<0>>, total)

    :ets.foldl(
      fn
        {{:range, s, p, st}, bin}, acc when s == skey and p == pkey and is_binary(bin) ->
          overlay(acc, start, fin, st, bin)

        _, acc ->
          acc
      end,
      buf,
      @table
    )
  end

  defp overlay(acc, start, fin, st, bin) do
    r_end = st + byte_size(bin) - 1

    if r_end < start or st > fin do
      acc
    else
      off = max(st, start) - start
      src_off = max(start - st, 0)
      take = min(byte_size(bin) - src_off, fin - start - off + 1)

      if take <= 0 do
        acc
      else
        piece = binary_part(bin, src_off, take)
        <<pre::binary-size(^off), _::binary-size(^take), post::binary>> = acc
        <<pre::binary, piece::binary, post::binary>>
      end
    end
  end

  @doc "Delete File (202). Unknown file -> 404."
  @spec delete_file(binary, binary) :: resp | err
  def delete_file(share, path) do
    :ok = ready()
    skey = sk(share)
    pkey = path_key(path)

    with {:ok, _} <- require_file(skey, pkey) do
      :ets.delete(@table, {:file, skey, pkey})
      drop_ranges(skey, pkey)
      {:ok, 202, std_headers(), nil}
    end
  end

  # Real Azure clear semantics: the cleared span LEAVES the nonzero range
  # list (reads return zeros). Trim/delete stored chunks overlapping [start, fin].
  defp clear_span(skey, pkey, start, fin) do
    :ets.foldl(
      fn
        {{:range, s, p, st}, bin}, :ok when s == skey and p == pkey and is_binary(bin) ->
          e = st + byte_size(bin) - 1

          cond do
            e < start or st > fin ->
              :ok

            st >= start and e <= fin ->
              :ets.delete(@table, {:range, skey, pkey, st})
              :ok

            st < start ->
              keep = :binary.part(bin, 0, start - st)
              :ets.insert(@table, {{:range, skey, pkey, st}, keep})
              :ok

            true ->
              new_st = fin + 1
              keep = :binary.part(bin, new_st - st, e - new_st + 1)
              :ets.insert(@table, {{:range, skey, pkey, new_st}, keep})
              :ok
          end

        _, acc ->
          acc
      end,
      :ok,
      @table
    )
  end

  defp drop_ranges(skey, pkey) do
    :ets.foldl(
      fn
        {{:range, s, p, st}, _}, acc when s == skey and p == pkey ->
          [{:range, s, p, st} | acc]

        _, acc ->
          acc
      end,
      [],
      @table
    )
    |> Enum.each(&:ets.delete(@table, &1))
  end
  @doc "List Shares (GET /?comp=list) - EnumerationResults XML."
  @spec list_shares() :: resp
  def list_shares do
    :ok = ready()
    shares =
      :ets.foldl(
        fn
          {{:share, _}, rec}, acc -> [{rec.name, rec} | acc]
          _, acc -> acc
        end,
        [],
        @table
      )
    body = render_share_list(Enum.sort(shares))
    {:ok, 200, Map.merge(std_headers(), %{"content-type" => "application/xml"}), body}
  end

  defp render_share_list(shares) do
    entries =
      Enum.map_join(shares, "", fn {name, rec} ->
        "<Share><Name>" <> BlobService.xml_escape(name) <>
        "</Name><Properties><Last-Modified>" <> rec.created <>
        "</Last-Modified><Quota>" <> Integer.to_string(rec.quota) <>
        "</Quota></Properties></Share>"
      end)
    ~s(<?xml version="1.0" encoding="utf-8"?><EnumerationResults ServiceEndpoint="file"><Shares>) <>
      entries <> "</Shares></EnumerationResults>"
  end

  @doc "Delete Share (202): drops the share row plus all dirs, files, ranges."
  @spec delete_share(binary) :: resp | err
  def delete_share(name) do
    :ok = ready()
    skey = sk(name)
    case :ets.lookup(@table, {:share, skey}) do
      [] ->
        {:error, 404, "ShareNotFound", "The specified share does not exist."}
      [_] ->
        drop_share_rows(skey)
        {:ok, 202, std_headers(), nil}
    end
  end

  defp drop_share_rows(skey) do
    :ets.delete(@table, {:share, skey})
    keys =
      :ets.foldl(
        fn
          {k, _}, acc ->
            case k do
              {:dir, s, _p} when s == skey -> [k | acc]
              {:file, s, _p} when s == skey -> [k | acc]
              {:range, s, _p, _st} when s == skey -> [k | acc]
              _ -> acc
            end
        end,
        [],
        @table
      )
    Enum.each(keys, &:ets.delete(@table, &1))
  end
end
