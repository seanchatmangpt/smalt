defmodule Smalt.Amqp.PrimitiveCodec do
  @moduledoc """
  Pure-function AMQP 1.0 type-system codec (spec section 1.6).

  Encodes Elixir terms to AMQP constructor-formatted iodata and decodes
  binaries back, byte-exact against the AMQP 1.0 OASIS spec.

  Elixir mapping:

  | AMQP type   | Elixir term            |
  |-------------|------------------------|
  | null        | `nil`                  |
  | boolean     | `true` / `false`       |
  | ubyte..long | integers (range-checked) |
  | float/double| floats                 |
  | binary      | binaries               |
  | string      | binaries (utf8)        |
  | symbol      | `{:symbol, binary}`    |
  | uuid        | `{:uuid, <<_::128>>}`  |
  | timestamp   | `{:timestamp, ms_int}` |
  | list        | lists                  |
  | map         | maps                   |
  | array       | `{:array, list}` (uniform element type) |
  | described   | `{:described, descriptor, value}` |

  Descriptor is an integer (ulong form) or `{:symbol, binary}`.
  """

  @type term_or_error :: {:ok, term, binary} | {:error, atom}

  # ===========================================================================
  # Encoding
  # ===========================================================================

  @spec encode(term) :: iodata
  def encode(nil), do: [0x40]
  def encode(true), do: [0x56, 0x01]
  def encode(false), do: [0x56, 0x00]

  # NOTE: non-negative integers encode as uint/ulong and negative integers as
  # int/long; the narrower ubyte/ushort/byte/short constructors have no native
  # Elixir type to select them and are decode-only.

  # --- fixed-width unsigned ---
  def encode(n) when is_integer(n) and n >= 0 and n <= 0xFFFF_FFFF do
    if n == 0 do
      [0x43]
    else
      if n <= 255 do
        [0x52, n]
      else
        [0x70, <<n::unsigned-integer-size(32)>>]
      end
    end
  end

  def encode(n) when is_integer(n) and n >= 0 do
    if n == 0 do
      [0x44]
    else
      if n <= 255 do
        [0x53, n]
      else
        [0x80, <<n::unsigned-integer-size(64)>>]
      end
    end
  end

  # --- fixed-width signed ---
  def encode(n) when is_integer(n) and n in -2_147_483_648..2_147_483_647 do
    if n in -128..127 do
      [0x54, <<n::signed-size(8)>>]
    else
      [0x71, <<n::signed-integer-size(32)>>]
    end
  end

  def encode(n) when is_integer(n) do
    if n in -128..127 do
      [0x55, <<n::signed-size(8)>>]
    else
      [0x81, <<n::signed-integer-size(64)>>]
    end
  end

  # --- floating point ---
  def encode(f) when is_float(f), do: [0x82, <<f::float-size(64)>>]

  # --- binary / string / symbol ---
  # vbin: explicit binary (0xA0/0xB0) — same decode shape as str8/str32 (a
  # plain binary), but rhea keeps it a Buffer instead of a JS string.
  def encode({:vbin, bin}) when is_binary(bin) do
    if byte_size(bin) <= 255 do
      [0xA0, byte_size(bin), bin]
    else
      [0xB0, <<byte_size(bin)::unsigned-integer-size(32)>>, bin]
    end
  end

  def encode(bin) when is_binary(bin) do
    len = byte_size(bin)

    if len <= 255 do
      [0xA1, len, bin]
    else
      [0xB1, <<len::unsigned-integer-size(32)>>, bin]
    end
  end

  def encode({:symbol, bin}) when is_binary(bin) do
    len = byte_size(bin)

    if len <= 255 do
      [0xA3, len, bin]
    else
      [0xB3, <<len::unsigned-integer-size(32)>>, bin]
    end
  end

  def encode({:uuid, <<_::128>> = uuid}), do: [0x98, uuid]

  def encode({:timestamp, ms}) when is_integer(ms) and ms in -9_223_372_036_854_775_808..9_223_372_036_854_775_807,
    do: [0x83, <<ms::signed-integer-size(64)>>]

  # --- collections ---
  def encode([]), do: [0x45]

  def encode(list) when is_list(list) do
    body = Enum.map(list, &encode/1)
    count = length(list)
    # wire size covers everything after the size field, including the count field
    body_len = IO.iodata_length(body)

    if body_len + 1 <= 255 and count <= 255 do
      [0xC0, body_len + 1, count, body]
    else
      [0xD0, <<(body_len + 4)::unsigned-integer-size(32)>>, <<count::unsigned-integer-size(32)>>, body]
    end
  end

  def encode(map) when is_map(map) do
    body =
      map
      |> Enum.flat_map(fn {k, v} -> [encode(k), encode(v)] end)

    body_len = IO.iodata_length(body)

    # Map count = number of KEYS AND VALUES (2 x pairs), the form rhea/Azure
    # write and expect. rhea's Reader.read_compound reads `count` items for
    # maps (types.js), so the pair-count form makes rhea read only the keys
    # and misalign every following section (census wire finding: the SDK
    # never saw our CBS reply's application-properties).
    count = 2 * map_size(map)

    if body_len + 1 <= 255 and count <= 255 do
      [0xC1, body_len + 1, count, body]
    else
      [0xD1, <<(body_len + 4)::unsigned-integer-size(32)>>, <<count::unsigned-integer-size(32)>>, body]
    end
  end

  def encode({:array, list} = t) when is_list(list) do
    if list == [] do
      [0xE0, 1, 0]
    else
      encoded = Enum.map(list, &encode/1)
      [element | rest] = encoded
      ctor = constructor_byte(element)

      unless ctor != nil and Enum.all?(rest, &(constructor_byte(&1) == ctor)) do
        raise ArgumentError,
              "AMQP array elements must share one constructor: #{inspect(t)}"
      end

      # wire form: element constructor once, then bare element values;
      # size covers the element constructor byte plus bare bodies
      bodies = Enum.map(encoded, &tl/1)
      body_len = IO.iodata_length(bodies)
      count = length(list)

      if body_len + 2 <= 255 and count <= 255 do
        [0xE0, body_len + 2, count, ctor, bodies]
      else
        [
          0xF0,
          <<(body_len + 5)::unsigned-integer-size(32)>>,
          <<count::unsigned-integer-size(32)>>,
          ctor,
          bodies
        ]
      end
    end
  end

  # --- described type: 0x00 descriptor value ---
  # rhea reads the map count as the number of keys AND values (2 x pairs);
  # the default encode/1 above writes the pair count, which corrupts every
  # odd-sized map for rhea-based clients (s5_sessions e2e lane finding).
  def encode({:map_rhea, map}) when is_map(map) do
    body = map |> Enum.flat_map(fn {k, v} -> [encode(k), encode(v)] end)
    body_len = IO.iodata_length(body)
    count = 2 * map_size(map)

    if body_len + 1 <= 255 and count <= 255 do
      [0xC1, body_len + 1, count, body]
    else
      [0xD1, <<(body_len + 4)::unsigned-integer-size(32)>>, <<count::unsigned-integer-size(32)>>, body]
    end
  end

  def encode({:described, descriptor, value}) do
    [0x00, encode_descriptor(descriptor), encode(value)]
  end

  def encode(other) do
    raise ArgumentError, "cannot encode as AMQP type: #{inspect(other)}"
  end

  defp encode_descriptor(d) when is_integer(d) and d >= 0, do: encode_ulong_descriptor(d)
  defp encode_descriptor({:symbol, bin}) when is_binary(bin), do: encode({:symbol, bin})
  defp encode_descriptor(bin) when is_binary(bin), do: encode({:symbol, bin})

  defp encode_ulong_descriptor(d) do
    if d == 0 do
      [0x44]
    else
      if d <= 255 do
        [0x53, d]
      else
        [0x80, <<d::unsigned-integer-size(64)>>]
      end
    end
  end

  defp constructor_byte([ctor | _]) when is_integer(ctor), do: ctor
  defp constructor_byte(_), do: nil

  # ===========================================================================
  # Decoding
  # ===========================================================================

  @spec decode(binary) :: term_or_error
  def decode(bin) when is_binary(bin) do
    # fuzz-court: any malformed wire input returns a tagged error, never raises.
    try do
      decode_value(bin)
    catch
      :throw, reason -> {:error, reason}
    end
  end

  @spec decode_all(binary) :: {:ok, [term]} | {:error, atom}
  def decode_all(bin) when is_binary(bin), do: decode_all_loop(bin, [])

  defp decode_all_loop(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_all_loop(bin, acc) do
    try do
      decode_value(bin)
    catch
      :throw, reason -> {:error, reason}
    end
    |> case do
      {:ok, value, rest} -> decode_all_loop(rest, [value | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  # --- fixed single-byte constructors ---
  defp decode_value(<<0x40, rest::binary>>), do: {:ok, nil, rest}

  # boolean fast-paths (wire-lane fix, real-SDK census finding)
  defp decode_value(<<0x41, rest::binary>>), do: {:ok, true, rest}
  defp decode_value(<<0x42, rest::binary>>), do: {:ok, false, rest}
  defp decode_value(<<0x45, rest::binary>>), do: {:ok, [], rest}
  defp decode_value(<<0x43, rest::binary>>), do: {:ok, 0, rest}
  defp decode_value(<<0x44, rest::binary>>), do: {:ok, 0, rest}

  defp decode_value(<<0x56, b, rest::binary>>),
    do: {:ok, b == 0x01, rest}

  # --- fixed-width numerics ---
  defp decode_value(<<0x50, n, rest::binary>>), do: {:ok, n, rest}
  defp decode_value(<<0x51, n::signed-size(8), rest::binary>>), do: {:ok, n, rest}
  defp decode_value(<<0x52, n, rest::binary>>), do: {:ok, n, rest}
  defp decode_value(<<0x53, n, rest::binary>>), do: {:ok, n, rest}
  defp decode_value(<<0x54, n::signed-size(8), rest::binary>>), do: {:ok, n, rest}
  defp decode_value(<<0x55, n::signed-size(8), rest::binary>>), do: {:ok, n, rest}
  defp decode_value(<<0x60, n::unsigned-integer-size(16), rest::binary>>), do: {:ok, n, rest}

  defp decode_value(<<0x61, n::signed-integer-size(16), rest::binary>>),
    do: {:ok, n, rest}

  defp decode_value(<<0x70, n::unsigned-integer-size(32), rest::binary>>), do: {:ok, n, rest}

  defp decode_value(<<0x71, n::signed-integer-size(32), rest::binary>>),
    do: {:ok, n, rest}

  defp decode_value(<<0x72, f::float-size(32), rest::binary>>), do: {:ok, f, rest}

  defp decode_value(<<0x80, n::unsigned-integer-size(64), rest::binary>>),
    do: {:ok, n, rest}

  defp decode_value(<<0x81, n::signed-integer-size(64), rest::binary>>),
    do: {:ok, n, rest}

  defp decode_value(<<0x82, f::float-size(64), rest::binary>>), do: {:ok, f, rest}

  defp decode_value(<<0x83, ms::signed-integer-size(64), rest::binary>>),
    do: {:ok, {:timestamp, ms}, rest}

  defp decode_value(<<0x98, uuid::binary-size(16), rest::binary>>),
    do: {:ok, {:uuid, uuid}, rest}

  # --- variable-length: bin/str/sym in 8- and 32-bit forms ---
  defp decode_value(<<ctor, len, rest::binary>>) when ctor in 0xA0..0xA3 do
    take_var(rest, len, ctor)
  end

  defp decode_value(<<ctor, len::unsigned-integer-size(32), rest::binary>>)
       when ctor in 0xB0..0xB3 do
    take_var(rest, len, ctor)
  end

  # --- compound containers ---
  defp decode_value(<<ctor, size, rest::binary>>) when ctor in 0xC0..0xC1 or ctor in 0xE0..0xE0 do
    take_compound(rest, size, ctor)
  end

  defp decode_value(<<ctor, size::unsigned-integer-size(32), rest::binary>>)
       when ctor in 0xD0..0xD1 or ctor in 0xF0..0xF0 do
    take_compound(rest, size, ctor)
  end

  # --- described type ---
  defp decode_value(<<0x00, rest::binary>>) do
    with {:ok, descriptor, rest} <- decode_value(rest) do
      with {:ok, value, rest} <- decode_value(rest) do
        {:ok, {:described, descriptor, value}, rest}
      end
    end
  end

  defp decode_value(<<>>), do: {:error, :truncated}
  defp decode_value(_), do: {:error, :invalid_constructor}

  defp take_var(rest, len, ctor) do
    case rest do
      <<body::binary-size(len), rest::binary>> ->
        {:ok, var_value(ctor, body), rest}

      _ ->
        {:error, :truncated}
    end
  end

  defp var_value(ctor, body) when ctor in [0xA0, 0xB0], do: body
  # 0xA2/0xB2 are non-standard str-variants some producers emit; decode
  # leniently as utf8 strings instead of raising (fuzz-court finding).
  defp var_value(ctor, body) when ctor in [0xA1, 0xA2, 0xB1, 0xB2], do: body
  defp var_value(ctor, body) when ctor in [0xA3, 0xB3], do: {:symbol, body}

  defp take_compound(rest, size, ctor) do
    case rest do
      <<body::binary-size(size), rest::binary>> ->
        case compound_value(ctor, body) do
          # thread the unconsumed tail to the caller (connection-lane fix:
          # dropping `_rest` broke decoding any compound followed by more bytes)
          {:ok, value, <<>>} -> {:ok, value, rest}
          other -> other
        end

      _ ->
        {:error, :truncated}
    end
  end

  defp compound_value(ctor, body) when ctor in [0xC0, 0xD0] do
    {count, rest} = take_count(body, ctor)

    case decode_count(rest, count, []) do
      {:ok, items, <<>>} -> {:ok, items, <<>>}
      {:ok, _, _} -> {:error, :invalid_length}
      {:error, reason} -> {:error, reason}
    end
  end

  defp compound_value(ctor, body) when ctor in [0xC1, 0xD1] do
    {count, rest} = take_count(body, ctor)

    # Map count is ambiguous on the wire: pair-count (spec-literal) or
    # element-count (2 x pairs — what rhea/Azure write; see encode/1). Decode
    # both: try element-count first, fall back to pair-count, require an even
    # item list either way (wire-lane reconciliation).
    with {:error, _} <- decode_count(rest, count * 2, []),
         {:ok, kv, tail} <- decode_count(rest, count, []) do
      _ = tail

      if rem(length(kv), 2) == 0, do: {:ok, to_map(kv), <<>>}, else: {:error, :invalid_length}
    else
      {:ok, kv, _} ->
        if rem(length(kv), 2) == 0, do: {:ok, to_map(kv), <<>>}, else: {:error, :invalid_length}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp compound_value(ctor, body) when ctor in [0xE0, 0xF0] do
    {count, rest} = take_count(body, ctor)

    if count == 0 do
      {:ok, {:array, []}, <<>>}
    else
      case rest do
      <<element_ctor, element_rest::binary>> ->
        case decode_bare_elements(element_rest, element_ctor, count, []) do
          {:ok, items, <<>>} -> {:ok, {:array, items}, <<>>}
          {:ok, _, _} -> {:error, :invalid_length}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :truncated}
      end
    end
  end

  defp compound_value(_, _), do: {:error, :truncated}

  # count field width follows the constructor family: 8-bit forms carry one
  # byte, 32-bit forms carry four
  defp take_count(<<count, rest::binary>>, ctor) when ctor in [0xC0, 0xC1, 0xE0],
    do: {count, rest}

  defp take_count(<<count::unsigned-integer-size(32), rest::binary>>, ctor)
       when ctor in [0xD0, 0xD1, 0xF0],
       do: {count, rest}

  # Malformed count constructor (fuzz-court finding): refuse, never raise.
  defp take_count(_body, ctor) when ctor in 0xC0..0xF0, do: throw({:bad_count, ctor})
  defp take_count(_body, _ctor), do: throw(:bad_constructor)

  defp decode_bare_elements(rest, ctor, count, acc) when count > 0 do
    case decode_value(<<ctor, rest::binary>>) do
      {:ok, value, rest} -> decode_bare_elements(rest, ctor, count - 1, [value | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_bare_elements(rest, _ctor, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp decode_count(body, count, acc) when count > 0 and body != <<>> do
    case decode_value(body) do
      {:ok, value, rest} -> decode_count(rest, count - 1, [value | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_count(body, 0, acc), do: {:ok, Enum.reverse(acc), body}
  defp decode_count(<<>>, _count, acc), do: {:ok, Enum.reverse(acc), <<>>}

  defp to_map(kv) do
    kv
    |> Enum.chunk_every(2)
    |> Map.new(fn
      [k, v] -> {k, v}
      [k] -> {k, nil}
    end)
  end
end
