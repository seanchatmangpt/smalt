defmodule Smalt.Storage.JournalReader do
  @moduledoc """
  Journal segment reader (PROD-1 / SJ-2).

  Reads SEALED journal segments written by `Smalt.Storage.JournalSink` (SJ-1)
  or the Erlang reference `smalt_journal`. A sealed segment is the triple
  under `<dir>/sealed/`:

      seg-<20-digit-seq>.journal            frames, appended in SeqID order
      seg-<20-digit-seq>.journal.meta.json  manifest: segment, bytes, frames,
                                            first_seq, last_seq, sha256 (hex)
      seg-<20-digit-seq>.journal.seal       seal sentinel — presence IS the
                                            sealed state; its absence is a
                                            typed refusal, never a best-effort
                                            parse of a segment under the
                                            writer's pen

  Frame layout (the cross-language wire contract, big-endian) is owned by the
  sink codec (`Smalt.Storage.JournalSink.encode_frame/6` / `decode_frame/1`):
  MAGIC "SMAL", FrameLen u32, SeqID u64, Ts s64, EventType u16, TableID u16,
  KeyLen u32 + Key, PayloadLen u32 + Payload, CRC32 u32 over SeqID..Payload.

  Fail-closed laws (SPOF-A3 split): INTEGRITY failures — a CRC mismatch, a
  manifest sha256 mismatch, a SeqID regression, or a truncated tail — are
  typed boot refusals, never a partial admission, never a best-effort parse.
  COMPLETENESS failures — a segment sitting in `sealed/` without its full
  `.seal` + `.meta.json` triple (the writer's crash window mid-rename) — are
  NOT a boot refusal: discovery quarantines such tails into `<dir>/quarantine/`
  (logged, `[:smalt, :journal, :quarantined]` telemetry, never silent) so the
  node boots; the quarantined bytes are preserved, never deleted.
  """

  @type frame :: %{
          required(:seq_id) => non_neg_integer(),
          required(:ts) => integer(),
          required(:event_type) => non_neg_integer(),
          required(:table_id) => non_neg_integer(),
          required(:key) => binary(),
          required(:payload) => binary()
        }

  @type refusal ::
          {:error,
           {:not_sealed, Path.t()}
           | {:missing_meta, Path.t()}
           | {:manifest_mismatch, keyword()}
           | {:crc_mismatch, keyword()}
           | {:seq_regression, keyword()}
           | {:truncated_frame, keyword()}
           | {:truncated_tail, keyword()}
           | {:bad_magic, keyword()}}

  @magic "SMAL"
  require Logger

  alias Smalt.Storage.JournalSink

  @frame_hdr 8
  # magic + framelen — minimum needed to size the next frame

  @doc """
  Discover SEALED segments under `<dir>/sealed`, sorted by name (the
  zero-padded seq prefix makes lexical == ordinal order).

  With `matter_scope:` (BK-135r) discovery runs under the scope's own root
  (`Smalt.Storage.JournalSink.matter_root/2` = `<dir>/matter_<scope>/segments/`),
  with quarantine confined to `<dir>/matter_<scope>/segments/quarantine/` —
  matter A's quarantine can never touch matter B's replay path.
  Sentinel law: a `.journal` is listed only when both its `.seal` sentinel AND
  `.meta.json` manifest exist. An active (unsealed) segment is never listed.
  Completeness law (SPOF-A3): a `.journal` in `sealed/` with a missing
  sentinel or manifest is a crash-window tail — it is renamed into
  `<dir>/quarantine/` (logged + `[:smalt, :journal, :quarantined]` telemetry,
  bytes preserved) and excluded, so boot never wedges on a completeness
  failure. Integrity failures found later in `read_sealed_segment/1` still
  refuse fail-closed.
  """
  @spec discover_sealed_segments(Path.t()) :: {:ok, [Path.t()]}
  def discover_sealed_segments(dir) when is_binary(dir) do
    do_discover(dir, dir)
  end

  @doc "Scoped discovery (BK-135r): `discover_sealed_segments(dir, matter_scope: scope)`."
  @spec discover_sealed_segments(Path.t(), keyword()) :: {:ok, [Path.t()]}
  def discover_sealed_segments(dir, matter_scope: scope) when is_binary(dir) and is_binary(scope) do
    do_discover(dir, JournalSink.matter_root(dir, scope))
  end

  defp do_discover(_dir, base) do
    {segs, _quarantined} =
      base
      |> Path.join("sealed/*.journal")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map_reduce(0, fn seg, q ->
        cond do
          File.regular?(seg <> ".seal") and File.regular?(seg <> ".meta.json") ->
            {seg, q}

          quarantine_incomplete(base, seg) ->
            {nil, q + 1}

          true ->
            # quarantine itself failed (e.g. read-only volume): exclude the
            # segment loudly but never crash discovery — boot proceeds, the
            # tail stays put on disk
            {nil, q}
        end
      end)

    {:ok, Enum.reject(segs, &is_nil/1)}
  end

  defp quarantine_incomplete(dir, seg) do
    reason = if File.regular?(seg <> ".seal"), do: :missing_meta, else: :not_sealed

    case File.mkdir_p(Path.join(dir, "quarantine")) do
      :ok ->
        case File.rename(seg, Path.join([dir, "quarantine", Path.basename(seg)])) do
          :ok ->
            Logger.warning(
              "Smalt.Storage.JournalReader: quarantined incomplete sealed segment " <>
                "#{seg} (#{reason}) — crash-window tail; bytes preserved under #{dir}/quarantine/"
            )

            :telemetry.execute([:smalt, :journal, :quarantined], %{count: 1}, %{
              path: seg,
              dir: dir,
              reason: reason
            })

            true

          {:error, rename_reason} ->
            Logger.error(
              "Smalt.Storage.JournalReader: could NOT quarantine incomplete segment #{seg} " <>
                "(#{inspect(rename_reason)}) — excluding from replay, file left in place"
            )

            false
        end

      {:error, mkdir_reason} ->
        Logger.error(
          "Smalt.Storage.JournalReader: could not create quarantine dir under #{dir} " <>
            "(#{inspect(mkdir_reason)}) — excluding incomplete segment #{seg} from replay"
        )

        false
    end
  end

  @doc """
  Read a sealed segment into structured frames, fail-closed. Check order
  (each is a typed refusal, first failure wins):

  1. `.seal` present? — else `{:not_sealed, path}`
  2. `.meta.json` present? — else `{:missing_meta, path}`
  3. manifest sha256 matches the segment bytes? — else `{:manifest_mismatch, ...}`
  4. per-frame: truncated tail/frame, scoped CRC, monotonic SeqID
  """
  @spec read_sealed_segment(Path.t()) :: {:ok, [frame()]} | refusal()
  def read_sealed_segment(seg_path) do
    with :ok <- require_file(seg_path <> ".seal", {:not_sealed, seg_path}),
         :ok <- require_file(seg_path <> ".meta.json", {:missing_meta, seg_path}),
         {:ok, bin} <- File.read(seg_path),
         :ok <- verify_manifest(seg_path <> ".meta.json", bin, seg_path) do
      parse_frames(bin, 0, nil, [])
    end
  end

  # -- private --

  defp require_file(path, refusal) do
    if File.regular?(path), do: :ok, else: {:error, refusal}
  end

  defp verify_manifest(meta_path, bin, seg_path) do
    with {:ok, body} <- File.read(meta_path),
         {:ok, %{"sha256" => hex}} when is_binary(hex) and hex != "" <- Jason.decode(body),
         {:ok, got} <- Base.decode16(hex, case: :mixed) do
      if :crypto.hash(:sha256, bin) == got do
        :ok
      else
        {:error, {:manifest_mismatch, path: seg_path, expected_sha256: hex}}
      end
    else
      _ -> {:error, {:manifest_mismatch, path: seg_path, reason: :unreadable_manifest}}
    end
  end

  defp parse_frames(bin, offset, prev_seq, acc) do
    have = byte_size(bin) - offset

    cond do
      have == 0 ->
        {:ok, Enum.reverse(acc)}

      have < @frame_hdr ->
        {:error, {:truncated_tail, offset: offset, have: have}}

      :else ->
        <<magic::binary-size(4), frame_len::unsigned-integer-size(32), _::binary>> =
          binary_part(bin, offset, have)

        cond do
          magic != @magic ->
            {:error, {:bad_magic, offset: offset}}

          frame_len < 4 ->
            # a frame_len smaller than the CRC field cannot tile a frame —
            # refusing here keeps decode_one/3's body_size non-negative
            {:error, {:truncated_frame, offset: offset, reason: :bad_frame_len, have: have}}

          true ->
            parse_frame_at(bin, offset, frame_len, prev_seq, acc)
        end
    end
  end

  # header already validated (magic + frame_len >= @crc_len) by parse_frames/4
  defp parse_frame_at(bin, offset, frame_len, prev_seq, acc) do
    have = byte_size(bin) - offset
    needed = @frame_hdr + frame_len

    if needed > have do
      {:error, {:truncated_frame, offset: offset, needed: needed, have: have}}
    else
      case decode_one(bin, offset, frame_len) do
        {:ok, frame} ->
          with :ok <- assert_monotonic(frame.seq_id, prev_seq, offset) do
            parse_frames(bin, offset + needed, frame.seq_id, [frame | acc])
          end

        {:error, :crc_mismatch} ->
          {:error, {:crc_mismatch, offset: offset}}

        {:error, :bad_lengths} ->
          {:error, {:truncated_frame, offset: offset, reason: :bad_lengths, have: have}}
      end
    end
  end

  # decode the frame at `offset` (sized by `frame_len`) into a structured map.
  # CRC is checked over the body exactly as the writer scoped it; the
  # structural length check (key_len/payload_len must tile the body exactly)
  # is a typed refusal, never a MatchError escape.
  defp decode_one(bin, offset, frame_len) do
    body_size = frame_len - 4

    <<_magic::binary-size(4), _fl::unsigned-integer-size(32),
      body::binary-size(^body_size)-unit(8), crc::unsigned-integer-size(32), _rest::binary>> =
      binary_part(bin, offset, @frame_hdr + frame_len)

    if :erlang.crc32(body) == crc do
      case extract_fields(body) do
        nil -> {:error, :bad_lengths}
        frame -> {:ok, frame}
      end
    else
      {:error, :crc_mismatch}
    end
  end

  defp extract_fields(body) do
    <<seq_id::unsigned-integer-size(64), ts::integer-size(64),
      event_type::unsigned-integer-size(16), table_id::unsigned-integer-size(16),
      key_len::unsigned-integer-size(32), key::binary-size(key_len)-unit(8),
      payload_len::unsigned-integer-size(32), payload::binary-size(payload_len)-unit(8),
      _::binary>> = body

    %{
      seq_id: seq_id,
      ts: ts,
      event_type: event_type,
      table_id: table_id,
      key: key,
      payload: payload
    }
  rescue
    MatchError -> nil
  end

  defp assert_monotonic(seq, prev_seq, _offset)
       when is_integer(prev_seq) and seq != prev_seq + 1 do
    {:error, {:seq_regression, expected: prev_seq + 1, got: seq}}
  end

  defp assert_monotonic(_seq, _prev, _offset), do: :ok
end
