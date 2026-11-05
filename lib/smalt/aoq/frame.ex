defmodule Smalt.Aoq.Frame do
  @moduledoc """
  AoQ wire frame codec (aq-architecture-spec §2/§3, LANE-13).

  Framing law: every frame is exactly `64` bytes of header followed by a
  body of at least 1 byte, so the total is ≥65 bytes — RefcBinary territory
  (`ERL_ONHEAP_BIN_LIMIT = 64`). Frame handoff between Listener, pool, and
  workers is pointer-passing, never a heap-bin copy.

  Egress law: `encode/1` returns an iolist `[header, payload]`, never a
  concatenation-appended flat binary. Writers (gen_tcp/ssl, file, Bandit adapter)
  consume iolists natively — scatter-gather straight into ErlIOVec, zero
  intermediate copy.
  """

  @header_size 64
  @min_body_size 1

  @doc "Fixed wire header size in bytes (spec §2)."
  @spec header_size() :: 64
  def header_size, do: @header_size

  @doc "Minimum body size in bytes (spec §2)."
  @spec min_body_size() :: 1
  def min_body_size, do: @min_body_size

  @typedoc "64-byte frame header. Always exactly 64 bytes on the wire."
  @type header :: binary()

  @typedoc "Frame body: at least 1 byte."
  @type body :: binary()

  @doc """
  Split a flat binary into `{header, body}`.

  Refuses frames smaller than 65 bytes total: a frame shorter than
  64B header + 1B body violates the >64B RefcBinary framing law (spec §2)
  and is a wire-format defect, not a short read.
  """
  @spec split(binary()) :: {:ok, header(), body()} | {:error, :short_frame}
  def split(bin) when is_binary(bin) do
    case bin do
      <<header::binary-size(64), body::binary>> when byte_size(body) >= 1 ->
        {:ok, header, body}

      _ ->
        {:error, :short_frame}
    end
  end

  @doc """
  Encode `{header, payload}` as an iolist `[header, payload]`.

  Payload must be ≥1 byte — a zero-length body would make a 64B total,
  which is a HeapBin. Returns `{:error, :empty_payload}` rather than
  emitting a frame that violates the framing law.
  """
  @spec encode(header(), body()) ::
          {:ok, iolist()} | {:error, :short_header | :empty_payload}
  def encode(header, payload)

  def encode(header, payload) when is_binary(header) and is_binary(payload) do
    if byte_size(header) == 64 do
      if byte_size(payload) >= 1 do
        {:ok, [header, payload]}
      else
        {:error, :empty_payload}
      end
    else
      {:error, :short_header}
    end
  end

  def encode(_, _), do: {:error, :short_header}
end
