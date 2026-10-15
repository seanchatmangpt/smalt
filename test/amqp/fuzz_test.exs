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

  @doc "Random AMQP-representable term, bounded depth #{5}, deterministic on the seed."
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
  defp gen_array(depth) do
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
            flunk(dump(seed, "expected exactly one value, got: #{inspect(other, limit: 20)}", term))

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
          e -> flunk("FUZZ FAILURE PrimitiveCodec.decode #{label}: #{Exception.format(:error, e)}")
        end

        # PrimitiveCodec.decode_all/1
        try do
          assert_tuple(PrimitiveCodec.decode_all(bin))
        rescue
          e -> flunk("FUZZ FAILURE PrimitiveCodec.decode_all #{label}: #{Exception.format(:error, e)}")
        end

        # FrameCodec.decode_frame/1
        try do
          assert_tuple(FrameCodec.decode_frame(bin))
        rescue
          e -> flunk("FUZZ FAILURE FrameCodec.decode_frame #{label}: #{Exception.format(:error, e)}")
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
              {:ok, decoded} -> decoded
              {:error, reason} -> flunk(dump(seed, "decode_message error: #{inspect(reason)}", payload))
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
      Smalt.Amqp.PrimitiveCodec.encode({:described, 0x12, [
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
        <<(IO.iodata_length(body) + 8)::32, 2::8, 0x00::8, 0::16>>,
        body
      ])

    # Warm-up decode: first pass through the codec loads Logger/lazy runtime
    # state that mints a small fixed set of atoms unrelated to wire input.
    assert {:ok, _} = FrameCodec.decode_frame(encoded)

    atoms_before = :erlang.system_info(:atom_count)
    assert {:ok, frame} = FrameCodec.decode_frame(encoded)

    src = frame.performative.source
    assert is_map(src)
    # decode_source_target/1 defaults a :filter key (nil) into the decoded map
    assert map_size(src) == 5001
    assert src[:filter] == nil

    # Every unknown wire key must come back as a binary, never a minted atom.
    assert Enum.all?(Map.keys(src), &(&1 == :filter or is_binary(&1)))

    atoms_after = :erlang.system_info(:atom_count)
    delta = atoms_after - atoms_before
    assert delta <= 10, "atom table grew by #{delta} decoding 5000 unique wire keys"
  end
end
