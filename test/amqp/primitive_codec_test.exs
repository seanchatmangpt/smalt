defmodule Smalt.Amqp.PrimitiveCodecTest do
  use ExUnit.Case, async: true

  alias Smalt.Amqp.PrimitiveCodec

  defp roundtrip(term) do
    io = PrimitiveCodec.encode(term)
    bin = IO.iodata_to_binary(io)

    assert {:ok, decoded, <<>>} = PrimitiveCodec.decode(bin)
    assert decoded == term
    bin
  end

  defp cut_range(bin) when byte_size(bin) <= 1, do: []
  defp cut_range(bin), do: Range.new(1, byte_size(bin) - 1, 1)

  describe "null / boolean" do
    test "null is 0x40" do
      assert IO.iodata_to_binary(PrimitiveCodec.encode(nil)) == <<0x40>>
      roundtrip(nil)
    end

    test "boolean compact form 0x56" do
      assert IO.iodata_to_binary(PrimitiveCodec.encode(true)) == <<0x56, 0x01>>
      assert IO.iodata_to_binary(PrimitiveCodec.encode(false)) == <<0x56, 0x00>>
      roundtrip(true)
      roundtrip(false)
    end

    test "decode boolean golden 0x56 with any nonzero payload is ambiguous per spec but 0x00/0x01 accepted" do
      assert {:ok, true, <<>>} = PrimitiveCodec.decode(<<0x56, 0x01>>)
      assert {:ok, false, <<>>} = PrimitiveCodec.decode(<<0x56, 0x00>>)
    end
  end

  describe "unsigned integers" do
    test "ubyte 0x50 decode-only" do
      assert {:ok, 200, <<>>} = PrimitiveCodec.decode(<<0x50, 200>>)
      roundtrip(0)
      roundtrip(255)
    end

    test "ushort 0x60 decode-only" do
      assert {:ok, 0x1234, <<>>} = PrimitiveCodec.decode(<<0x60, 0x12, 0x34>>)
      roundtrip(0)
      roundtrip(65_535)
    end

    test "uint: zero form 0x43, small form 0x52, wide form 0x70" do
      assert IO.iodata_to_binary(PrimitiveCodec.encode(0)) == <<0x43>>
      assert IO.iodata_to_binary(PrimitiveCodec.encode(7)) == <<0x52, 7>>

      assert IO.iodata_to_binary(PrimitiveCodec.encode(1000)) ==
               <<0x70, 0x00, 0x00, 0x03, 0xE8>>

      roundtrip(4_294_967_295)
    end

    test "ulong: small form 0x53, wide form 0x80 (zero uses uint 0x43 form)" do
      # 0 has one native integer type: encodes as the uint zero form 0x43
      assert IO.iodata_to_binary(PrimitiveCodec.encode(0)) == <<0x43>>
      assert {:ok, 0, <<>>} = PrimitiveCodec.decode(<<0x44>>)
      # small positive ints take the uint small form; 0x53 is decode-only
      assert IO.iodata_to_binary(PrimitiveCodec.encode(9)) == <<0x52, 9>>
      assert {:ok, 9, <<>>} = PrimitiveCodec.decode(<<0x53, 9>>)

      # small positive ints take uint forms; 0x80 only for > 32-bit values
      assert IO.iodata_to_binary(PrimitiveCodec.encode(0x01_00)) ==
               <<0x70, 0, 0, 1, 0>>

      assert IO.iodata_to_binary(PrimitiveCodec.encode(0x1_0000_0000)) ==
               <<0x80, 0, 0, 0, 1, 0, 0, 0, 0>>

      roundtrip(18_446_744_073_709_551_615)
    end
  end

  describe "signed integers" do
    test "byte 0x51 / short 0x61 decode-only" do
      assert {:ok, -1, <<>>} = PrimitiveCodec.decode(<<0x51, 0xFF>>)
      assert {:ok, -2, <<>>} = PrimitiveCodec.decode(<<0x61, 0xFF, 0xFE>>)
      roundtrip(-128)
      roundtrip(127)
      roundtrip(-32_768)
      roundtrip(32_767)
    end

    test "int: small form 0x54, wide form 0x71" do
      assert IO.iodata_to_binary(PrimitiveCodec.encode(-5)) == <<0x54, 0xFB>>

      assert IO.iodata_to_binary(PrimitiveCodec.encode(-70_000)) ==
               <<0x71, 0xFF, 0xFE, 0xEE, 0x90>>

      roundtrip(-2_147_483_648)
      roundtrip(2_147_483_647)
    end

    test "long: wide form 0x81 (small long 0x55 is decode-only)" do
      # negative small ints take the smallint form 0x54; 0x55 is decode-only
      assert IO.iodata_to_binary(PrimitiveCodec.encode(-9)) == <<0x54, 0xF7>>
      assert {:ok, -9, <<>>} = PrimitiveCodec.decode(<<0x55, 0xF7>>)

      assert IO.iodata_to_binary(PrimitiveCodec.encode(-5_000_000_000)) ==
               <<0x81, 0xFF, 0xFF, 0xFF, 0xFE, 0xD5, 0xFA, 0x0E, 0x00>>

      roundtrip(9_223_372_036_854_775_807)
      roundtrip(-9_223_372_036_854_775_808)
    end
  end

  describe "floating point" do
    test "double 0x82 round-trips; float 0x72 decodes" do
      roundtrip(3.14159)
      roundtrip(-0.5)

      assert {:ok, 1.5, <<>>} =
               PrimitiveCodec.decode(<<0x72, 0x3F, 0xC0, 0x00, 0x00>>)
    end
  end

  describe "binary / string / symbol" do
    test "short string 0xA1 and long string 0xB1" do
      assert IO.iodata_to_binary(PrimitiveCodec.encode("hi")) == <<0xA1, 2, "h", "i">>
      roundtrip("hello, amqp")

      long = String.duplicate("x", 300)
      bin = roundtrip(long)
      assert <<0xB1, len::unsigned-integer-size(32), _::binary>> = bin
      assert len == 300
    end

    test "binary uses 0xA0/0xB0" do
      roundtrip(<<1, 2, 3, 255>>)
      long = :binary.copy(<<0xAB>>, 300)
      bin = roundtrip(long)
      # native binaries take the string constructor family (0xA1/0xB1)
      assert <<0xB1, len::unsigned-integer-size(32), _::binary>> = bin
      assert len == 300
    end

    test "symbol uses 0xA3/0xB3 and decodes to {:symbol, _}" do
      assert IO.iodata_to_binary(PrimitiveCodec.encode({:symbol, "aq"})) ==
               <<0xA3, 2, "a", "q">>

      roundtrip({:symbol, "com.microsoft:renew-lock"})

      long = String.duplicate("s", 300)
      bin = roundtrip({:symbol, long})
      assert <<0xB3, len::unsigned-integer-size(32), _::binary>> = bin
      assert len == 300
    end
  end

  describe "uuid and timestamp" do
    test "uuid 0x98, 16 bytes" do
      uuid = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>

      assert IO.iodata_to_binary(PrimitiveCodec.encode({:uuid, uuid})) ==
               [0x98 | uuid] |> IO.iodata_to_binary()

      roundtrip({:uuid, uuid})
    end

    test "timestamp 0x83, signed 64-bit ms" do
      ms = 1_697_000_000_000

      assert IO.iodata_to_binary(PrimitiveCodec.encode({:timestamp, ms})) ==
               <<0x83, 0x00, 0x00, 0x01, 0x8B, 0x1D, 0x15, 0x0A, 0x00>>

      roundtrip({:timestamp, ms})
      roundtrip({:timestamp, -1})
    end
  end

  describe "list" do
    test "empty list 0x45" do
      assert IO.iodata_to_binary(PrimitiveCodec.encode([])) == <<0x45>>
      roundtrip([])
    end

    test "list8 0xC0 golden bytes" do
      assert IO.iodata_to_binary(PrimitiveCodec.encode([1, "a"])) ==
               <<0xC0, 6, 2, 0x52, 1, 0xA1, 1, "a">>

      roundtrip([1, "two", {:symbol, "sym"}, nil, true, -3, 4.5])
    end

    test "list32 0xD0 when >255 bytes" do
      long = List.duplicate(String.duplicate("y", 20), 20)
      bin = roundtrip(long)

      assert <<0xD0, size::unsigned-integer-size(32), count::unsigned-integer-size(32),
               _::binary>> = bin

      assert count == 20
      assert size == byte_size(bin) - 5
    end
  end

  describe "map" do
    test "map8 0xC1 golden bytes" do
      assert IO.iodata_to_binary(PrimitiveCodec.encode(%{"k" => 1})) ==
               <<0xC1, 6, 2, 0xA1, 1, "k", 0x52, 1>>

      roundtrip(%{"statusCode" => 200, "statusDescription" => "OK", "n" => nil})
    end

    test "map32 0xD1 when >255 bytes" do
      big = Map.new(0..30, fn i -> {"key#{i}", String.duplicate("v", 20)} end)
      bin = roundtrip(big)

      assert <<0xD1, size::unsigned-integer-size(32), count::unsigned-integer-size(32),
               _::binary>> = bin

      assert count == 62
      assert size == byte_size(bin) - 5
    end
  end

  describe "array" do
    test "array8 0xE0 with uniform constructors" do
      assert IO.iodata_to_binary(PrimitiveCodec.encode({:array, [1, 2, 3]})) ==
               <<0xE0, 5, 3, 0x52, 1, 2, 3>>

      # element constructor byte emitted once, then bare element bodies

      roundtrip({:array, [1, 2, 3]})
      roundtrip({:array, []})
    end

    test "array32 0xF0 when >255 bytes" do
      bin = roundtrip({:array, List.duplicate(String.duplicate("a", 20), 50)})

      assert <<0xF0, size::unsigned-integer-size(32), count::unsigned-integer-size(32),
               _::binary>> = bin

      assert count == 50
      assert size == byte_size(bin) - 5
    end

    test "mixed-type array raises" do
      assert_raise ArgumentError, ~r/share one constructor/, fn ->
        PrimitiveCodec.encode({:array, [1, "a"]})
      end
    end
  end

  describe "described types" do
    test "0x00 + ulong descriptor + value" do
      assert IO.iodata_to_binary(PrimitiveCodec.encode({:described, 0x23, "hi"})) ==
               <<0x00, 0x53, 0x23, 0xA1, 2, "h", "i">>

      roundtrip({:described, 0x23, "hi"})
    end

    test "symbolic descriptor (open performative style)" do
      roundtrip({:described, {:symbol, "amqp:open:list"}, [1, 2, 3]})
    end

    test "nested described round-trip" do
      roundtrip({:described, 0x13, {:described, 0x28, [1]}})
    end

    # Lens-5 re-encode-stability finding: a string-form descriptor (str8 ctor
    # in the descriptor slot) decoded to a plain binary — an undocumented term
    # shape encode/1 cannot re-emit (re-encode minted a symbol, silently
    # rewriting remote data). Spec §1.6: the descriptor is ulong or symbol.
    @tag :amqp_wire
    test "string-form described descriptor is refused, never mints a binary descriptor (lens-5)" do
      # str8 descriptor + null value
      assert {:error, {:bad_descriptor, "vbin-not-legal"}} =
               PrimitiveCodec.decode(<<0x00, 0xA1, 14, "vbin-not-legal"::binary, 0x40>>)

      # vbin8 descriptor likewise
      assert {:error, {:bad_descriptor, <<1, 2, 3>>}} =
               PrimitiveCodec.decode(<<0x00, 0xA0, 3, 1, 2, 3, 0x40>>)

      # float descriptor likewise
      assert {:error, {:bad_descriptor, _}} =
               PrimitiveCodec.decode(<<0x00, 0x72, 0, 0, 0, 0, 0x40>>)

      # integer/symbol descriptors still decode; list containers still fine
      assert {:ok, {:described, 3, nil}, <<>>} = PrimitiveCodec.decode(<<0x00, 0x52, 3, 0x40>>)

      assert {:ok, {:described, {:symbol, "s"}, nil}, <<>>} =
               PrimitiveCodec.decode(<<0x00, 0xA3, 1, ?s, 0x40>>)
    end
  end

  describe "falsy composite fields (lane-107 fence)" do
    # Regression fence for the reported "encoder drops falsy fields" claim:
    # a detach with handle 0 / closed false must carry explicit typed zero /
    # boolean-false constructors in wire order — never dropped.
    test "detach [handle=0, closed=false] byte-exact per spec §1.6" do
      bin = IO.iodata_to_binary(PrimitiveCodec.encode({:described, 0x16, [0, false]}))

      # described 0x00 | ulong 0x53 0x16 | list8 0xC0, size 4, count 2
      # | uint0 0x43 | boolean 0x56 0x00
      assert bin == <<0x00, 0x53, 0x16, 0xC0, 0x04, 0x02, 0x43, 0x56, 0x00>>
      assert {:ok, {:described, 0x16, [0, false]}, <<>>} = PrimitiveCodec.decode(bin)
    end

    test "transfer [handle=0, delivery_id=0, settled=false] round-trips" do
      body = [0, 0, false]
      bin = IO.iodata_to_binary(PrimitiveCodec.encode({:described, 0x14, body}))
      assert {:ok, {:described, 0x14, ^body}, <<>>} = PrimitiveCodec.decode(bin)
    end
  end

  describe "decode_all" do
    test "decodes concatenated values" do
      bin =
        IO.iodata_to_binary([
          PrimitiveCodec.encode(1),
          PrimitiveCodec.encode("a"),
          PrimitiveCodec.encode(nil)
        ])

      assert {:ok, [1, "a", nil]} = PrimitiveCodec.decode_all(bin)
    end

    test "empty input yields empty list" do
      assert {:ok, []} = PrimitiveCodec.decode_all(<<>>)
    end

    test "propagates errors" do
      assert {:error, :invalid_constructor} = PrimitiveCodec.decode_all(<<0xFF>>)
    end
  end

  describe "truncated input" do
    test "every truncated encoding errors cleanly, never raises" do
      terms = [
        nil,
        true,
        200,
        1000,
        100_000,
        -5,
        -70_000,
        3.25,
        "hello",
        {:symbol, "sym"},
        {:uuid, <<0::128>>},
        {:timestamp, 1_697_000_000_000},
        [1, 2, "three"],
        %{"a" => 1},
        {:array, [1, 2]},
        {:described, 0x23, "x"}
      ]

      for term <- terms do
        bin = IO.iodata_to_binary(PrimitiveCodec.encode(term))

        for cut <- cut_range(bin) do
          assert {:error, _} = PrimitiveCodec.decode(binary_part(bin, 0, cut))
        end
      end
    end

    test "overlong length prefix errors" do
      assert {:error, :truncated} = PrimitiveCodec.decode(<<0xA1, 10, "abc">>)
      assert {:error, :truncated} = PrimitiveCodec.decode(<<0xC0, 10, 2, 0x52>>)
    end

    test "declared element count exceeding the body errors, never a short list (cycle-5 fence)" do
      # list8: size=4 (count byte + one 2-byte element), count declares 2,
      # body holds only 1 element -> truncated, not a 1-element list.
      assert {:error, :truncated} = PrimitiveCodec.decode(<<0xC0, 0x04, 0x02, 0x52, 0x07>>)
      # same for list32
      assert {:error, :truncated} =
               PrimitiveCodec.decode(<<0xD0, 0, 0, 0, 4, 2, 0x52, 0x07>>)

      # control: matching count decodes fully
      assert {:ok, [7, 9], <<>>} =
               PrimitiveCodec.decode(<<0xC0, 0x05, 0x02, 0x52, 0x07, 0x52, 0x09>>)
    end

    test "garbage constructor errors" do
      assert {:error, :invalid_constructor} = PrimitiveCodec.decode(<<0xFF>>)
      assert {:error, :truncated} = PrimitiveCodec.decode(<<>>)
    end

    test "decode returns trailing rest" do
      assert {:ok, 5, <<0x40>>} = PrimitiveCodec.decode(<<0x52, 5, 0x40>>)
    end
  end

  describe "performative golden vector (open-frame body prefix shape)" do
    test "uint max 4294967295 encodes wide" do
      assert IO.iodata_to_binary(PrimitiveCodec.encode(4_294_967_295)) ==
               <<0x70, 0xFF, 0xFF, 0xFF, 0xFF>>
    end

    test "descriptor-less described with wide ulong descriptor" do
      bin = IO.iodata_to_binary(PrimitiveCodec.encode({:described, 70_000, nil}))
      assert bin == <<0x00, 0x80, 0, 0, 0, 0, 0, 0x01, 0x11, 0x70, 0x40>>
    end
  end

  describe "constructor table totality pin (lens-5)" do
    # The decode dispatch table (decode_typed/2) is PINNED as a total function
    # over the full 256-byte constructor space. Every byte is classified:
    # recognized (decodes {:ok,_,_} for some body) or unrecognized (returns
    # {:error, :invalid_constructor} for EVERY body).
    @recognized_ctor_bytes [
      # described
      0x00,
      # null 0x40, boolean T/F 0x41/0x42, uint0 0x43, ulong0 0x44, list0 0x45
      0x40,
      0x41,
      0x42,
      0x43,
      0x44,
      0x45,
      # ubyte 0x50, byte 0x51, smalluint 0x52, smallulong 0x53, smallint 0x54,
      # smalllong 0x55, boolean 0x56
      0x50,
      0x51,
      0x52,
      0x53,
      0x54,
      0x55,
      0x56,
      # ushort 0x60, short 0x61
      0x60,
      0x61,
      # uint 0x70, int 0x71, float 0x72
      0x70,
      0x71,
      0x72,
      # ulong 0x80, long 0x81, double 0x82, timestamp 0x83
      0x80,
      0x81,
      0x82,
      0x83,
      # uuid 0x98
      0x98,
      # vbin8/32, str8/32 (0xA2/0xB2 str-variants decode leniently)
      0xA0,
      0xA1,
      0xA2,
      0xA3,
      0xB0,
      0xB1,
      0xB2,
      0xB3,
      # list8/list32, map8/map32
      0xC0,
      0xC1,
      0xD0,
      0xD1,
      # array8/array32
      0xE0,
      0xF0
    ]

    @unrecognized_ctor_bytes Enum.to_list(0..255) -- @recognized_ctor_bytes

    # A rich body corpus: fixed widths (1/2/4/8/16 bytes), variable-length
    # prefixes, compound headers — enough for each recognized byte to have at
    # least one body it decodes cleanly.
    @bodies [
      <<>>,
      <<0x00>>,
      <<0x00, 0x00>>,
      <<0x00, 0x00, 0x00, 0x00>>,
      <<0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>,
      <<0x00::unsigned-size(128)>>,
      <<0x00, 0x00, 0x00, 0x01>>,
      <<0x00, 0x00, 0x00, 0x02, 0x41>>,
      <<0x00, 0x00, 0x00, 0x04, 0x41, 0x41, 0x41, 0x41>>,
      <<0x01, 0x01, 0x41>>,
      <<0x02, 0x01, 0x41>>,
      <<0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x01, 0x41>>,
      <<0x03, 0x02, 0x41, 0x41>>,
      <<0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x02, 0x41, 0x41>>,
      <<0x02, 0x01, 0x41>>,
      <<0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01, 0x41>>,
      <<0x53, 0x10, 0x40>>
    ]

    test "all 256 constructor bytes classified; unrecognized bytes never decode, never raise" do
      assert length(@recognized_ctor_bytes) == 38

      for ctor <- 0..255, body <- @bodies do
        bin = <<ctor, body::binary>>

        result =
          try do
            PrimitiveCodec.decode(bin)
          rescue
            e ->
              flunk(
                "ctor 0x#{Integer.to_string(ctor, 16)} raised on " <>
                  Base.encode16(bin, case: :lower) <> ": " <> Exception.format(:error, e)
              )
          end

        assert match?({:ok, _, _}, result) or match?({:error, _}, result),
               "ctor 0x#{Integer.to_string(ctor, 16)} returned non-tagged #{inspect(result)}"

        if ctor in @unrecognized_ctor_bytes do
          assert result == {:error, :invalid_constructor},
                 "unrecognized ctor 0x#{Integer.to_string(ctor, 16)} decoded #{inspect(result)} on " <>
                   Base.encode16(bin, case: :lower)
        end
      end

      # decode_all shares the same table: totality at both entry points.
      for ctor <- 0..255 do
        assert match?({:ok, _}, PrimitiveCodec.decode_all(<<ctor, 0x40>>)) or
                 match?({:error, _}, PrimitiveCodec.decode_all(<<ctor, 0x40>>))
      end
    end

    test "recognized set is behaviorally live: every recognized byte decodes some corpus body" do
      for ctor <- @recognized_ctor_bytes do
        decoded? =
          Enum.any?(@bodies, fn body ->
            match?({:ok, _, _}, PrimitiveCodec.decode(<<ctor, body::binary>>))
          end)

        assert decoded?,
               "pinned-recognized ctor 0x#{Integer.to_string(ctor, 16)} decodes NO corpus body — " <>
                 "table pin is stale"
      end
    end

    test "unrecognized set equals the spec-unused constructor space (exhaustive)" do
      # Spec §1.6 constructor space: every byte not in the recognized set is
      # unused/reserved (including 0x73 char and 0x9x reserved — see receipt).
      spec_unused =
        Enum.to_list(0x01..0x3F) ++
          Enum.to_list(0x46..0x4F) ++
          Enum.to_list(0x57..0x5F) ++
          Enum.to_list(0x62..0x6F) ++
          [0x73] ++
          Enum.to_list(0x74..0x7F) ++
          Enum.to_list(0xB4..0xBF) ++
          Enum.to_list(0x84..0x97) ++
          Enum.to_list(0x99..0x9F) ++
          Enum.to_list(0xA4..0xAF) ++
          Enum.to_list(0xC2..0xCF) ++
          Enum.to_list(0xD2..0xDF) ++
          Enum.to_list(0xE1..0xEF) ++
          Enum.to_list(0xF1..0xFF)

      assert Enum.sort(@unrecognized_ctor_bytes) == Enum.sort(spec_unused)
    end
  end
end
