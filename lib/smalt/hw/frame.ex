defmodule Smalt.Hw.Frame do
  @moduledoc """
  HIL wire codec — exact parity with workspace/lib/serial/gateway.ts:28-140
  (and smalt-cli/smalt_cli/hw/serial.py, itself TS-parity-witnessed).

  Frame: `[0x7E][len:u16 LE][payload][crc over body][0x7E]`, byte-stuffing
  0x7E -> 0x7D 0x5E, 0x7D -> 0x7D 0x5D (ESC_XOR = 0x20), CRC-16/CCITT-FALSE
  (poly 0x1021, init 0xFFFF, no reflection, no xorout) over [len:u16 LE][payload].
  Max payload 4096 bytes.

  Witness vector: CRC-16/CCITT-FALSE("123456789") == 0x29B1.
  """

  @flag 0x7E
  @esc 0x7D

  # Cross-lane unblock (S-1 compile-freeze SLA, disclosed in s1 receipt): the
  # `<<<`/`>>>` operators come from Bitwise; without this import the module
  # fails to compile and every lane's boot is frozen.
  import Bitwise
  @esc_xor 0x20
  @max_payload 4096

  @doc "Max payload bytes (gateway.ts MAX_PAYLOAD_BYTES)."
  def max_payload_bytes, do: @max_payload

  @doc """
  CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflection, no xorout).

  Witness vector: crc16("123456789") == 0x29B1.
  """
  def crc16(data, crc \\ 0xFFFF)

  def crc16(<<>>, crc), do: crc

  def crc16(<<byte, rest::binary>>, crc) do
    crc = Bitwise.bxor(crc, byte <<< 8)

    crc =
      Enum.reduce(1..8, crc, fn _, acc ->
        if Bitwise.band(acc, 0x8000) != 0 do
          Bitwise.band(Bitwise.bxor(acc <<< 1, 0x1021), 0xFFFF)
        else
          Bitwise.band(acc <<< 1, 0xFFFF)
        end
      end)

    crc16(rest, crc)
  end

  @doc "Witnessed self-test: crc16(\"123456789\") == 0x29B1."
  def self_test, do: crc16("123456789") == 0x29B1

  @doc """
  Encode one frame: [0x7E][len LE][payload][crc LE][0x7E], stuffed.
  Raises on payload > 4096 (parity with gateway.ts RangeError).
  """
  @spec encode(binary()) :: binary()
  def encode(payload) when is_binary(payload) do
    if byte_size(payload) > @max_payload do
      raise ArgumentError, "payload #{byte_size(payload)} > #{@max_payload}"
    end

    body = <<byte_size(payload)::little-integer-size(16), payload::binary>>
    crc = crc16(body)
    tail = <<body::binary, crc::little-integer-size(16)>>
    stuffed = stuff(tail, [])
    IO.iodata_to_binary([@flag, stuffed, @flag])
  end

  defp stuff(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp stuff(<<b, rest::binary>>, acc) when b == @flag or b == @esc do
    stuff(rest, [Bitwise.bxor(b, @esc_xor), @esc | acc])
  end

  defp stuff(<<b, rest::binary>>, acc), do: stuff(rest, [b | acc])

  @doc """
  Streaming deframer — mirrors gateway.ts FrameDecoder. Feed raw bytes with
  `push/2`; completed payloads accumulate; `take/1` drains them. Resynchronizes
  on the next 0x7E after any malformed frame: bad CRC or wrong length are
  silently dropped, exactly like the TS/Python decoders.
  """
  defstruct buf: <<>>, in_frame: false, escaped: false, frames: []

  @type t :: %__MODULE__{
          buf: binary(),
          in_frame: boolean(),
          escaped: boolean(),
          frames: [binary()]
        }

  def decoder, do: %__MODULE__{}

  @doc "Feed raw bytes into the deframer; returns the updated decoder."
  @spec push(t(), binary()) :: t()
  def push(%__MODULE__{} = d, chunk) when is_binary(chunk) do
    do_push(chunk, d)
  end

  defp do_push(<<>>, d), do: d

  defp do_push(<<@flag, rest::binary>>, d) do
    d =
      if d.in_frame and d.buf != <<>> do
        emit(d)
      else
        d
      end

    do_push(rest, %{d | in_frame: true, buf: <<>>, escaped: false})
  end

  defp do_push(<<_b, rest::binary>>, %{in_frame: false} = d) do
    do_push(rest, d)
  end

  defp do_push(<<@esc, rest::binary>>, d) do
    do_push(rest, %{d | escaped: true})
  end

  defp do_push(<<b, rest::binary>>, %{escaped: true} = d) do
    do_push(rest, %{d | buf: <<d.buf::binary, Bitwise.bxor(b, @esc_xor)>>, escaped: false})
  end

  defp do_push(<<b, rest::binary>>, d) do
    do_push(rest, %{d | buf: <<d.buf::binary, b>>})
  end

  defp emit(%{buf: raw} = d) do
    payload =
      with <<len::little-integer-size(16), rest::binary>> <- raw,
           <<body::binary-size(^len), crc::little-integer-size(16), _::binary>> <- rest,
           true <- byte_size(rest) == len + 2,
           true <- crc16(<<len::little-integer-size(16), body::binary>>) == crc do
        body
      else
        _ -> nil
      end

    frames = if payload, do: [payload | d.frames], else: d.frames
    %{d | frames: frames}
  end

  @doc "Drain completed payloads (oldest first); returns {payloads, decoder}."
  @spec take(t()) :: {[binary()], t()}
  def take(%__MODULE__{frames: frames} = d), do: {Enum.reverse(frames), %{d | frames: []}}
end
