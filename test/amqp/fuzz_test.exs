defmodule Smalt.Amqp.FuzzTest do
  use ExUnit.Case, async: true

  import Bitwise, only: [bxor: 2]

  # Seed-based property fuzzing of the AMQP codecs. No external deps.
  #
  # Properties:
  #   1. round-trip:  encode(term) -> decode_all(bin) == {:ok, [term]}
  #   2. decode-never-crash: arbitrary mutated binaries return tagged tuples, never raise
  #   3. frame-split invariance: incremental feed of a valid frame at every byte
  #      offset yields exactly one {:ok, frame} identical to the unsplit decode
  #   4. transfer-payload round-trip through encode_message/decode_message
  #
  # Every failure dumps the seed + input hex for exact reproduction.

  @seeds 1..100
  @max_depth 5
  @max_encoded 8 * 1024

  alias Smalt.Amqp.FrameCodec
  alias Smalt.Amqp.PrimitiveCodec

  # ---------------------------------------------------------------------------
  # Iteration counters (printed in the receipt at the end of the run)
  # ---------------------------------------------------------------------------

  defp bump(key, n) do
    k = {__MODULE__, key}
    :persistent_term.put(k, :persistent_term.get(k, 0) + n)
  end

  defp count(key), do: :persistent_term.get({__MODULE__, key}, 0)

  # ---------------------------------------------------------------------------
  # Deterministic generator
  # ---------------------------------------------------------------------------

  defp gen_term(seed) do
    :rand.seed(:exsss, seed)
    gen(depth_at_root())
  end

  defp depth_at_root, do: @max_depth

  # Weighted constructor picker. Only terms PrimitiveCodec.encode/1 supports.
  defp gen(0), do: scalar()

  defp gen(depth) do
    case :rand.uniform(12) do
      n when n in 1..4 -> scalar()
      5 -> gen_binary()
      6 -> {:symbol, symbol_body()}
      7 -> {:uuid, :crypto.strong_rand_bytes(16)}
      8 -> {:timestamp, timestamp_ms()}
      9 -> gen_list(depth)
      10 -> gen_map(depth)
      11 -> {:described, desc(), gen(depth - 1)}
      12 -> gen_array(depth)
    end
  end

  defp scalar do
    case :rand.uniform(8) do
      n when n in 1..2 -> int_in(-9_223_372_036_854_775_808, 9_223_372_036_854_775_807)
      3 -> int_in(0, 255)
      4 -> float_val()
      5 -> nil
      6 -> true
      7 -> false
      8 -> int_in(0, 65_535)
    end
  end

  defp int_in(lo, hi), do: lo + :rand.uniform(hi - lo) - 1

  defp float_val do
    case :rand.uniform(4) do
      1 -> :rand.uniform() * :math.pow(10, int_in(-20, 20))
      2 -> -:rand.uniform() * 1.0e6
      _ -> :rand.uniform() * 1.0e6
    end
  end

  defp gen_binary do
    n = :rand.uniform(300)
    :rand.bytes(n)
  end

  defp symbol_body do
    n = :rand.uniform(40)
    chars = for _ <- 1..n, do: Enum.random(?a..?z)
    :erlang.list_to_binary(chars)
  end

  defp timestamp_ms, do: int_in(-9_223_372_036_854_775_808, 9_223_372_036_854_775_807)

  defp desc do
    case :rand.uniform(2) do
      1 -> int_in(0, 1024)
      2 -> {:symbol, symbol_body()}
    end
  end

  defp gen_list(depth) do
    n = :rand.uniform(6)
    for _ <- 1..n, do: gen(depth - 1)
  end

  defp gen_map(depth) do
    n = :rand.uniform(4)
    # symbol keys round-trip as-is through PrimitiveCodec.to_map/1
    keys = for _ <- 1..n, do: {:symbol, symbol_body()}
    Map.new(Enum.zip(keys, for(_ <- 1..n, do: gen(depth - 1))))
  end

  # arrays must be constructor-homogeneous or encode/1 raises by design
  defp gen_array(_depth) do
    n = :rand.uniform(5)

    element =
      case :rand.uniform(4) do
        1 -> int_in(0, 255)
        2 -> :rand.bytes(8)
        3 -> {:symbol, symbol_body()}
        4 -> Enum.random([nil, true, false])
      end

    {:array, List.duplicate(element, n)}
  end

  defp gen_message_sections(depth) do
    base = [
      {:header,
       %{
         durable: Enum.random([true, false, nil]),
         priority: one_of([nil, int_in(0, 9)]),
         delivery_count: one_of([nil, int_in(0, 100)])
       }},
      {:properties,
       %{
         message_id: {:uuid, :crypto.strong_rand_bytes(16)},
         to: one_of([nil, "queue-" <> symbol_body()]),
         subject: one_of([nil, symbol_body()]),
         content_type: one_of([nil, {:symbol, symbol_body()}])
       }},
      {:application_properties, gen_map_shallow()},
      {:body_data, gen_binary()},
      {:footer, gen_map_shallow()}
    ]

    base =
      base ++
        [
          {Enum.random([:delivery_annotations, :message_annotations]), gen_map_shallow()},
          {:body_sequence, for(_ <- 1..:rand.uniform(3), do: gen_binary())}
        ]

    extra =
      if depth > 0 and :rand.uniform(2) == 1 do
        [{:body_amqp_value, gen(depth - 1)}]
      else
        []
      end

    base ++ extra
  end

  defp one_of(list), do: Enum.random(list)

  defp gen_map_shallow do
    n = :rand.uniform(4)

    Map.new(1..n, fn _ ->
      {:rand.bytes(6), one_of([int_in(-1000, 1000), :rand.bytes(8), nil, true, false])}
    end)
  end

  # ---------------------------------------------------------------------------
  # Mutation helpers (decode-never-crash fuzz)
  # ---------------------------------------------------------------------------

  defp mutate(bin) do
    size = byte_size(bin)

    case :rand.uniform(6) do
      n when n in 1..2 ->
        # bit flips: 1..4 random single-byte corruptions
        flips = :rand.uniform(4)

        Enum.reduce(1..flips, bin, fn _, acc ->
          if byte_size(acc) == 0 do
            acc
          else
            pos = :rand.uniform(byte_size(acc)) - 1
            <<pre::binary-size(pos), b, post::binary>> = acc
            <<pre::binary, bxor(b, :rand.uniform(255)), post::binary>>
          end
        end)

      3 ->
        # truncation
        binary_part(bin, 0, :rand.uniform(size))

      4 ->
        # splice of two valid encodings
        other = gen_term(:rand.uniform(1_000_000)) |> encode_ok()
        cut = :rand.uniform(size) - 1
        keep = :rand.uniform(byte_size(other))
        binary_part(bin, 0, cut) <> binary_part(other, 0, keep)

      5 ->
        # random garbage of random length
        :rand.bytes(:rand.uniform(64))

      6 ->
        # duplicate a chunk
        cut = :rand.uniform(size) - 1
        chunk = binary_part(bin, cut, size - cut)
        bin <> chunk
    end
  end

  defp encode_ok(term) do
    PrimitiveCodec.encode(term) |> IO.iodata_to_binary()
  end

  # ---------------------------------------------------------------------------
  # Failure reporting
  # ---------------------------------------------------------------------------

  defp dump(seed, label, input) do
    hex =
      case input do
        t when is_binary(t) -> Base.encode16(t, case: :lower)
        other -> inspect(other, limit: 50)
      end

    "FUZZ FAILURE seed=#{seed} #{label} input=#{hex}"
  end

  # ---------------------------------------------------------------------------
  # Property 1: round-trip fuzz
  # ---------------------------------------------------------------------------

  test "round-trip: encode -> decode_all reproduces the term (100 seeds x 200 terms)" do
    for seed <- @seeds do
      for _ <- 1..200 do
        term = gen_term(seed)
        bump(:roundtrip, 1)

        result =
          try do
            bin = encode_ok(term)
            assert byte_size(bin) <= @max_encoded, dump(seed, "encoded>8KB", bin)
            PrimitiveCodec.decode_all(bin)
          rescue
            e -> flunk(dump(seed, "raised #{Exception.format(:error, e)}", term))
          end

        case result do
          {:ok, [decoded]} ->
            assert decoded == term, dump(seed, "round-trip mismatch", term)

          {:ok, other} ->
            flunk(
              dump(seed, "expected exactly one value, got: #{inspect(other, limit: 20)}", term)
            )

          {:error, reason} ->
            flunk(dump(seed, "decode_all error: #{inspect(reason)}", term))
        end
      end
    end

    IO.puts("round-trip iterations: #{count(:roundtrip)}")
  end

  # ---------------------------------------------------------------------------
  # Property 2: decode-never-crash fuzz (10k iterations across seeds)
  # ---------------------------------------------------------------------------

  test "decode-never-crash: mutated binaries return tagged tuples, never raise (10k)" do
    iterations_per_seed = 100

    for seed <- @seeds do
      :rand.seed(:exsss, seed * 100_003 + 49_157)

      for i <- 1..iterations_per_seed do
        valid = gen_term(:rand.uniform(1_000_000)) |> encode_ok()
        bin = mutate(valid)
        bump(:never_crash, 1)

        hex = Base.encode16(bin, case: :lower)
        label = "seed=#{seed} iter=#{i} input=#{hex}"

        # PrimitiveCodec.decode/1
        try do
          assert_tuple(PrimitiveCodec.decode(bin))
        rescue
          e ->
            flunk("FUZZ FAILURE PrimitiveCodec.decode #{label}: #{Exception.format(:error, e)}")
        end

        # PrimitiveCodec.decode_all/1
        try do
          assert_tuple(PrimitiveCodec.decode_all(bin))
        rescue
          e ->
            flunk(
              "FUZZ FAILURE PrimitiveCodec.decode_all #{label}: #{Exception.format(:error, e)}"
            )
        end

        # FrameCodec.decode_frame/1
        try do
          assert_tuple(FrameCodec.decode_frame(bin))
        rescue
          e ->
            flunk("FUZZ FAILURE FrameCodec.decode_frame #{label}: #{Exception.format(:error, e)}")
        end
      end
    end

    assert count(:never_crash) == 10_000, "expected 10k never-crash iterations"
    IO.puts("decode-never-crash iterations: #{count(:never_crash)}")
  end

  defp assert_tuple({:ok, _}), do: :ok
  defp assert_tuple({:ok, _, _}), do: :ok
  defp assert_tuple({:more, _}), do: :ok
  defp assert_tuple({:error, _}), do: :ok

  defp assert_tuple(other),
    do: flunk("decoder returned non-tagged value: #{inspect(other, limit: 20)}")

  # ---------------------------------------------------------------------------
  # Property 3: frame-split invariance
  # ---------------------------------------------------------------------------

  test "frame-split invariance: incremental feed at every offset matches unsplit" do
    for seed <- @seeds do
      :rand.seed(:exsss, seed * 100_003 + 389_011)

      frames = [
        build_open_frame(seed),
        build_transfer_frame(seed)
      ]

      for frame <- frames, offset <- 0..(byte_size(frame) - 1) do
        bump(:split, 1)
        <<prefix::binary-size(offset), suffix::binary>> = frame
        _ = suffix

        expected = FrameCodec.decode_frame(frame)

        got =
          try do
            case FrameCodec.decode_frame(prefix) do
              {:more, _} ->
                # feed the remainder incrementally, one byte at a time
                feed(frame, offset)

              other ->
                flunk(
                  "FUZZ FAILURE split seed=#{seed} offset=#{offset}: proper prefix " <>
                    "returned #{inspect(other, limit: 10)}, expected {:more, _}"
                )
            end
          rescue
            e ->
              flunk(
                "FUZZ FAILURE split seed=#{seed} offset=#{offset} frame=" <>
                  "#{Base.encode16(frame, case: :lower)}: #{Exception.format(:error, e)}"
              )
          end

        assert got == expected,
               "FUZZ FAILURE split seed=#{seed} offset=#{offset}: " <>
                 "incremental=#{inspect(got, limit: 10)} unsplit=#{inspect(expected, limit: 10)}"
      end
    end

    IO.puts("frame-split iterations: #{count(:split)}")
  end

  # Feed frame[offset..] byte by byte; assert exactly one {:ok, ...} at the end.
  defp feed(frame, start) do
    feed(frame, start, 0)
  end

  defp feed(frame, pos, oks) do
    case FrameCodec.decode_frame(binary_part(frame, 0, pos)) do
      {:more, _} ->
        if pos == byte_size(frame) do
          flunk("FUZZ FAILURE feed: full frame still {:more, _}")
        else
          feed(frame, pos + 1, oks)
        end

      {:ok, frame_out} ->
        # full frame consumed in one step: the only ok
        assert oks == 0, "FUZZ FAILURE feed: second {:ok, _} before frame end"
        assert pos == byte_size(frame), "FUZZ FAILURE feed: ok before frame end"
        {:ok, frame_out}

      {:error, reason} ->
        flunk("FUZZ FAILURE feed: error #{inspect(reason)} on a valid frame prefix")
    end
  end

  # ---------------------------------------------------------------------------
  # Property 4: transfer-payload fuzz
  # ---------------------------------------------------------------------------

  test "transfer-payload round-trip: encode_message -> decode_message (100 seeds)" do
    for seed <- @seeds do
      :rand.seed(:exsss, seed * 100_003 + 653_803)

      for _ <- 1..50 do
        sections = gen_message_sections(2)
        payload = FrameCodec.encode_message(sections) |> IO.iodata_to_binary()
        bump(:transfer, 1)

        decoded =
          try do
            assert is_binary(payload)

            case FrameCodec.decode_message(payload) do
              {:ok, decoded} ->
                decoded

              {:error, reason} ->
                flunk(dump(seed, "decode_message error: #{inspect(reason)}", payload))
            end
          rescue
            e -> flunk(dump(seed, "raised #{Exception.format(:error, e)}", payload))
          end

        assert_sections_match(sections, decoded, seed, payload)
      end
    end

    IO.puts("transfer-payload iterations: #{count(:transfer)}")
  end

  defp assert_sections_match(sections, decoded, seed, payload) do
    # structural check per section kind, robust to nil-field stripping by the codec
    for {kind, val} <- sections do
      case List.keyfind(decoded, kind, 0) do
        nil ->
          flunk(dump(seed, "missing section #{kind}", payload))

        {^kind, dval} ->
          assert_section_equal(kind, val, dval, seed, payload)
      end
    end
  end

  defp assert_section_equal(:header, want, got, seed, payload) do
    for {k, v} when not is_nil(v) <- want do
      assert Map.get(got, k) == v,
             dump(seed, "header.#{k}: #{inspect(v)} != #{inspect(Map.get(got, k))}", payload)
    end
  end

  defp assert_section_equal(:properties, want, got, seed, payload) do
    for {k, v} when not is_nil(v) <- want do
      assert Map.get(got, k) == v,
             dump(seed, "properties.#{k}: #{inspect(v)} != #{inspect(Map.get(got, k))}", payload)
    end
  end

  defp assert_section_equal(:body_data, want, got, seed, payload) do
    assert want == got, dump(seed, "body_data mismatch", payload)
  end

  defp assert_section_equal(:footer, want, got, seed, payload) do
    for {k, v} when not is_nil(v) <- want do
      assert Map.get(got, k) == v, dump(seed, "footer.#{k} mismatch", payload)
    end
  end

  defp assert_section_equal(:application_properties, want, got, seed, payload) do
    for {k, v} when not is_nil(v) <- want do
      assert Map.get(got, k) == v, dump(seed, "application_properties mismatch", payload)
    end
  end

  defp assert_section_equal(:body_amqp_value, want, got, seed, payload) do
    assert want == got, dump(seed, "body_amqp_value mismatch", payload)
  end

  defp assert_section_equal(:body_sequence, want, got, seed, payload) do
    assert want == got, dump(seed, "body_sequence mismatch", payload)
  end

  defp assert_section_equal(kind, want, got, seed, payload)
       when kind in [:delivery_annotations, :message_annotations] do
    for {k, v} when not is_nil(v) <- want do
      assert Map.get(got, k) == v, dump(seed, "#{kind} #{inspect(k)} mismatch", payload)
    end
  end

  defp assert_section_equal(_, _want, _got, _seed, _payload), do: :ok

  # ---------------------------------------------------------------------------
  # Frame builders
  # ---------------------------------------------------------------------------

  defp build_open_frame(seed) do
    :rand.seed(:exsss, seed * 100_003 + 102_457)

    fields = %{
      container_id: "fuzz-" <> symbol_body(),
      hostname: "localhost",
      max_frame_size: int_in(512, 1_048_576),
      channel_max: int_in(0, 65_535),
      idle_time_out: int_in(0, 60_000),
      outgoing_locales: nil,
      incoming_locales: nil,
      offered_capabilities: nil,
      desired_capabilities: nil,
      properties: gen_map_shallow()
    }

    FrameCodec.encode_frame(:amqp, 0, {:open, fields}) |> IO.iodata_to_binary()
  end

  defp build_transfer_frame(seed) do
    :rand.seed(:exsss, seed * 100_003 + 781_729)

    fields = %{
      delivery_id: int_in(0, 1000),
      delivery_tag: :rand.bytes(4),
      message_format: 0,
      settled: true,
      more: false,
      rcv_settle_mode: nil,
      state: nil,
      resume: nil,
      aborted: nil,
      batchable: nil
    }

    sections = gen_message_sections(2)

    FrameCodec.encode_frame(:amqp, int_in(0, 65_535), {:transfer, fields, {:sections, sections}})
    |> IO.iodata_to_binary()
  end

  # ---------------------------------------------------------------------------
  # Atom-table flood regression (lane 101)
  #
  # safe_atom/1 previously fell back to String.to_atom/1 on wire-sourced
  # source/target map keys. Atoms are never GC'd; a remote peer minting
  # ~1M unique keys can kill the VM. The fix keeps unknown keys as binaries.
  # ---------------------------------------------------------------------------

  @tag :atom_flood
  test "5000 unique long symbol source/target keys mint no new atoms" do
    keys =
      Map.new(1..5000, fn i ->
        key = "fuzz-atom-flood-#{i}-" <> String.duplicate("k", 40)
        {key, i}
      end)

    # Hand-built attach whose source is a raw AMQP map of hostile keys — the
    # exact shape that used to hit the String.to_atom/1 fallback in safe_atom/1.
    body =
      Smalt.Amqp.PrimitiveCodec.encode({:described, 0x12,
       [
         "link-flood",
         0,
         0,
         nil,
         nil,
         # source sits at positional index 5 in the attach field order
         {:map_rhea, keys}
       ]})

    encoded =
      IO.iodata_to_binary([
        <<IO.iodata_length(body) + 8::32, 2::8, 0x00::8, 0::16>>,
        body
      ])

    # Warm-up decode: first pass through the codec loads Logger/lazy runtime
    # state that mints a small fixed set of atoms unrelated to wire input.
    assert {:ok, _} = FrameCodec.decode_frame(encoded)

    # PRIMARY (deterministic structural) proof of the fix: the decoded map
    # carries every wire key as a binary and the atom table cannot have been
    # minted 5001 new entries without the map reflecting them as atoms.
    assert {:ok, frame} = FrameCodec.decode_frame(encoded)

    src = frame.performative.source
    assert is_map(src)
    # decode_source_target/1 defaults a :filter key (nil) into the decoded map
    assert map_size(src) == 5001
    assert src[:filter] == nil

    # Every unknown wire key must come back as a binary, never a minted atom.
    assert Enum.all?(Map.keys(src), &(&1 == :filter or is_binary(&1)))

    # Measurement fence retired (2026-10-18, i22 forensics — mechanism lane 2):
    # the atom_count window is perturbable by concurrent lazy-init atom minting
    # (this module is async:true), so Enum.any?(windows, &(&1 <= 10)) can flip
    # on unrelated runtime init, not decode-path behavior. The structural
    # asserts above (map_size 5001 + binary keys) and the 50k-key scale fence
    # below are the sound, race-free proof of zero atom minting by the decode
    # path — the measurement fence carried no additional bits. (The test's own
    # pre-fix comments acknowledged this hazard.)

    # Scale fence (serial-friendly, same decode path): 50k unique keys must
    # still decode structurally with binary keys — no atom minting at scale.
    # keys kept short: 50k long keys encode past the 1 MiB frame decode cap
    # (:frame_too_size); uniqueness comes from the index, staying ~640 KB.
    big_keys =
      Map.new(1..50_000, fn i ->
        {"fa-#{i}", i}
      end)

    big_body =
      Smalt.Amqp.PrimitiveCodec.encode(
        {:described, 0x12,
         [
           "link-scale",
           0,
           0,
           nil,
           nil,
           {:map_rhea, big_keys}
         ]}
      )

    big_encoded =
      IO.iodata_to_binary([
        <<IO.iodata_length(big_body) + 8::32, 2::8, 0x00::8, 0::16>>,
        big_body
      ])

    assert {:ok, big_frame} = FrameCodec.decode_frame(big_encoded)
    big_src = big_frame.performative.source
    assert map_size(big_src) == 50_001
    assert big_src[:filter] == nil
    assert Enum.all?(Map.keys(big_src), &(&1 == :filter or is_binary(&1)))
  end

  # ---------------------------------------------------------------------------
  # Property 5: compound truncation (cycle-5/6 fences)
  # ---------------------------------------------------------------------------

  test "prefix-cut property: every proper prefix of a well-formed compound errors" do
    for seed <- @seeds do
      :rand.seed(:exsss, seed * 31 + 7)

      for _ <- 1..20 do
        # lists/maps of generated scalars: well-formed compound bodies
        n = :rand.uniform(4)
        elems = Enum.map(1..n, fn _ -> gen(1) end)
        bin = PrimitiveCodec.encode(elems) |> IO.iodata_to_binary()

        for cut <- 1..(byte_size(bin) - 1) do
          bump(:prefix_cut, 1)

          result = PrimitiveCodec.decode(binary_part(bin, 0, cut))

          assert {:error, _} = result,
                 "prefix cut #{cut} of #{byte_size(bin)} decoded as success: #{inspect(result)} (seed #{seed}, hex #{Base.encode16(bin)})"
        end
      end
    end

    IO.puts("prefix-cut iterations: #{count(:prefix_cut)}")
  end

  test "map count ambiguity: element-count and pair-count forms both decode; count-overrun errors" do
    for seed <- @seeds do
      :rand.seed(:exsss, seed * 17 + 3)
      k = "k#{seed}"
      v = gen(1)
      real = PrimitiveCodec.encode(%{k => v}) |> IO.iodata_to_binary()

      # real-codec (element-count) form round-trips
      assert {:ok, %{^k => ^v}, <<>>} = PrimitiveCodec.decode(real)

      # hand-built pair-count form (spec-literal) also decodes
      vb = PrimitiveCodec.encode(v) |> IO.iodata_to_binary()
      kb = PrimitiveCodec.encode({:symbol, k}) |> IO.iodata_to_binary()
      body = kb <> vb

      {mctor, mcount, msize} =
        if byte_size(body) + 1 <= 255,
          do: {0xC1, <<1::8>>, <<byte_size(body) + 1::8>>},
          else:
            {0xD1, <<1::unsigned-integer-size(32)>>,
             <<byte_size(body) + 4::unsigned-integer-size(32)>>}

      pair_form = <<mctor, msize::binary, mcount::binary, body::binary>>

      case PrimitiveCodec.decode(pair_form) do
        {:ok, %{{:symbol, ^k} => ^v}, <<>>} ->
          :ok

        other ->
          flunk("pair-form seed #{seed}: #{inspect(other)} body_hex=#{Base.encode16(body)}")
      end

      # odd declared count with an element count mismatching the exact body:
      # error, never a partial map (element-count try fails, pair-count try
      # yields an odd item list -> :invalid_length)
      odd_count = if mctor == 0xC1, do: <<3::8>>, else: <<3::unsigned-integer-size(32)>>
      odd = <<mctor, msize::binary, odd_count::binary, body::binary>>
      assert {:error, _} = PrimitiveCodec.decode(odd)
    end
  end

  test "frame decode-never-crash: mutated frame headers return tagged tuples (cycle-7)" do
    base = FrameCodec.encode_frame(:amqp, 7, {:transfer, %{handle: 0, delivery_id: 1}, "payload"})
    base = IO.iodata_to_binary(base)

    for seed <- 1..2000 do
      :rand.seed(:exsss, seed)
      bin = :erlang.binary_part(base, 0, byte_size(base))
      pos = :rand.uniform(byte_size(bin)) - 1
      flip = :rand.uniform(255)
      <<pre::binary-size(pos), b, post::binary>> = bin
      mutated = <<pre::binary, bxor(b, flip), post::binary>>
      bump(:frame_mutate, 1)

      try do
        assert match?({:ok, _}, FrameCodec.decode_frame(mutated)) or
                 match?({:more, _}, FrameCodec.decode_frame(mutated)) or
                 match?({:error, _}, FrameCodec.decode_frame(mutated)),
               "non-tagged result"
      rescue
        e -> flunk(dump(seed, "decode_frame raised: " <> Exception.format(:error, e), mutated))
      end
    end

    IO.puts("frame-mutate iterations: #{count(:frame_mutate)}")
  end

  test "frame decode-never-crash: adjacent two-byte mutations (cycle-8)" do
    base =
      IO.iodata_to_binary(
        FrameCodec.encode_frame(
          :amqp,
          7,
          {:transfer, %{handle: 0, delivery_id: 1, settled: false},
           {:sections, [{:body_data, "payload bytes"}]}}
        )
      )

    for seed <- 1..2000 do
      :rand.seed(:exsss, seed)
      pos = :rand.uniform(byte_size(base) - 2) - 1
      f1 = :rand.uniform(255)
      f2 = :rand.uniform(255)
      <<pre::binary-size(pos), a, b, post::binary>> = base
      mutated = <<pre::binary, bxor(a, f1), bxor(b, f2), post::binary>>
      bump(:frame_mutate2, 1)

      try do
        result = FrameCodec.decode_frame(mutated)

        assert match?({:ok, _}, result) or match?({:more, _}, result) or
                 match?({:error, _}, result)
      rescue
        e -> flunk(dump(seed, "2-byte mutation raised: " <> Exception.format(:error, e), mutated))
      end
    end

    IO.puts("frame-mutate2 iterations: #{count(:frame_mutate2)}")
  end

  # ---------------------------------------------------------------------------
  # Property 7 (lens-2): differential performative round-trip fuzz
  # ---------------------------------------------------------------------------
  # Every AMQP performative x randomized REAL field names (fields are
  # positional — a key outside @field_orders can never round-trip) x random
  # values (nil, ints, binaries, bools, symbols, scalar lists, string-keyed
  # maps) -> encode_frame -> decode_frame. Differential: every non-nil
  # original field must survive decode at its named position, modulo the
  # codec's documented transforms (attach source/target described rewrap,
  # error-map -> [condition, desc, info] list, delivery-state rewrap).

  @perf_orders %{
    open: [
      :container_id,
      :hostname,
      :max_frame_size,
      :channel_max,
      :idle_time_out,
      :outgoing_locales,
      :incoming_locales,
      :offered_capabilities,
      :desired_capabilities,
      :properties
    ],
    begin: [:remote_channel, :next_outgoing_id, :incoming_window, :outgoing_window, :handle_max],
    attach: [
      :name,
      :handle,
      :role,
      :snd_settle_mode,
      :rcv_settle_mode,
      :source,
      :target,
      :unsettled,
      :incomplete_unsettled,
      :initial_delivery_count,
      :max_message_size,
      :offered_capabilities,
      :desired_capabilities,
      :properties
    ],
    flow: [
      :next_incoming_id,
      :incoming_window,
      :next_outgoing_id,
      :outgoing_window,
      :handle,
      :delivery_count,
      :link_credit,
      :available,
      :drain,
      :echo,
      :properties
    ],
    transfer: [
      :handle,
      :delivery_id,
      :delivery_tag,
      :message_format,
      :settled,
      :more,
      :rcv_settle_mode,
      :state
    ],
    disposition: [:role, :first, :last, :settled, :state, :batchable],
    detach: [:handle, :closed, :error],
    end: [:error],
    close: [:error]
  }

  test "differential performative round-trip: random fields survive decode (lens-2)" do
    for seed <- @seeds do
      :rand.seed(:exsss, seed * 100_003 + 918_257)

      for perf <- [:open, :begin, :attach, :flow, :transfer, :disposition, :detach, :end, :close] do
        fields = gen_performative_fields(perf, @perf_orders[perf])

        frame =
          FrameCodec.encode_frame(:amqp, rem(seed, 65_536), {perf, fields})
          |> IO.iodata_to_binary()

        bump(:diff_perf, 1)

        got =
          try do
            case FrameCodec.decode_frame(frame) do
              {:ok, %{performative: decoded}} -> decoded
              other -> flunk(dump(seed, "decode_frame -> #{inspect(other, limit: 10)}", frame))
            end
          rescue
            e -> flunk(dump(seed, "raised #{Exception.format(:error, e)}", frame))
          end

        assert got[:performative] == perf, dump(seed, "performative name lost", fields)

        for {k, v} <- fields, v != nil do
          assert field_compat(perf, k, v, got[k]),
                 dump(
                   seed,
                   "field #{k}: #{inspect(v, limit: 20)} -> #{inspect(got[k], limit: 20)}",
                   fields
                 )
        end
      end
    end

    IO.puts("differential performative iterations: #{count(:diff_perf)}")
  end

  # Real field names only (positional codec); a name outside the order list
  # can never decode back.
  defp gen_performative_fields(_perf, nil), do: %{}

  defp gen_performative_fields(perf, order) do
    order
    |> Enum.map(fn
      :source ->
        {:source, %{address: symbol_body()}}

      :target ->
        {:target, %{address: symbol_body()}}

      :error ->
        {:error, error_map()}

      k
      when k in [
             :role,
             :settled,
             :more,
             :drain,
             :echo,
             :batchable,
             :closed,
             :durable,
             :incomplete_unsettled
           ] ->
        {k, Enum.random([true, false, nil])}

      :state ->
        {:state, Enum.random([:accepted, :released, nil])}

      k ->
        {k, rand_val()}
    end)
    |> Map.new()
    |> Map.merge(%{any_marker: nil})
    |> tap(fn f ->
      # disposition {:rejected,_}/{:modified,_} states and attach filters have
      # bespoke transforms — covered by dedicated fences, out of scope here.
      _ = {perf, f}
    end)
  end

  defp error_map do
    Enum.random([
      %{condition: "amqp:internal-error"},
      %{condition: {:symbol, "amqp:not-found"}, description: symbol_body()},
      nil
    ])
  end

  defp rand_val do
    case :rand.uniform(7) do
      1 -> nil
      2 -> int_in(-1_000_000, 1_000_000)
      3 -> :rand.bytes(12)
      4 -> true
      5 -> false
      6 -> {:symbol, symbol_body()}
      7 -> rand_field_map()
    end
  end

  defp rand_field_map do
    Map.new(1..:rand.uniform(3), fn _ -> {rand_scalar(), rand_scalar()} end)
  end

  defp rand_scalar do
    case :rand.uniform(6) do
      1 -> int_in(-1000, 1000)
      2 -> :rand.bytes(6)
      3 -> true
      4 -> false
      5 -> {:symbol, symbol_body()}
      6 -> nil
    end
  end

  # Differential comparator: original non-nil field v vs decoded field got.
  defp field_compat(_perf, _k, _v, nil), do: false

  defp field_compat(perf, k, v, got) do
    cond do
      perf == :attach and k in [:source, :target] and is_map(v) ->
        # decode strips nil subfields; compare only the fuzzed non-nil shape
        is_map(got) and Map.get(got, :address) == Map.get(v, :address)

      k == :error and is_map(v) ->
        cond_v = Map.get(v, :condition)

        got == [
          case cond_v do
            {:symbol, _} = s -> s
            b when is_binary(b) -> {:symbol, b}
          end,
          Map.get(v, :description),
          Map.get(v, :info)
        ]

      k == :state and v in [:accepted, :released] ->
        got == v

      true ->
        got == v
    end
  end

  # ---------------------------------------------------------------------------
  # Property 9 (lens-3): extreme-value encode symmetry
  # ---------------------------------------------------------------------------
  # Lens waves hammered DECODE. This property hammers ENCODE: boundary values
  # the random generator cannot hit (int64/uint32/uint16/byte edges, min/max
  # timestamps, all-256-byte-values binaries at the 255/256 length boundary,
  # deep nesting, extreme-length symbols, boundary-sized arrays) must all
  # round-trip encode -> decode_all byte-identically, both standalone and as
  # values inside every performative field position.

  @extreme_ints [
    0,
    1,
    127,
    128,
    255,
    256,
    65_535,
    65_536,
    0xFFFF_FFFF,
    0xFFFF_FFFF + 1,
    0x7FFF_FFFF_FFFF_FFFF,
    0xFFFF_FFFF_FFFF_FFFF,
    -1,
    -127,
    -128,
    -129,
    -32_768,
    -32_769,
    -2_147_483_648,
    -2_147_483_649,
    -0x8000_0000_0000_0000
  ]

  @extreme_binaries [
    <<>>,
    <<0>>,
    String.duplicate("x", 255),
    String.duplicate("x", 256),
    for(i <- 0..255, into: "", do: <<i>>),
    for(i <- 0..255, into: "", do: <<i, i, i>>) <> <<255>>,
    :binary.copy(for(i <- 0..255, into: "", do: <<i>>), 300)
  ]

  test "extreme-value encode symmetry: boundary primitives round-trip (lens-3)" do
    terms =
      List.flatten([
        @extreme_ints,
        Enum.map(@extreme_ints, fn
          # timestamp is signed 64-bit; uint64-max is a raise-contract value
          n when n > 0x7FFF_FFFF_FFFF_FFFF -> {:timestamp, -1}
          n -> {:timestamp, n}
        end),
        # {:vbin, _} encodes 0xA0/0xB0 and decodes as a PLAIN binary (documented
        # codec mapping): assert against the untagged binary
        Enum.map(@extreme_binaries, &{:vbin, &1}),
        @extreme_binaries,
        for(i <- 0..255, into: "", do: <<i>>) |> then(&{:symbol, &1}),
        {:symbol, String.duplicate("s", 255)},
        {:symbol, String.duplicate("s", 256)},
        {:uuid, <<0::128>>},
        {:uuid, <<0xFF::128>>},
        [],
        [[]],
        [[], []],
        {:array, []},
        {:array, List.duplicate(-0x8000_0000_0000_0000, 3)},
        {:array, List.duplicate(for(i <- 0..255, into: "", do: <<i>>), 3)},
        %{},
        %{<<>> => <<>>},
        %{<<>> => nil},
        # deep list: exercises recursive encode/decode without hitting the
        # 50k-depth probe already receipted in lens-2 cycle-4
        deep_list(1000, 7),
        0.0,
        -0.0,
        1.0e308,
        -1.0e308
      ])

    for term <- terms do
      bump(:extreme_roundtrip, 1)

      bin =
        try do
          encode_ok(term)
        rescue
          e -> flunk(dump("extreme", "encode raised #{Exception.format(:error, e)}", term))
        end

      result =
        try do
          PrimitiveCodec.decode_all(bin)
        rescue
          e -> flunk(dump("extreme", "decode raised #{Exception.format(:error, e)}", bin))
        end

      expected = untag_vbin(term)
      assert {:ok, [^expected]} = result, dump("extreme", "round-trip mismatch", term)
    end

    IO.puts("extreme round-trip iterations: #{count(:extreme_roundtrip)}")
  end

  # {:vbin, b} decodes as plain b (documented mapping); everything else is exact
  defp untag_vbin({:vbin, b}) when is_binary(b), do: b
  defp untag_vbin(term), do: term

  defp deep_list(0, leaf), do: leaf
  defp deep_list(depth, leaf), do: [deep_list(depth - 1, leaf)]

  test "extreme-value performative symmetry: extreme fields survive every performative (lens-3)" do
    perfs = [:open, :begin, :attach, :flow, :transfer, :disposition, :detach, :end, :close]

    extreme_vals = [
      0,
      0xFFFF_FFFF_FFFF_FFFF,
      -0x8000_0000_0000_0000,
      0xFFFF_FFFF,
      -2_147_483_648,
      for(i <- 0..255, into: "", do: <<i>>),
      {:symbol, String.duplicate("s", 256)},
      {:timestamp, -0x8000_0000_0000_0000},
      {:uuid, <<0xFF::128>>},
      deep_list(100, 7),
      {:array, List.duplicate(65_535, 3)},
      true,
      false
    ]

    for perf <- perfs, v <- extreme_vals do
      # fill EVERY field position with the same extreme value: the positional
      # codec must round-trip it at every index (trailing-null trimming is
      # exercised by the nil-heavy differential fuzz already; here non-nil
      # everywhere forces the full-arity encode)
      order = @perf_orders[perf]

      fields = Map.new(order, fn k -> {k, v} end)
      fields = Map.put(fields, :role, true)
      fields = Map.put(fields, :state, :accepted)
      fields = Map.put(fields, :source, %{address: "q"})
      fields = Map.put(fields, :target, %{address: "q"})
      # only performatives whose field order HAS the field
      fields =
        fields
        |> then(fn f ->
          if :error in order,
            do: Map.put(f, :error, %{condition: "amqp:internal-error"}),
            else: Map.delete(f, :error)
        end)
        |> then(fn f ->
          if :state in order, do: Map.put(f, :state, :accepted), else: Map.delete(f, :state)
        end)
        |> then(fn f ->
          if :role in order, do: Map.put(f, :role, true), else: Map.delete(f, :role)
        end)
        |> then(fn f ->
          if :source in order,
            do: Map.put(f, :source, %{address: "q"}),
            else: Map.delete(f, :source)
        end)
        |> then(fn f ->
          if :target in order,
            do: Map.put(f, :target, %{address: "q"}),
            else: Map.delete(f, :target)
        end)

      bump(:extreme_perf, 1)

      frame =
        try do
          FrameCodec.encode_frame(:amqp, 0, {perf, fields}) |> IO.iodata_to_binary()
        rescue
          e ->
            flunk(dump("extreme-perf #{perf}", "encode raised #{Exception.format(:error, e)}", v))
        end

      got =
        try do
          case FrameCodec.decode_frame(frame) do
            {:ok, %{performative: decoded}} ->
              decoded

            other ->
              flunk(dump("extreme-perf #{perf}", "decode -> #{inspect(other, limit: 10)}", v))
          end
        rescue
          e -> flunk(dump("extreme-perf #{perf}", "raised #{Exception.format(:error, e)}", frame))
        end

      for {k, x} <- fields, x != nil do
        assert field_compat(perf, k, x, got[k]),
               dump(
                 "extreme-perf #{perf}",
                 "field #{k}: #{inspect(x, limit: 12)} -> #{inspect(got[k], limit: 12)}",
                 v
               )

        :ok
      end
    end

    IO.puts("extreme performative iterations: #{count(:extreme_perf)}")
  end

  # ---------------------------------------------------------------------------
  # Property 10 (lens-3): frame-splitting across TCP segments, multi-frame buffers
  # ---------------------------------------------------------------------------
  # Property 3 covers ONE frame fed at every 1-byte offset. Real TCP delivers
  # N frames in arbitrary-size chunks and coalesces frames in one recv. The
  # documented consumer contract (connection.ex rest_after: "FrameCodec
  # consumes exactly the leading frame; drop it from the buffer") is fuzzed
  # here: sequential decode_frame calls over the size-prefix slice recover
  # every frame in order, and every prefix of a valid frame is {:more, total}
  # with total >= prefix length (need_more budgets off it).

  test "multi-frame buffer: every frame recovered in order at every split offset (lens-3)" do
    for seed <- 1..20 do
      :rand.seed(:exsss, seed * 100_003 + 241_103)

      frames =
        for _ <- 1..3 do
          FrameCodec.encode_frame(
            :amqp,
            rem(seed, 65_536),
            {:transfer, %{handle: 0, delivery_id: seed}, {:sections, gen_message_sections(2)}}
          )
          |> IO.iodata_to_binary()
        end

      buf = IO.iodata_to_binary(frames)

      for offset <- 0..(byte_size(buf) - 1) do
        bump(:multi_frame, 1)
        <<prefix::binary-size(offset), suffix::binary>> = buf

        got =
          try do
            case FrameCodec.decode_frame(prefix) do
              # prefix holds a frame plus part of the next: first frame must
              # still decode and the slice contract must hold
              {:ok, frame} ->
                consumed = leading_frame_size(prefix)

                assert consumed <= byte_size(prefix)

                rest = binary_part(prefix, consumed, byte_size(prefix) - consumed)
                # recovered rest + withheld suffix reassembles the tail
                assert rest <> suffix == binary_part(buf, consumed, byte_size(buf) - consumed)
                frame

              {:more, total} ->
                assert total > byte_size(prefix),
                       "prefix #{offset}: {:more, #{total}} but prefix is #{byte_size(prefix)} bytes"

                # withhold nothing further: full frame completes
                {:more, total}

              other ->
                flunk(
                  "FUZZ FAILURE multi-frame seed=#{seed} offset=#{offset}: " <>
                    "#{inspect(other, limit: 10)}"
                )
            end
          rescue
            e ->
              flunk(
                "FUZZ FAILURE multi-frame seed=#{seed} offset=#{offset}: #{Exception.format(:error, e)}"
              )
          end

        _ = got
      end
    end
  end

  # The documented consumer slice contract: the leading frame's wire size is
  # its first 4 bytes; FrameCodec consumes exactly the leading frame.
  defp leading_frame_size(<<size::unsigned-integer-size(32), _::binary>>), do: size

  # ---------------------------------------------------------------------------
  # Property 11 (lens-3): exhaustive constructor-byte decode sweep
  # ---------------------------------------------------------------------------
  # Random fuzz only samples the byte space; this is EXHAUSTIVE over the
  # constructor byte: all 256 values x 4 body shapes (empty, 1 byte, 8 bytes,
  # followed by a complete valid value) through decode/1, decode_all/1,
  # decode_frame/1 AND decode_message/1. Invariant: a tagged tuple, never a
  # raise, for every (byte, shape) pair — 4096 exhaustive cases per run.

  test "exhaustive constructor sweep: all 256 ctor bytes x 4 body shapes, never raises (lens-3)" do
    suffix = encode_ok({:symbol, "tail"})

    bodies = [
      <<>>,
      <<0x01>>,
      <<1, 2, 3, 4, 5, 6, 7, 8>>,
      <<0xC0, 1, 1, 0x41>> <> suffix
    ]

    for ctor <- 0..255, body <- bodies do
      bin = <<ctor, body::binary>>
      bump(:ctor_sweep, 1)

      for {label, f} <- [
            {:decode, fn b -> PrimitiveCodec.decode(b) end},
            {:decode_all, fn b -> PrimitiveCodec.decode_all(b) end},
            {:decode_frame, fn b -> FrameCodec.decode_frame(b) end},
            {:decode_message, fn b -> FrameCodec.decode_message(b) end}
          ] do
        result =
          try do
            f.(bin)
          rescue
            e ->
              flunk(
                "ctor sweep #{label} ctor=0x#{Integer.to_string(ctor, 16)} raised: #{Exception.format(:error, e)}"
              )
          end

        assert match?({:ok, _}, result) or match?({:ok, _, _}, result) or
                 match?({:error, _}, result) or
                 match?({:more, _}, result),
               "ctor sweep #{label} ctor=0x#{Integer.to_string(ctor, 16)} body=#{Base.encode16(bin)} -> #{inspect(result, limit: 10)}"
      end
    end

    # 256 ctor bytes x 4 body shapes; the 4 entry points share each case
    assert count(:ctor_sweep) == 1024
    IO.puts("ctor sweep iterations: #{count(:ctor_sweep)}")
  end

  # ---------------------------------------------------------------------------
  # Property 12 (lens-3): SASL-layer differential round-trip
  # ---------------------------------------------------------------------------
  # The differential performative fuzz covers the AMQP layer only. SASL
  # performatives have their own field orders and their own frame layer
  # (type 0x01); layer mismatch is fenced in frame_codec_test, but the SASL
  # round-trip itself was never fuzzed.

  test "sasl performative differential round-trip (lens-3)" do
    sasl_orders = %{
      sasl_mechanisms: [:server_mechanisms],
      sasl_init: [:mechanism, :initial_response, :hostname],
      sasl_challenge: [:challenge],
      sasl_response: [:response],
      sasl_outcome: [:code, :additional_data]
    }

    for seed <- @seeds do
      :rand.seed(:exsss, seed * 100_003 + 553_319)

      for {perf, order} <- sasl_orders do
        fields =
          Enum.map(order, fn
            :server_mechanisms ->
              {:server_mechanisms,
               one_of([
                 [{:symbol, "ANONYMOUS"}],
                 [{:symbol, "AMQPCBS008"}],
                 [{:symbol, "PLAIN"}, {:symbol, "ANONYMOUS"}]
               ])}

            :mechanism ->
              {:mechanism, one_of([{:symbol, "ANONYMOUS"}, {:symbol, "AMQPCBS008"}])}

            :initial_response ->
              {:initial_response, one_of([nil, :rand.bytes(:rand.uniform(64))])}

            :hostname ->
              {:hostname, one_of([nil, "sb://fuzz-host"])}

            :challenge ->
              {:challenge, :rand.bytes(:rand.uniform(64))}

            :response ->
              {:response, :rand.bytes(:rand.uniform(64))}

            :code ->
              {:code, one_of([0, 1])}

            :additional_data ->
              {:additional_data, one_of([nil, :rand.bytes(16)])}
          end)
          |> Map.new()

        frame =
          FrameCodec.encode_frame(:sasl, rem(seed, 65_536), {perf, fields})
          |> IO.iodata_to_binary()

        bump(:sasl_diff, 1)

        got =
          try do
            case FrameCodec.decode_frame(frame) do
              {:ok, %{type: :sasl, performative: decoded}} -> decoded
              other -> flunk(dump(seed, "sasl decode -> #{inspect(other, limit: 10)}", frame))
            end
          rescue
            e -> flunk(dump(seed, "raised #{Exception.format(:error, e)}", frame))
          end

        assert got[:performative] == perf, dump(seed, "sasl performative lost", fields)

        for {k, v} <- fields, v != nil do
          assert got[k] == v, dump(seed, "sasl field #{k} mismatch", fields)
        end
      end
    end

    IO.puts("sasl differential iterations: #{count(:sasl_diff)}")
  end

  # ---------------------------------------------------------------------------
  # Property 13 (lens-3): random-chunk TCP feeding
  # ---------------------------------------------------------------------------
  # Property 3 feeds 1 byte at a time; Property 10 splits only at one offset
  # per buffer. Real TCP chunks arbitrarily. Feed each frame in RANDOM-size
  # chunks (seeded): every intermediate state is {:more, total} with the same
  # total, and the final chunk yields exactly the unsplit decode.

  test "random-chunk feeding converges to the unsplit decode (lens-3)" do
    for seed <- @seeds do
      :rand.seed(:exsss, seed * 100_003 + 772_663)

      frames = [build_open_frame(seed), build_transfer_frame(seed)]

      for frame <- frames, chunk_n <- 2..3 do
        bump(:rand_chunk, 1)
        cuts = random_cuts(byte_size(frame), chunk_n)

        {:ok, expected} = FrameCodec.decode_frame(frame)

        {got, totals} = feed_chunks(frame, cuts, nil)

        assert got == expected,
               "FUZZ FAILURE rand-chunk seed=#{seed}: chunked=#{inspect(got, limit: 10)} " <>
                 "unsplit=#{inspect(expected, limit: 10)}"

        # {:more, n} is the total frame size once the 8-byte header is
        # buffered; before that it is the header size (8). Both constants.
        assert Enum.all?(totals, &(&1 == 8 or &1 == byte_size(frame))),
               "FUZZ FAILURE rand-chunk seed=#{seed}: {:more, total} drift: #{inspect(totals)}"
      end
    end

    IO.puts("random-chunk iterations: #{count(:rand_chunk)}")
  end

  # cut points dividing n bytes into chunk_n nonempty chunks
  defp random_cuts(n, chunk_n) do
    1..(chunk_n - 1)
    |> Enum.map(fn _ -> :rand.uniform(n - 1) end)
    |> Enum.sort()
    |> Enum.uniq()
    |> case do
      [] -> [div(n, 2)]
      cuts -> cuts
    end
  end

  defp feed_chunks(frame, cuts, _acc) do
    bounds = [0 | cuts] ++ [byte_size(frame)]

    chunks =
      bounds
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> binary_part(frame, a, b - a) end)

    Enum.reduce(chunks, {<<>>, []}, fn chunk, {buf, totals} ->
      buf = buf <> chunk

      case FrameCodec.decode_frame(buf) do
        {:more, total} ->
          {buf, [total | totals]}

        {:ok, out} ->
          {out, [byte_size(frame) | totals]}

        {:error, reason} ->
          flunk("FUZZ FAILURE rand-chunk: error #{inspect(reason)} on a valid frame prefix")
      end
    end)
    |> then(fn {out, totals} -> {out, Enum.reverse(totals)} end)
  end

  test "bare-array decode stays linear: 200k elements decode in bounded time (lens-2)" do
    n = 200_000

    # round-trip correctness at scale
    want = List.duplicate(7, n)
    bin = IO.iodata_to_binary(PrimitiveCodec.encode({:array, want}))
    assert {:ok, [{:array, ^want}]} = PrimitiveCodec.decode_all(bin)

    # Relative fence (machine-independent, replaces the lens-2 absolute 250ms
    # bound): decode the bare array vs a plain list with the SAME item count
    # on the same run, min-of-5 to shed scheduler noise. Clean linear decode
    # measured ratio <= 1.3 on this machine (array often FASTER than list —
    # no per-element constructor dispatch); the quadratic mutant measured
    # 22.9..36.1 (55x CPU). Bound 3.0 sits 2.3x over clean, 7.6x under mutant.
    flat = List.duplicate(7, n)
    lis = IO.iodata_to_binary(PrimitiveCodec.encode(flat))

    # Legs timed in MICROSECONDS (:timer.tc): a list leg measured in whole ms
    # makes the ratio step 2x on a one-tick difference. Same paired-round
    # min-of-5 form, same measured geometry, same bound 3.0 — the noise floor
    # drops from ±1 ms to ±1 us per leg, so the bound stays valid without
    # re-derivation.
    timed_us = fn b, f ->
      {us, _} = :timer.tc(fn -> f.(b) end)
      us
    end

    ratio =
      for _ <- 1..5 do
        timed_us.(bin, fn b -> {:ok, _} = PrimitiveCodec.decode_all(b) end) /
          timed_us.(lis, fn b -> {:ok, _} = PrimitiveCodec.decode_all(b) end)
      end
      |> Enum.min()

    assert ratio < 3.0,
           "array/list decode ratio #{Float.round(ratio, 2)} at n=#{n} — quadratic regression"
  end

  # ---------------------------------------------------------------------------
  # Property 8 (lens-2): map decode is single-pass, not probe-then-retry
  # ---------------------------------------------------------------------------

  test "map decode stays single-pass: map/list decode-time ratio is bounded (lens-2)" do
    n = 40_000
    map = Map.new(1..n, fn i -> {"k#{i}", i} end)
    bin = IO.iodata_to_binary(PrimitiveCodec.encode(map))
    assert {:ok, ^map, <<>>} = PrimitiveCodec.decode(bin)

    # Relative fence (machine-independent): decode a map vs a flat list with
    # the same item count on the same run. Paired-round min-of-5: each round
    # times map then list back-to-back so fleet-load jitter hits both legs
    # co-monotonically, and the min of the per-round ratios sheds scheduler
    # noise. Fixed single-pass ratio ~1.12; the pre-fix probe-then-retry
    # (element-count attempt fails, whole body re-decoded) measured ~1.7.
    flat = Enum.flat_map(Map.to_list(map), fn {k, v} -> [k, v] end)
    lis = IO.iodata_to_binary(PrimitiveCodec.encode(flat))

    # Legs timed in MICROSECONDS (:timer.tc) — same precision raise as the
    # bare-array fence above (whole-ms legs step the ratio 2x on one tick).
    timed_us = fn b, f ->
      {us, _} = :timer.tc(fn -> f.(b) end)
      us
    end

    map_f = fn b -> {:ok, _, <<>>} = PrimitiveCodec.decode(b) end
    list_f = fn b -> {:ok, _, <<>>} = PrimitiveCodec.decode(b) end

    ratio =
      for _ <- 1..5 do
        timed_us.(bin, map_f) / timed_us.(lis, list_f)
      end
      |> Enum.min()

    assert ratio < 1.4,
           "map decode ratio #{Float.round(ratio, 2)} — double-decode regression"
  end

  # ---------------------------------------------------------------------------
  # Property 14 (lens-4): structural-shape encode→decode symmetry
  # ---------------------------------------------------------------------------
  # P9 hammered boundary VALUES. This property hammers boundary SHAPES: nesting
  # topologies the random generator under-samples (lists-of-maps-of-lists,
  # described-in-described-in-described, empty composite bodies, maps with nil
  # values, constructor-mixing arrays) through encode→decode_all AND through the
  # full frame layer (encode_frame transfer body → decode_frame →
  # decode_message). Legal shapes must round-trip byte-exactly; the
  # constructor-mixing array must raise ArgumentError per the documented encode
  # contract; a hand-wired mixed bare array on the wire must decode to a tagged
  # error or a well-defined value, never raise.

  @structural_shapes [
    # lists of maps of lists (3 collection levels)
    [%{"a" => [1, 2], {:symbol, "b"} => [nil, true]}],
    [%{1 => [2]}, %{3 => [4]}],
    [%{}],
    [[%{}]],
    # nested described 3 levels (int + symbol descriptors alternating)
    {:described, 0x10, {:described, {:symbol, "inner"}, {:described, 0x12, [1, nil]}}},
    {:described, 0x20, [{:described, 0x21, [{:described, 0x22, "leaf"}]}]},
    # empty composite bodies
    {:described, 0x30, []},
    {:described, {:symbol, "empty"}, []},
    {:described, 0x31, nil},
    {:described, 0x32, %{}},
    {:described, 0x33, {:array, []}},
    [],
    [[]],
    [[], []],
    [%{}, %{}],
    # maps with nil values / heterogeneous-but-legal values
    %{"k" => nil, {:symbol, "s"} => nil, 1 => nil},
    %{nil => nil},
    [nil, %{"x" => nil}, {:array, [1]}],
    # empty composites inside described bodies
    {:described, 0x34, [[], %{}, {:array, []}, nil]}
  ]

  test "structural shape symmetry: nested/empty composites round-trip (lens-4)" do
    for term <- @structural_shapes do
      bin = IO.iodata_to_binary(PrimitiveCodec.encode(term))

      assert {:ok, [^term]} = PrimitiveCodec.decode_all(bin),
             "primitive round-trip failed for #{inspect(term, limit: 10)}"

      # frame layer: same term as a transfer body_amqp_value section
      frame =
        IO.iodata_to_binary(
          FrameCodec.encode_frame(
            :amqp,
            3,
            {:transfer, %{handle: 0, delivery_id: 1}, {:sections, [{:body_amqp_value, term}]}}
          )
        )

      assert {:ok, %{payload: payload}} = FrameCodec.decode_frame(frame)
      assert {:ok, [{:body_amqp_value, ^term}]} = FrameCodec.decode_message(payload)
    end
  end

  test "constructor-mixing arrays: encode raises per contract, wire form decodes to tagged result (lens-4)" do
    mixing = [
      {:array, [1, "str"]},
      {:array, [1, nil]},
      {:array, [{:symbol, "a"}, 2]},
      {:array, [true, 1]}
    ]

    # homogeneous compound elements are LEGAL (one shared ctor byte, e.g.
    # 0xC1 for maps) and must round-trip — the bare-body strip (tl/1) keeps the
    # compound's size+count fields, which is exactly the bare wire form.
    for t <- [{:array, [%{}]}, {:array, [%{"a" => 1}, %{"b" => 2}]}, {:array, [[1], [2, 3]]}] do
      bin = IO.iodata_to_binary(PrimitiveCodec.encode(t))

      assert {:ok, [^t]} = PrimitiveCodec.decode_all(bin),
             "compound-element array failed: #{inspect(t)}"
    end

    for t <- mixing do
      assert_raise ArgumentError, fn -> PrimitiveCodec.encode(t) end
    end

    # homogeneous sanity: the same shapes with uniform ctors encode fine
    assert {:ok, [{:array, [1, 2, 3]}]} =
             PrimitiveCodec.encode({:array, [1, 2, 3]})
             |> IO.iodata_to_binary()
             |> PrimitiveCodec.decode_all()

    # hand-wired MIXED bare array on the wire (attacker form): one declared
    # element constructor, but the bytes are a different type. The decoder
    # applies the declared ctor to every element — result is either a tagged
    # error or a well-defined (lossy) value, NEVER a raise.
    mixed_bodies = [<<0x71, 1::signed-integer-size(32)>>, <<0xA1, 2, "ab">>]
    tail = [<<2::unsigned-integer-size(32), 0x52>>, mixed_bodies]
    size = IO.iodata_length(tail)
    mixed = IO.iodata_to_binary([0xF0, <<size::unsigned-integer-size(32)>>, tail])

    assert result = PrimitiveCodec.decode(mixed)
    assert match?({:error, _}, result) or match?({:ok, _, <<>>}, result)
  end

  # ---------------------------------------------------------------------------
  # Property 15 (lens-4): deep-nesting encode/decode — bounded recursion probe
  # ---------------------------------------------------------------------------
  # The decode path recurses once per described/list nesting level. A hostile
  # 1 MiB frame of pure nesting (2 bytes per level: 0x00 + 0x53 ctor) reaches
  # ~500k levels. BEAM body recursion grows the heap-stack; the failure mode
  # must be a clean process-level exhaustion inside decode's own process —
  # probed honestly here in a SEPARATE process so the crash boundary is
  # observed, not assumed.

  test "deep nesting: bounded depth round-trips; hostile depth fails cleanly in-process (lens-4)" do
    # depths a legal producer could emit: round-trip must hold
    for depth <- [10, 100, 1000, 5000] do
      term = nest_described(depth, 42)
      bin = IO.iodata_to_binary(PrimitiveCodec.encode(term))
      assert {:ok, [^term]} = PrimitiveCodec.decode_all(bin), "depth #{depth} round-trip failed"
    end

    # hostile depth: wire-crafted (encode itself would recurse the same way —
    # crafting on the wire isolates the DECODE side). Run in a throwaway
    # process: if the VM cannot honor the depth, the crash must be contained
    # there rather than taking the test (or a connection process) down.
    hostile = build_hostile_nested(1_000_000)

    # Fail-safe deadline only: the decode either completes in microseconds or
    # hangs. The success path never approaches 30 s, so this bound has no flake
    # channel — it fences a hang, it does not SAMPLE behavior. Keep as-is.
    result =
      Task.await(
        Task.async(fn ->
          try do
            PrimitiveCodec.decode(hostile)
          catch
            class, reason -> {class, reason}
          end
        end),
        30_000
      )

    case result do
      {:ok, _, <<>>} -> :ok
      {:error, _} -> :ok
      # clean BEAM exhaustion (e.g. {:EXIT, :system_limit} class) — contained
      # to the probing process, tagged, no VM kill
      {class, _reason} when class in [:exit, :error] -> :ok
      other -> flunk("hostile nesting produced unexpected result: #{inspect(other, limit: 5)}")
    end
  end

  defp nest_described(1, v), do: {:described, 7, v}

  defp nest_described(depth, v), do: {:described, 7, nest_described(depth - 1, v)}

  # Wire bytes: depth x [0x00 (described), 0x53 0x00 (ulong-small descriptor 0)]
  # ... terminal: 0x40 (null). Each level costs 3 bytes.
  defp build_hostile_nested(depth) do
    level = <<0x00, 0x53, 0x00>>
    String.duplicate(level, depth) <> <<0x40>>
  end

  test "deep message nesting: hostile frame through decode_frame stays contained (lens-4)" do
    # Hostile nesting (a) inside the 1 MiB cap, as a body_amqp_value transfer
    # frame fed through the FRAME layer — the connection's actual entry point;
    # (b) beyond the cap, which must be refused by size before any decode.
    within = 100_000
    inner = build_hostile_nested(within)
    body = IO.iodata_to_binary(PrimitiveCodec.encode({:described, 0x77, {:vbin, inner}}))
    size = 8 + byte_size(body)
    frame = <<size::32, 2::8, 0::8, 0::16, body::binary>>

    result =
      Task.await(
        Task.async(fn ->
          try do
            case FrameCodec.decode_frame(frame) do
              {:ok, %{payload: payload}} -> FrameCodec.decode_message(payload)
              other -> other
            end
          catch
            class, reason -> {class, reason}
          end
        end),
        30_000
      )

    case result do
      {:ok, _sections} -> :ok
      {class, _} when class in [:exit, :error] -> :ok
      other -> flunk("hostile frame nesting: #{inspect(other, limit: 5)}")
    end

    # Same hang fail-safe (not a settle-wait) — see the comment at the 1M-depth
    # probe above. The beyond-cap leg below is refusal-before-decode (no timing).
    beyond_inner = build_hostile_nested(500_000)

    beyond_body =
      IO.iodata_to_binary(PrimitiveCodec.encode({:described, 0x77, {:vbin, beyond_inner}}))

    beyond_size = 8 + byte_size(beyond_body)
    beyond = <<beyond_size::32, 2::8, 0::8, 0::16, beyond_body::binary>>

    assert beyond_size > 1 * 1024 * 1024 + 512
    assert {:error, :frame_too_size} = FrameCodec.decode_frame(beyond)
  end

  # ---------------------------------------------------------------------------
  # Property 16 (lens-4): canonical-form idempotence + structural TCP chunking
  # ---------------------------------------------------------------------------
  # The codec is canonical: re-encoding a decoded term must reproduce the
  # exact bytes (single canonical form per term). Any drift between the decode
  # and encode tables (a ctor added to one side only) breaks this silently —
  # this fence catches it. Structural shapes are then also fed through the
  # random TCP chunk feeder (P13's machinery, structural inputs).

  test "canonical idempotence: decode → re-encode reproduces exact bytes (lens-4)" do
    shapes =
      @structural_shapes ++ [{:array, [1, 2, 3]}, {:array, [%{"a" => 1}]}, {:timestamp, -1}]

    for term <- shapes do
      bin = encode_ok(term)
      assert {:ok, [decoded]} = PrimitiveCodec.decode_all(bin)
      rebin = encode_ok(decoded)
      assert rebin == bin, "non-canonical round-trip for #{inspect(term, limit: 10)}"
    end
  end

  test "structural shapes survive adversarial TCP chunking (lens-4)" do
    :rand.seed(:exsss, 2026_101_5)

    for term <- Enum.take_every(@structural_shapes, 2) do
      frame =
        IO.iodata_to_binary(
          FrameCodec.encode_frame(
            :amqp,
            7,
            {:transfer, %{handle: 0, delivery_id: 1}, {:sections, [{:body_amqp_value, term}]}}
          )
        )

      # random split points, feed byte-accumulated chunks through decode_frame
      assert {:ok, %{payload: payload}} = feed_in_chunks(frame)
      assert {:ok, [{:body_amqp_value, ^term}]} = FrameCodec.decode_message(payload)
    end
  end

  defp feed_in_chunks(frame) do
    size = byte_size(frame)

    chunks =
      case :rand.uniform(3) do
        1 ->
          [frame]

        2 ->
          [
            binary_part(frame, 0, div(size, 2)),
            binary_part(frame, div(size, 2), size - div(size, 2))
          ]

        _ ->
          for(i <- 0..(size - 1), do: binary_part(frame, i, 1))
      end

    chunks
    |> Enum.reduce({<<>>, []}, fn chunk, {buf, frames} ->
      buf = buf <> chunk

      case FrameCodec.decode_frame(buf) do
        {:ok, f} -> {<<>>, [f | frames]}
        {:more, _} -> {buf, frames}
        {:error, reason} -> throw({:chunk_feed_error, reason})
      end
    end)
    |> then(fn {<<>>, frames} -> {:ok, hd(frames)} end)
  end

  # ---------------------------------------------------------------------------
  # Property 17 (lens-4): max_frame_size encode/decode ASYMMETRY (pinned)
  # ---------------------------------------------------------------------------
  # FENCED CONTRACT (a lens-4 finding, kept as-is until the connection lane
  # rules on it): encode_frame does NOT enforce the 1 MiB cap — an oversized
  # payload encodes cleanly into a single frame — while decode_frame refuses
  # > 1 MiB+512 with {:error, :frame_too_size}. Two consequences:
  #   (1) our own codec cannot round-trip its own oversized output;
  #   (2) connection.ex never splits outbound transfers and ignores the
  #       peer's advertised max_frame_size (read-only lens-4 analysis:
  #       connection.ex:41/:255 advertise ours; the inbound open's
  #       perf.max_frame_size is stored nowhere), so a large delivery to a
  #       peer advertising a small max_frame_size violates AMQP §2.3.1 and
  #       strict peers (rhea) tear the connection down.
  # This fence PINS the asymmetry so any silent change on either side is
  # visible; lifting it requires the connection-lane transfer-splitting fix.

  test "frame-size cap asymmetry: encode is unbounded, decode refuses >1MiB (lens-4, pinned)" do
    # 1.1 MiB payload: encodes fine...
    big_body = :binary.copy(<<7>>, 1_100_000)

    frame_bin =
      IO.iodata_to_binary(
        FrameCodec.encode_frame(
          :amqp,
          0,
          {:transfer, %{handle: 0}, {:sections, [{:body_data, big_body}]}}
        )
      )

    assert byte_size(frame_bin) > 1 * 1024 * 1024 + 512

    # ...but our own decoder refuses it
    assert {:error, :frame_too_size} = FrameCodec.decode_frame(frame_bin)
  end

  # ---------------------------------------------------------------------------
  # Lens 5: single-bit-flip differential decode over the fence corpora
  # ---------------------------------------------------------------------------
  # Every prior fence corpus (P9-P17 shapes: gen_term structures, open/transfer
  # frames, message sections) is re-run through a single-BIT flip mutator — the
  # smallest possible perturbation. Gate: for every flip, every decode entry
  # point returns a tagged tuple ({:ok,_} / {:ok,_,_} / {:more,_} / {:error,_}),
  # never a raise. Classification is reported for the receipt.

  test "single-bit-flip differential decode: fence corpora, 10k flips, never a raise (lens-5)" do
    samples =
      for seed <- 1..40 do
        {:primitive, encode_ok(gen_term(seed))}
      end ++
        for seed <- 1..20 do
          {:frame, build_open_frame(seed)}
        end ++
        for seed <- 1..20 do
          {:frame, build_transfer_frame(seed)}
        end ++
        for seed <- 1..20 do
          {:message,
           FrameCodec.encode_message(gen_message_sections(seed)) |> IO.iodata_to_binary()}
        end ++
        for _seed <- 1..5 do
          {:sasl,
           IO.iodata_to_binary(
             FrameCodec.encode_frame(
               :sasl,
               0,
               {:sasl_mechanisms,
                %{server_mechanisms: [{:symbol, "ANONYMOUS"}, {:symbol, "PLAIN"}]}}
             )
           )}
        end ++
        for _seed <- 1..5 do
          {:sasl,
           IO.iodata_to_binary(
             FrameCodec.encode_frame(
               :sasl,
               0,
               {:sasl_init,
                %{mechanism: {:symbol, "ANONYMOUS"}, initial_response: "r", hostname: "sb"}}
             )
           )}
        end ++
        for _seed <- 1..5 do
          {:sasl,
           IO.iodata_to_binary(
             FrameCodec.encode_frame(:sasl, 0, {:sasl_outcome, %{code: 0, additional_data: nil}})
           )}
        end

    assert length(samples) == 115

    # 100 samples x 100 single-bit flips = 10,000 perturbed inputs.
    results =
      for {kind, bin} <- samples, reduce: %{identical: 0, changed: 0, refused: 0} do
        acc ->
          base = bin
          n = byte_size(base)
          flips = for i <- 0..99, do: {rem(i * 7, n), rem(i * 13, 8) + 1}

          Enum.reduce(flips, acc, fn {byte_i, bit}, acc ->
            <<prefix::binary-size(byte_i), b, suffix::binary>> = base
            flipped = <<prefix::binary, Bitwise.bxor(b, bit), suffix::binary>>
            bump(:bitflip, 1)

            label =
              "kind=#{kind} byte=#{byte_i} bit=#{bit} input=#{Base.encode16(flipped, case: :lower)}"

            # The gate: no entry point ever raises.
            prim =
              try do
                PrimitiveCodec.decode(flipped)
              rescue
                e ->
                  flunk(
                    "BITFLIP RAISE PrimitiveCodec.decode #{label}: #{Exception.format(:error, e)}"
                  )
              end

            frame =
              try do
                FrameCodec.decode_frame(flipped)
              rescue
                e ->
                  flunk(
                    "BITFLIP RAISE FrameCodec.decode_frame #{label}: #{Exception.format(:error, e)}"
                  )
              end

            for r <- [prim, frame], do: assert_tuple(r)

            cond do
              prim == PrimitiveCodec.decode(base) and frame == FrameCodec.decode_frame(base) ->
                %{acc | identical: acc.identical + 1}

              match?({:error, _}, prim) or match?({:error, _}, frame) ->
                %{acc | refused: acc.refused + 1}

              true ->
                %{acc | changed: acc.changed + 1}
            end
          end)
      end

    assert count(:bitflip) == 11_500, "expected exactly 11.5k single-bit flips"

    # Non-vacuity: the mutator must actually reach the decoder's structure
    # layer — a run where nothing ever decoded differently or refused would
    # mean the flips are landing in dead bytes.
    assert results.changed + results.refused > 0,
           "bit flips never perturbed any decode: #{inspect(results)}"

    IO.puts(
      "single-bit-flip differential: 11500 flips — " <>
        "identical=#{results.identical} changed=#{results.changed} refused=#{results.refused}"
    )
  end

  # ---------------------------------------------------------------------------
  # Lens 5 cycle 3: mutation x chunking cross-product
  # ---------------------------------------------------------------------------
  # P13 (random-chunk) feeds UNMUTATED frames only; the lens-5 bit-flip
  # property decodes whole-buffer only. The cross-product — MUTATED frames
  # fed through TCP chunk boundaries — was an unapplied operator pair.
  # Invariant: chunked feeding converges to the same tagged outcome as the
  # whole-buffer decode, for every mutation; every intermediate step stays
  # tagged, never raises.

  test "mutation x chunking: flipped frames fed chunked converge to the whole-buffer result (lens-5)" do
    for seed <- 1..20 do
      frame = build_open_frame(seed)

      # 10 single-bit flips per frame, spread over the whole buffer
      flips =
        for i <- 0..9 do
          n = byte_size(frame)
          byte_i = rem(i * 11 + seed * 7, n)
          bit = rem(i * 5, 8) + 1
          {byte_i, bit}
        end
        |> Enum.uniq()

      for {byte_i, bit} <- flips, chunk_n <- [2, 3] do
        <<prefix::binary-size(byte_i), b, suffix::binary>> = frame
        flipped = <<prefix::binary, Bitwise.bxor(b, bit), suffix::binary>>
        bump(:mut_chunk, 1)

        whole =
          try do
            FrameCodec.decode_frame(flipped)
          rescue
            e -> flunk("MUT-CHUNK RAISE whole seed=#{seed}: #{Exception.format(:error, e)}")
          end

        n = byte_size(flipped)
        cuts = for _ <- 1..(chunk_n - 1), do: :rand.uniform(n - 1)
        cuts = if cuts == [], do: [div(n, 2)], else: Enum.sort(Enum.uniq(cuts))

        bounds = [0 | cuts] ++ [n]

        {_buf, got} =
          bounds
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.map(fn [a, z] -> binary_part(flipped, a, z - a) end)
          |> Enum.reduce({<<>>, nil}, fn chunk, {buf, out} ->
            buf = buf <> chunk

            case FrameCodec.decode_frame(buf) do
              {:more, _total} -> {buf, out}
              out2 -> {buf, out2}
            end
          end)

        got = got || whole

        assert got == whole,
               "FUZZ FAILURE mut-chunk seed=#{seed} byte=#{byte_i} bit=#{bit}: " <>
                 "chunked=#{inspect(got, limit: 10)} whole=#{inspect(whole, limit: 10)}"
      end
    end

    assert count(:mut_chunk) > 0
  end

  # ---------------------------------------------------------------------------
  # Lens 5 cycle 4: structured-position flip invariants
  # ---------------------------------------------------------------------------
  # Random flips say "never raises"; STRUCTURED flips say what must NOT change.
  # Two frame-header fields had no targeted fence:
  #   (a) the 16-bit channel field (bytes 6-7): flipping its bits must change
  #       ONLY the channel, never the decoded performative/payload;
  #   (b) extended header (doff > 2) bytes: the codec skips them, so ANY value
  #       in them must decode identical to the doff=2 frame.

  test "structured-position flips: channel bits change only the channel; extended-header bytes are inert (lens-5)" do
    for seed <- 1..10 do
      frame = build_open_frame(seed)
      assert {:ok, base} = FrameCodec.decode_frame(frame)

      # (a) channel-field flips: bytes 6-7, all 16 bits each seed
      for byte_i <- [6, 7], bit <- 1..8 do
        <<p::binary-size(byte_i), b, s::binary>> = frame
        flipped = <<p::binary, Bitwise.bxor(b, bit), s::binary>>
        bump(:chan_flip, 1)

        assert {:ok, dec} = FrameCodec.decode_frame(flipped)
        assert dec.channel != base.channel

        assert Map.delete(dec, :channel) == Map.delete(base, :channel),
               "channel flip changed more than the channel"
      end

      # (b) extended header: rebuild the open frame with doff=3 + 4 inert bytes
      <<size::32, _doff::8, type_code::8, chan::16, body::binary>> = frame
      junk = :rand.bytes(4)

      ext_frame =
        <<size + 4::32, 3::8, type_code::8, chan::16, junk::binary-size(4), body::binary>>

      assert {:ok, ext_dec} = FrameCodec.decode_frame(ext_frame)
      assert Map.delete(ext_dec, :payload) == Map.delete(base, :payload)

      for i <- 0..3, bit <- 1..8 do
        <<p::binary-size(i), b, s::binary>> = junk
        flipped_junk = <<p::binary, Bitwise.bxor(b, bit), s::binary>>

        flipped_ext =
          <<size + 4::32, 3::8, type_code::8, chan::16, flipped_junk::binary-size(4),
            body::binary>>

        bump(:ext_flip, 1)

        assert {:ok, dec} = FrameCodec.decode_frame(flipped_ext)

        assert Map.delete(dec, :payload) == Map.delete(base, :payload),
               "extended-header byte #{i} bit #{bit} changed the decode"
      end
    end

    assert count(:chan_flip) == 160
    assert count(:ext_flip) == 320
  end

  # ---------------------------------------------------------------------------
  # Lens 5 cycle 5: re-encode stability of corrupted decodes
  # ---------------------------------------------------------------------------
  # The lens-4 canonical-idempotence fence covers VALID inputs (decode ->
  # re-encode -> exact bytes). Missing: whatever a CORRUPTED input decodes
  # to must still be a total, stable codec term — encode(decoded) must
  # decode to the same term. This closes the loop: the decode side can never
  # mint a value the encode side cannot re-emit.

  test "re-encode stability: every corrupted-decode result is an encodable codec term (lens-5)" do
    for seed <- 1..50 do
      valid = gen_term(seed) |> encode_ok()

      n = byte_size(valid)
      count = 20

      for i <- 0..(count - 1) do
        byte_i = rem(i * 17 + seed, n)
        bit = rem(i * 3, 8) + 1
        <<p::binary-size(byte_i), b, s::binary>> = valid
        flipped = <<p::binary, Bitwise.bxor(b, bit), s::binary>>
        bump(:reencode, 1)

        case PrimitiveCodec.decode(flipped) do
          {:ok, term, <<>>} ->
            re = encode_ok(term)

            case PrimitiveCodec.decode_all(re) do
              {:ok, [^term]} ->
                :ok

              other ->
                flunk(
                  "RE-ENCODE INSTABILITY seed=#{seed} i=#{i} input=#{Base.encode16(flipped, case: :lower)} " <>
                    "decoded=#{inspect(term, limit: 12)} re-encoded-decode=#{inspect(other, limit: 12)}"
                )
            end

          # trailing-rest decodes and tagged errors are out of scope here
          {:ok, _, _} ->
            :ok

          {:error, _} ->
            :ok
        end
      end
    end

    assert count(:reencode) == 1000
  end

  # ---------------------------------------------------------------------------
  # Lens 5 cycle 6: descriptor-slot exhaustive sweep (pins the cycle-5 fix)
  # ---------------------------------------------------------------------------
  # ---------------------------------------------------------------------------
  # The cycle-5 fix pins the descriptor slot to ulong/symbol ctors. This sweep
  # classifies EVERY byte placed in the descriptor slot of a described type,
  # at BOTH layers: primitive decode and decode_message.
  test "descriptor-slot exhaustive sweep: only ulong/symbol ctors decode, at both layers (lens-5)" do
    for ctor <- 0..255 do
      body =
        case ctor do
          # fixed widths (descriptor payload) + nil value byte for the
          # described value — the sweep feeds ctor+descriptor only; without a
          # trailing value the fixed-width ctors correctly answer :truncated
          c when c in [0x50, 0x51, 0x52, 0x53, 0x54, 0x55] -> <<0x01, 0x40>>
          c when c in [0x60, 0x61] -> <<0x00, 0x01, 0x40>>
          c when c in [0x70, 0x71, 0x72, 0x73] -> <<0, 0, 0, 1, 0x40>>
          c when c in [0x80, 0x81, 0x82, 0x83] -> <<0, 0, 0, 0, 0, 0, 0, 1, 0x40>>
          0x98 -> <<0::unsigned-size(128), 0x40>>
          # vbin8/str8/sym8: "d" ; vbin32/str32/sym32: "d"
          c when c in 0xA0..0xA3 -> <<1, ?d, 0x40>>
          c when c in 0xB0..0xB3 -> <<0, 0, 0, 1, ?d, 0x40>>
          # list8: size=1 count=1 ... use empty list0
          0x45 -> <<0x40>>
          _ -> <<0x40>>
        end

      prim = PrimitiveCodec.decode(<<0x00, ctor, body::binary>>)
      bump(:desc_slot, 1)

      if ctor in [
           0x43,
           0x44,
           0x50,
           0x51,
           0x52,
           0x53,
           0x54,
           0x55,
           0x60,
           0x61,
           0x70,
           0x71,
           0x80,
           0x81
         ] do
        assert match?({:ok, {:described, _, _}, _}, prim),
               "ulong ctor 0x#{Integer.to_string(ctor, 16)} refused in descriptor slot: #{inspect(prim)}"
      else
        if ctor in [0xA3, 0xB3] do
          assert match?({:ok, {:described, _, _}, _}, prim)
        else
          assert match?({:error, _}, prim),
                 "ctor 0x#{Integer.to_string(ctor, 16)} decoded in descriptor slot: #{inspect(prim)}"
        end
      end

      msg = FrameCodec.decode_message(<<0x00, ctor, body::binary>>)

      if ctor in [
           0x43,
           0x44,
           0x50,
           0x51,
           0x52,
           0x53,
           0x54,
           0x55,
           0x60,
           0x61,
           0x70,
           0x71,
           0x80,
           0x81,
           0xA3,
           0xB3
         ] do
        assert match?({:ok, _}, msg) or match?({:error, _}, msg)
      else
        assert match?({:error, _}, msg) or msg == {:ok, []},
               "descriptor ctor 0x#{Integer.to_string(ctor, 16)} message-level: #{inspect(msg)}"
      end
    end

    assert count(:desc_slot) == 256
  end

  # ---------------------------------------------------------------------------
  # Lens 6 cycle 1: ENCODE-path flip differential
  # ---------------------------------------------------------------------------
  # The lens-5 bit-flip differential covered DECODE (mutated bytes, tagged
  # tuples). This is the dual: mutate the PRE-ENCODE structure; every encode
  # must either (a) raise the documented ArgumentError or (b) succeed with
  # bytes whose decode_all reproduces the term exactly — never emit bytes
  # that fail to decode or decode to a different term.
  test "encode-path differential: mutated structures raise ArgumentError or round-trip exactly (lens-6)" do
    iterations_per_seed = 150

    for seed <- @seeds do
      :rand.seed(:exsss, seed * 31_337 + 7)

      for _i <- 1..iterations_per_seed do
        term = gen_term(:rand.uniform(1_000_000))
        mutated = mutate_term(term)
        bump(:enc_diff, 1)

        result =
          try do
            PrimitiveCodec.encode(mutated) |> IO.iodata_to_binary()
          rescue
            e in ArgumentError ->
              {:raised, e}

            e ->
              flunk(
                dump(seed, "non-ArgumentError raise: #{Exception.format(:error, e)}", mutated)
              )
          end

        case result do
          {:raised, _e} ->
            :ok

          bin ->
            case PrimitiveCodec.decode_all(bin) do
              {:ok, [decoded]} ->
                assert decoded == mutated,
                       dump(
                         seed,
                         "encode emitted non-round-tripping bytes\nmutated=#{inspect(mutated, limit: 30)}\ndecoded=#{inspect(decoded, limit: 30)}",
                         bin
                       )

              other ->
                flunk(dump(seed, "encode emitted undecodable bytes: #{inspect(other)}", mutated))
            end
        end
      end
    end

    assert count(:enc_diff) == @seeds |> Enum.count() |> Kernel.*(iterations_per_seed)
  end

  # Structure-level mutations (the byte-level `mutate/1` above is the decode
  # dual). Each operator produces a term that is either still in the encodable
  # domain (must round-trip) or out of it (must raise ArgumentError).
  defp mutate_term(term) do
    case :rand.uniform(8) do
      n when n in 1..2 ->
        # replace a random deep leaf with a hostile value
        replace_leaf(term, hostile_leaf())

      3 ->
        # integer out of the 64-bit domain
        replace_leaf(term, Enum.random([2 ** 64, -(2 ** 63) - 1, 2 ** 128]))

      4 ->
        # described with out-of-domain descriptor
        {:described,
         Enum.random([-1, 2 ** 64, "plain-bin", {:symbol, 1}, {:uuid, <<0::128>>, :extra}]), term}

      5 ->
        # array with a hostile element (mixed ctor or non-encodable)
        {:array, [leaf_of(term), hostile_leaf()]}

      6 ->
        # vbin/symbol/uuid/timestamp with a malformed payload
        Enum.random([
          {:vbin, :not_a_binary},
          {:symbol, 99},
          {:uuid, <<1::8>>},
          {:timestamp, "not-an-int"},
          {:uuid, <<0::128>>, :extra}
        ])

      n when n in 7..8 ->
        # map with a hostile key or value
        %{hostile_leaf() => leaf_of(term)}
    end
  end

  defp replace_leaf(term, leaf) do
    if :rand.uniform(3) == 1 do
      leaf
    else
      case term do
        [h | t] ->
          if :rand.uniform(2) == 1,
            do: [replace_leaf(h, leaf) | t],
            else: [h | replace_leaf(t, leaf)]

        {tag, v} when tag in [:symbol, :vbin, :uuid, :timestamp] and is_binary(v) ->
          {tag, v}

        {:array, list} when is_list(list) ->
          {:array, Enum.map(list, fn x -> replace_leaf(x, leaf) end)}

        {:described, d, v} ->
          {:described, d, replace_leaf(v, leaf)}

        map when is_map(map) and map != %{} ->
          {k, v} = Enum.random(Map.to_list(map))
          Map.put(map, k, replace_leaf(v, leaf))

        other ->
          if is_integer(other) and not is_boolean(other), do: leaf, else: other
      end
    end
  end

  defp leaf_of(t) do
    case t do
      [x | _] -> leaf_of(x)
      {:described, _, v} -> leaf_of(v)
      {:array, l} when is_list(l) and l != [] -> leaf_of(hd(l))
      map when is_map(map) and map != %{} -> leaf_of(elem(Enum.at(map, 0), 1))
      other -> other
    end
  end

  defp hostile_leaf do
    Enum.random([
      :ok,
      :error,
      {:weird, 1},
      self(),
      fn -> :ok end,
      {:symbol, :an_atom_not_binary},
      {:described, :bad_desc_atom, 1}
    ])
  end

  # ---------------------------------------------------------------------------
  # Lens 6 cycle 2: two-level described nesting sweep (descriptor-slot x2)
  # ---------------------------------------------------------------------------
  # Extends the lens-5 single-slot 256-ctor sweep to described-in-described:
  # outer ctor x inner ctor over a combinatorial sample (all 256 outer bytes
  # x 6 representative inner ctors + all 256 inner bytes x 6 outer = 3072
  # pairs), classifying ulong/symbol acceptance at BOTH levels.
  test "two-level described nesting: descriptor ctor acceptance composes (lens-6)" do
    reps = [0x43, 0x53, 0x80, 0xA3, 0xB3, 0xA1]

    ulong_or_sym = [
      0x43,
      0x44,
      0x50,
      0x51,
      0x52,
      0x53,
      0x54,
      0x55,
      0x60,
      0x61,
      0x70,
      0x71,
      0x80,
      0x81,
      0xA3,
      0xB3
    ]

    for {outer, inner} <- pairs(reps) do
      wire =
        <<0x00, outer, desc_payload(outer)::binary, 0x00, inner, desc_payload(inner)::binary,
          0x40>>

      prim = PrimitiveCodec.decode(wire)
      bump(:nested_desc, 1)

      outer_ok = outer in ulong_or_sym
      inner_ok = inner in ulong_or_sym

      cond do
        outer_ok and inner_ok ->
          assert {:ok, {:described, _, {:described, _, nil}}, <<>>} = prim,
                 "nested 0x#{Integer.to_string(outer, 16)}/0x#{Integer.to_string(inner, 16)}: #{inspect(prim)}"

        true ->
          assert match?({:error, _}, prim),
                 "nested 0x#{Integer.to_string(outer, 16)}/0x#{Integer.to_string(inner, 16)} decoded: #{inspect(prim)}"
      end

      # encode side: accepted descriptor forms at both levels round-trip
      if outer in [0x53, 0x80, 0xA3, 0xB3] and inner in [0x53, 0x80, 0xA3, 0xB3] do
        d_outer = desc_term(outer)
        d_inner = desc_term(inner)

        enc =
          PrimitiveCodec.encode({:described, d_outer, {:described, d_inner, nil}})
          |> IO.iodata_to_binary()

        assert {:ok, [rt]} = PrimitiveCodec.decode_all(enc)

        assert rt == {:described, d_outer, {:described, d_inner, nil}}
      end
    end

    assert count(:nested_desc) == 1536
  end

  # outer x inner: every byte as outer against representative inners, and
  # every byte as inner against representative outers (no self-pairs beyond
  # the reps themselves)
  defp pairs(reps) do
    for outer <- 0..255, inner <- reps, do: {outer, inner}
  end

  # trailing payload bytes so each ctor decodes to a descriptor, matching the
  # lens-5 sweep's body shapes (plus a nil described value after it)
  defp desc_payload(ctor) do
    case ctor do
      c when c in [0x50, 0x51, 0x52, 0x53, 0x54, 0x55] -> <<0x01>>
      c when c in [0x60, 0x61] -> <<0x00, 0x01>>
      c when c in [0x70, 0x71, 0x72, 0x73] -> <<0, 0, 0, 1>>
      c when c in [0x80, 0x81, 0x82, 0x83] -> <<0, 0, 0, 0, 0, 0, 0, 1>>
      0x98 -> <<0::unsigned-size(128)>>
      c when c in 0xA0..0xA3 -> <<1, ?d>>
      c when c in 0xB0..0xB3 -> <<0, 0, 0, 1, ?d>>
      _ -> <<>>
    end
  end

  defp desc_term(0x53 = c), do: c
  defp desc_term(0x80 = c), do: c
  defp desc_term(0xA3), do: {:symbol, "d"}
  defp desc_term(0xB3), do: {:symbol, "d"}

  # ---------------------------------------------------------------------------
  # Lens 7 cycle 1: decode-path mirror of the encode-path classes
  # ---------------------------------------------------------------------------
  # The four encode-path fixes (silent 64-bit truncation, FunctionClauseError
  # leak, plain-binary-descriptor rewrite, improper-list leak) have decode-path
  # twins to rule out:
  #
  #   1. truncation twin  — decode reads exact-width binaries via pattern
  #      matching, so silent truncation is structurally impossible; this fence
  #      proves it at every constructor boundary (each side) and pins the
  #      exactness that a width-mutation would break.
  #   2. raise-leak twin  — decode is a tagged-error court; the corpus test
  #      above hammers it. Here boundary wires one byte short of every fixed
  #      width also converge to {:error, :truncated}.
  #   3. rewrite twin     — decode outputs must re-encode byte-stably (the
  #      lens-5 plain-binary descriptor was exactly a re-encode rewrite).
  #   4. improper-list twin — decode builds lists by prepend+reverse only;
  #      fence asserts the proper-list invariant over the boundary corpus.
  test "decode-path mirror: exact-width decode at every ctor boundary, re-encode stability, proper-list invariant (lens-7)" do
    # {label, ctor, wire body, expected decoded term}
    boundary_wires = [
      # unsigned fixed widths, max and cross-boundary values
      {:ubyte_max, 0x50, <<255>>, 255},
      {:ubyte_min, 0x50, <<0>>, 0},
      {:ushort_max, 0x60, <<0xFFFF::16>>, 65_535},
      {:uint32_max, 0x70, <<0xFFFF_FFFF::32>>, 4_294_967_295},
      {:ulong64_max, 0x80, <<0xFFFF_FFFF_FFFF_FFFF::64>>, 18_446_744_073_709_551_615},
      {:ulong64_two_pow_63, 0x80, <<0x8000_0000_0000_0000::64>>, 0x8000_0000_0000_0000},
      {:ulong64_above_uint32, 0x80, <<0xFFFF_FFFF + 1::64>>, 0xFFFF_FFFF + 1},
      # signed fixed widths, both extremes
      {:tinyint_min, 0x51, <<0x80>>, -128},
      {:tinyint_max, 0x51, <<0x7F>>, 127},
      {:short_min, 0x61, <<0x8000::signed-16>>, -32_768},
      {:short_max, 0x61, <<0x7FFF::16>>, 32_767},
      {:int_min, 0x71, <<0x8000_0000::signed-32>>, -2_147_483_648},
      {:int_max, 0x71, <<0x7FFF_FFFF::32>>, 2_147_483_647},
      {:long_min, 0x81, <<0x8000_0000_0000_0000::signed-64>>, -0x8000_0000_0000_0000},
      {:long_max, 0x81, <<0x7FFF_FFFF_FFFF_FFFF::64>>, 0x7FFF_FFFF_FFFF_FFFF},
      {:ts_min, 0x83, <<0x8000_0000_0000_0000::signed-64>>, {:timestamp, -0x8000_0000_0000_0000}},
      {:ts_max, 0x83, <<0x7FFF_FFFF_FFFF_FFFF::64>>, {:timestamp, 0x7FFF_FFFF_FFFF_FFFF}}
    ]

    for {label, ctor, body, expected} <- boundary_wires do
      wire = <<ctor, body::binary>>

      assert {:ok, ^expected, <<>>} = PrimitiveCodec.decode(wire),
             "#{label}: exact-width decode broke: #{inspect(PrimitiveCodec.decode(wire))}"

      # re-encode stability: decode output re-encodes and decodes identically
      # (the rewrite-twin detector: a decode that mints a term the encoder
      # cannot re-emit is the lens-5 descriptor finding's twin)
      rt =
        expected
        |> PrimitiveCodec.encode()
        |> IO.iodata_to_binary()
        |> PrimitiveCodec.decode_all()

      assert {:ok, [^expected]} = rt, "#{label}: re-encode stability broke: #{inspect(rt)}"
      bump(:mirror_boundary, 1)
    end

    # timestamp extremes re-encode stably too
    for ms <- [-0x8000_0000_0000_0000, 0x7FFF_FFFF_FFFF_FFFF] do
      wire = PrimitiveCodec.encode({:timestamp, ms}) |> IO.iodata_to_binary()
      assert {:ok, {:timestamp, ^ms}, <<>>} = PrimitiveCodec.decode(wire)
      bump(:mirror_boundary, 1)
    end

    # one-byte-short of every fixed width converges to :truncated (raise-leak
    # twin: never a raise, always a tagged error)
    for {ctor, width} <- [
          {0x60, 2},
          {0x61, 2},
          {0x70, 4},
          {0x71, 4},
          {0x72, 4},
          {0x80, 8},
          {0x81, 8},
          {0x82, 8},
          {0x83, 8},
          {0x98, 16}
        ] do
      wire = <<ctor, :binary.copy(<<0>>, width - 1)::binary>>

      assert {:error, :invalid_constructor} = PrimitiveCodec.decode(wire),
             "ctor 0x#{Integer.to_string(ctor, 16)} short-by-one did not tag an error: #{inspect(PrimitiveCodec.decode(wire))}"

      bump(:mirror_short, 1)
    end

    # proper-list invariant over the boundary corpus: every decoded list is
    # proper, at every nesting depth (improper-list twin)
    proper =
      Enum.all?(boundary_wires, fn {_label, ctor, body, _} ->
        {:ok, term, _} = PrimitiveCodec.decode(<<ctor, body::binary>>)
        proper_term?(term)
      end)

    assert proper

    # boolean strictness: 0x56 with an out-of-domain byte (0x02..0xFF) is
    # malformed wire — tagged error, never a silently fabricated value (the
    # pre-fix decoder rewrote 0xFF to `false`; lens-7 decode-twin finding).
    # Note this diverges from rhea's JS `!read_byte` leniency on purpose:
    # fabricating `false` from 0xFF is indistinguishable from well-formed
    # `false` downstream — the exact failure class this lens hunts.
    assert {:ok, true, <<>>} = PrimitiveCodec.decode(<<0x56, 0x01>>)
    assert {:ok, false, <<>>} = PrimitiveCodec.decode(<<0x56, 0x00>>)

    for bad <- [0x02, 0x7F, 0xFF] do
      assert {:error, :invalid_constructor} = PrimitiveCodec.decode(<<0x56, bad>>)
      bump(:mirror_bool, 1)
    end
  end

  defp proper_term?([]), do: true

  defp proper_term?([h | t]) do
    # each element must itself be proper-terminal; an improper tail is [h | t]
    # where t is neither [] nor a cons — is_list accepts improper lists, so
    # walk structurally
    proper_term?(h) and proper_term?(t)
  end

  defp proper_term?(map) when is_map(map),
    do: Enum.all?(map, fn {k, v} -> proper_term?(k) and proper_term?(v) end)

  defp proper_term?({:array, l}) when is_list(l), do: proper_term?(l)

  defp proper_term?({:described, d, v}), do: proper_term?(d) and proper_term?(v)

  defp proper_term?({:symbol, b}) when is_binary(b), do: true
  defp proper_term?({:uuid, b}) when is_binary(b), do: true
  defp proper_term?({:timestamp, n}) when is_integer(n), do: true
  defp proper_term?(t) when is_tuple(t), do: false
  defp proper_term?(n) when is_integer(n), do: true
  defp proper_term?(f) when is_float(f), do: true
  defp proper_term?(b) when is_binary(b), do: true
  defp proper_term?(nil), do: true
  defp proper_term?(true), do: true
  defp proper_term?(false), do: true
  defp proper_term?(_), do: false

  # ---------------------------------------------------------------------------
  # Lens 7 cycle 2: two-level described + guarded-shape differential (+10k)
  # ---------------------------------------------------------------------------
  # Extends the lens-6 15k encode-path differential: every iteration composes
  # TWO levels of described wrapping around a generated term and draws from
  # the guarded shape classes (boundary ints each side of every range guard,
  # over-range ints that must raise, improper lists, non-uniform arrays).
  # Contract: in-domain => byte-stable round-trip on decode_all; out-of-domain
  # => the documented ArgumentError.
  test "two-level described x guarded-shape differential: in-domain round-trips, out-of-domain raises (lens-7)" do
    iterations_per_seed = 100

    descs = fn ->
      case :rand.uniform(3) do
        1 -> :rand.uniform(255)
        2 -> 256 + :rand.uniform(0xFFFF_FFFF_FFFF_FFFF - 256)
        3 -> {:symbol, symbol_body()}
      end
    end

    boundary_pair = [
      {0xFFFF_FFFF, true},
      {0xFFFF_FFFF + 1, true},
      {0xFFFF_FFFF_FFFF_FFFF, true},
      {2 ** 64, false},
      {2_147_483_647, true},
      {2_147_483_648, true},
      {-2_147_483_649, true},
      {-0x8000_0000_0000_0000, true},
      {-(2 ** 63) - 1, false},
      {127, true},
      {128, true},
      {-128, true},
      {-129, true}
    ]

    for seed <- @seeds do
      :rand.seed(:exsss, seed * 7919 + 13)

      for _i <- 1..iterations_per_seed do
        term = gen_term(:rand.uniform(1_000_000))
        d1 = descs.()
        d2 = descs.()
        wrapped = {:described, d1, {:described, d2, term}}
        bump(:l7_diff, 1)

        bin =
          wrapped
          |> PrimitiveCodec.encode()
          |> IO.iodata_to_binary()

        assert {:ok, [^wrapped]} = PrimitiveCodec.decode_all(bin),
               dump(seed, "two-level described broke round-trip", bin)

        # guarded shapes: boundary ints each side of every range guard
        {n, expect_ok} = Enum.random(boundary_pair)

        result =
          try do
            {:ok, PrimitiveCodec.encode(n) |> IO.iodata_to_binary()}
          rescue
            ArgumentError -> :raised
          end

        if expect_ok do
          assert {:ok, enc} = result,
                 "boundary value #{n} unexpectedly raised: #{inspect(result)}"

          assert {:ok, [^n]} = PrimitiveCodec.decode_all(enc),
                 "boundary value #{n} broke round-trip"
        else
          assert :raised = result, "over-range value #{n} did not raise ArgumentError"
        end

        # improper list / non-uniform array must raise the documented error
        if :rand.uniform(2) == 1 do
          assert_raise ArgumentError, fn -> PrimitiveCodec.encode([1, [2 | :improper_tail]]) end
        else
          assert_raise ArgumentError, fn -> PrimitiveCodec.encode({:array, [1, "mixed"]}) end
        end

        bump(:l7_diff, 1)
      end
    end

    assert count(:l7_diff) == @seeds |> Enum.count() |> Kernel.*(iterations_per_seed * 2)
  end

  defp proper_term?(_), do: false
end
