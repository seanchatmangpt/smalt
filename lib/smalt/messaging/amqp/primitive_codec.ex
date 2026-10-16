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

  def encode(n) when is_integer(n) and n >= 0 and n <= 0xFFFF_FFFF_FFFF_FFFF do
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

  def encode(n) when is_integer(n) and n in -9_223_372_036_854_775_808..9_223_372_036_854_775_807 do
    if n in -128..127 do
      [0x55, <<n::signed-size(8)>>]
    else
      [0x81, <<n::signed-integer-size(64)>>]
    end
  end

  # Integers outside the 64-bit AMQP domain: the documented ArgumentError.
  # Previously the ulong/int64 clauses matched ANY non-negative/any integer
  # and the binary constructor silently truncated to the low 64 bits (2**128
  # encoded as 0x80 + eight zero bytes and decoded to 0 — lens-6 encode-path
  # differential finding).
  def encode(n) when is_integer(n),
    do: raise(ArgumentError, "integer out of AMQP 64-bit range: #{n}")

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
    # is_list/1 is true for improper lists; encoding one previously leaked a
    # FunctionClauseError out of Enum.map instead of the documented
    # ArgumentError (lens-6 encode-path differential finding).
    unless proper_list?(list),
      do: raise(ArgumentError, "cannot encode improper list as AMQP list: #{inspect(list, limit: 10)}")

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

  defp encode_descriptor(d) when is_integer(d) and d >= 0 and d <= 0xFFFF_FFFF_FFFF_FFFF,
    do: encode_ulong_descriptor(d)
  defp encode_descriptor({:symbol, bin}) when is_binary(bin), do: encode({:symbol, bin})

  # Plain-binary descriptors used to be accepted (bin -> encoded as symbol,
  # silently rewriting the term shape — the mirror of the lens-5 decode-side
  # finding: encode accepted a term shape it could not round-trip). Spec §1.6
  # allows ulong or symbol only; refused by the catch-all below.
  #
  # Out-of-domain descriptor (negative, >64-bit, atom, malformed tuple): the
  # documented ArgumentError, never a FunctionClauseError leak (lens-6
  # encode-path differential finding).
  defp encode_descriptor(other),
    do: raise(ArgumentError, "invalid AMQP descriptor: #{inspect(other)}")

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

  defp proper_list?([]), do: true
  defp proper_list?([_ | t]), do: proper_list?(t)
  defp proper_list?(_), do: false

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

  # decode_value/1 splits the constructor byte off (O(1) subbinary) and
  # dispatches to decode_typed/2, which takes the constructor separately.
  # decode_bare_elements rides decode_typed/2 directly: the old form rebuilt
  # `<<ctor, rest>>` per element — a full binary copy per element — making
  # bare-array decode O(n²) in bytes (a 1 MiB frame of ubyte elements took
  # ~14s of CPU; quadratic DoS via one transfer frame). With the constructor
  # known, each element is a single O(1) match and the whole array is linear.
  defp decode_value(<<ctor, rest::binary>>), do: decode_typed(ctor, rest)
  defp decode_value(<<>>), do: {:error, :truncated}
  defp decode_value(_), do: {:error, :invalid_constructor}

  # --- fixed single-byte constructors ---
  defp decode_typed(0x40, rest), do: {:ok, nil, rest}

  # boolean fast-paths (wire-lane fix, real-SDK census finding)
  defp decode_typed(0x41, rest), do: {:ok, true, rest}
  defp decode_typed(0x42, rest), do: {:ok, false, rest}
  defp decode_typed(0x45, rest), do: {:ok, [], rest}
  defp decode_typed(0x43, rest), do: {:ok, 0, rest}
  defp decode_typed(0x44, rest), do: {:ok, 0, rest}

  # Boolean wire form is 0x00/0x01 only (spec §1.6.8). The previous clause
  # decoded ANY byte as `b == 0x01`, silently rewriting out-of-domain wire
  # (0xFF) as `false` — the decode-path twin of the encode-side silent
  # truncation class (lens-7 finding). Out-of-domain byte now falls through
  # to the tagged-error catch-all.
  defp decode_typed(0x56, <<0x00, rest::binary>>), do: {:ok, false, rest}
  defp decode_typed(0x56, <<0x01, rest::binary>>), do: {:ok, true, rest}

  # --- fixed-width numerics ---
  defp decode_typed(0x50, <<n, rest::binary>>), do: {:ok, n, rest}
  defp decode_typed(0x51, <<n::signed-size(8), rest::binary>>), do: {:ok, n, rest}
  defp decode_typed(0x52, <<n, rest::binary>>), do: {:ok, n, rest}
  defp decode_typed(0x53, <<n, rest::binary>>), do: {:ok, n, rest}
  defp decode_typed(0x54, <<n::signed-size(8), rest::binary>>), do: {:ok, n, rest}
  defp decode_typed(0x55, <<n::signed-size(8), rest::binary>>), do: {:ok, n, rest}
  defp decode_typed(0x60, <<n::unsigned-integer-size(16), rest::binary>>), do: {:ok, n, rest}
  defp decode_typed(0x61, <<n::signed-integer-size(16), rest::binary>>), do: {:ok, n, rest}
  defp decode_typed(0x70, <<n::unsigned-integer-size(32), rest::binary>>), do: {:ok, n, rest}
  defp decode_typed(0x71, <<n::signed-integer-size(32), rest::binary>>), do: {:ok, n, rest}
  defp decode_typed(0x72, <<f::float-size(32), rest::binary>>), do: {:ok, f, rest}
  defp decode_typed(0x80, <<n::unsigned-integer-size(64), rest::binary>>), do: {:ok, n, rest}
  defp decode_typed(0x81, <<n::signed-integer-size(64), rest::binary>>), do: {:ok, n, rest}
  defp decode_typed(0x82, <<f::float-size(64), rest::binary>>), do: {:ok, f, rest}
  defp decode_typed(0x83, <<ms::signed-integer-size(64), rest::binary>>), do: {:ok, {:timestamp, ms}, rest}
  defp decode_typed(0x98, <<uuid::binary-size(16), rest::binary>>), do: {:ok, {:uuid, uuid}, rest}

  # --- variable-length: bin/str/sym in 8- and 32-bit forms ---
  defp decode_typed(ctor, <<len, rest::binary>>) when ctor in 0xA0..0xA3,
    do: take_var(rest, len, ctor)

  defp decode_typed(ctor, <<len::unsigned-integer-size(32), rest::binary>>)
       when ctor in 0xB0..0xB3,
       do: take_var(rest, len, ctor)

  # --- compound containers ---
  defp decode_typed(ctor, <<size, rest::binary>>) when ctor in 0xC0..0xC1 or ctor == 0xE0,
    do: take_compound(rest, size, ctor)

  defp decode_typed(ctor, <<size::unsigned-integer-size(32), rest::binary>>)
       when ctor in 0xD0..0xD1 or ctor == 0xF0,
       do: take_compound(rest, size, ctor)

  # --- described type (descriptor validated: spec §1.6 ulong or symbol —
  # see check_descriptor below for the lens-5 finding) ---
  defp decode_typed(0x00, rest) do
    with {:ok, descriptor, rest} <- decode_value(rest),
         :ok <- check_descriptor(descriptor),
         {:ok, value, rest} <- decode_value(rest) do
      {:ok, {:described, descriptor, value}, rest}
    end
  end

  # Bad constructor or a body truncated below the fixed width — same tagged
  # error the pre-refactor catch-all clause returned (fuzz corpus depends on it).
  defp decode_typed(_ctor, _rest), do: {:error, :invalid_constructor}

  # Descriptor validation for the described type (spec §1.6: ulong or symbol).
  # A lenient string-form descriptor (str8/str32/vbin ctor in the descriptor
  # slot) decoded to a plain binary — an undocumented term shape the encode
  # side cannot re-emit (re-encode minted a symbol, silently rewriting remote
  # data; lens-5 re-encode-stability finding). Refuse with a tagged error.
  # Grouped AFTER the decode_typed clauses to keep that clause group contiguous.
  defp check_descriptor(d) when is_integer(d), do: :ok
  defp check_descriptor({:symbol, b}) when is_binary(b), do: :ok
  defp check_descriptor(d), do: throw({:bad_descriptor, d})

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

    # Map count is ambiguous on the wire: pair-count (spec-literal: count =
    # number of pairs, body holds count*2 items) or element-count (2 x pairs —
    # what rhea/Azure write; see encode/1: count = body item count). Decode the
    # body ONCE and disambiguate by item-count arithmetic — the previous
    # probe-then-retry form decoded every inbound rhea-form map twice (a 1 MiB
    # application-properties map paid double CPU; lens-2 cycle-2 finding).
    case decode_all_items(rest, []) do
      {:ok, items, <<>>} ->
        m = length(items)

        cond do
          # pair-count form: count pairs on the wire
          m == count * 2 -> {:ok, to_map(items), <<>>}
          # element-count form: count IS the kv item count, must be even
          m == count and rem(count, 2) == 0 -> {:ok, to_map(items), <<>>}
          true -> {:error, :invalid_length}
        end

      {:ok, _, _} ->
        {:error, :invalid_length}

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

  # Decode items until the body is exhausted (map disambiguation: the item
  # count itself is the discriminator, so no count-guided retry).
  defp decode_all_items(<<>>, acc), do: {:ok, Enum.reverse(acc), <<>>}

  defp decode_all_items(body, acc) do
    case decode_value(body) do
      {:ok, value, rest} -> decode_all_items(rest, [value | acc])
      {:error, reason} -> {:error, reason}
    end
  end

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
    case decode_typed(ctor, rest) do
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

  # Declared count exceeds the elements the (size-exact) body can hold: this
  # is a truncated/malformed compound. Returning the partial list as success
  # masked truncation as a short list (fuzz-class defect).
  defp decode_count(<<>>, count, _acc) when count > 0, do: {:error, :truncated}

  defp to_map(kv) do
    kv
    |> Enum.chunk_every(2)
    |> Map.new(fn
      [k, v] -> {k, v}
    end)
  end
end
