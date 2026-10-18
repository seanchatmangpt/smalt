defmodule Smalt.Property.FrameCodecPropertyTest do
  # async: false — the shared Store and the global :primitive_codec
  # Application env (swapped by Smalt.Amqp.FrameCodecTest) make this suite's
  # codec surfaces tree-global; same posture as frame_codec_test.exs.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Smalt.Amqp.FrameCodec
  alias Smalt.Amqp.PrimitiveCodec
  alias Smalt.Hw.Frame
  alias Smalt.Store

  @moduledoc """
  Property-based tests (stream_data, with shrinking) — ERRC Raise lane 6.

  Generalizes the hand-rolled matrices in test/amqp/frame_codec_test.exs,
  test/amqp/fuzz_test.exs (seed-based, no shrinking) and the Hw.Frame witness
  vectors into generated properties. The example-based suites remain the
  pinned regressions; these properties are their generalization.

  Properties
  ----------
  P1  AMQP frame round-trip: encode_frame/3 then decode_frame/1 over generated
      performatives/fields/channels reconstructs the performative map.
  P2  Decode totality: arbitrary binaries decode to a tagged result
      ({:ok,_} | {:more,_} | {:error,_}), never raise — frame layer and
      primitive layer both.
  P3  Hw.Frame round-trip + split-invariance over arbitrary payloads and
      arbitrary chunk splits.
  P4  Hw decoder totality: arbitrary byte soup, any chunking, never raises;
      anything emitted from noise re-validates as a well-formed body.
  P5  Store exactly-one-winner: N racing compare_and_swap/4 (and insert_new/3)
      on generated keys yield exactly one winner; get/2 observes the winner.
  """

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  defp gen_text, do: string(:alphanumeric, max_length: 32)

  defp gen_sym, do: map(string(:alphanumeric, max_length: 16), fn s -> {:symbol, s} end)

  defp gen_u32, do: integer(0..4_294_967_295)

  # Curated per-performative field generators. Fields whose encode/decode is
  # NOT the identity (attach source/target/properties, transfer delivery_tag
  # uuid-wrap, disposition/transfer state described-tuples, error maps) are
  # deliberately excluded: this property pins identity round-trip, and those
  # fields have their own pinned example-based courts in frame_codec_test.exs.
  defp gen_performative_spec do
    specs = [
      {:amqp, :open,
       %{
         container_id: gen_text(),
         hostname: gen_text(),
         max_frame_size: gen_u32(),
         channel_max: integer(0..65_535),
         idle_time_out: gen_u32()
       }},
      {:amqp, :begin,
       %{
         next_outgoing_id: gen_u32(),
         incoming_window: gen_u32(),
         outgoing_window: gen_u32(),
         handle_max: gen_u32()
       }},
      {:amqp, :attach, %{name: gen_text(), handle: gen_u32()}},
      {:amqp, :flow,
       %{next_incoming_id: gen_u32(), incoming_window: gen_u32(), outgoing_window: gen_u32()}},
      {:amqp, :transfer, %{delivery_id: gen_u32(), settled: boolean(), more: boolean()}},
      {:amqp, :disposition, %{role: boolean(), settled: boolean()}},
      {:amqp, :detach, %{handle: gen_u32(), closed: boolean()}},
      {:amqp, :end, %{}},
      {:amqp, :close, %{}},
      {:sasl, :sasl_mechanisms, %{server_mechanisms: list_of(gen_sym(), max_length: 3)}},
      {:sasl, :sasl_init, %{mechanism: gen_sym(), hostname: gen_text()}},
      {:sasl, :sasl_response, %{}},
      {:sasl, :sasl_outcome, %{code: gen_u32()}}
    ]

    bind(constant(specs), fn specs ->
      # Uniform pick over the curated spec list.
      bind(integer(0..(length(specs) - 1)), fn i ->
        {type, perf, field_gens} = Enum.at(specs, i)
        fixed_map(field_gens) |> map(fn fields -> {type, perf, fields} end)
      end)
    end)
  end

  # ---------------------------------------------------------------------------
  # P1 — AMQP frame round-trip
  # ---------------------------------------------------------------------------

  property "P1: encode_frame -> decode_frame round-trips generated performatives" do
    check all(
            channel <- integer(0..65_535),
            {type, perf, fields} <- gen_performative_spec(),
            max_runs: 150
          ) do
      encoded = IO.iodata_to_binary(FrameCodec.encode_frame(type, channel, {perf, fields}))

      assert {:ok, decoded} = FrameCodec.decode_frame(encoded)
      assert decoded.type == type
      assert decoded.channel == channel
      assert decoded.performative.performative == perf

      Enum.each(fields, fn {k, v} ->
        assert Map.get(decoded.performative, k) == v,
               "field #{inspect(k)} mismatch: #{inspect(v)} != #{inspect(Map.get(decoded.performative, k))}"
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # P2 — decode totality (never raises, always tagged)
  # ---------------------------------------------------------------------------

  property "P2: decode_frame is total over arbitrary binaries" do
    check all(
            buf <- binary(max_length: 600),
            max_runs: 200
          ) do
      result = FrameCodec.decode_frame(buf)

      assert match?({:ok, _}, result) or match?({:more, _}, result) or
               match?({:error, _}, result),
             "untagged result for #{inspect(buf)}"
    end
  end

  property "P2b: PrimitiveCodec.decode is total over arbitrary binaries" do
    check all(
            buf <- binary(max_length: 400),
            max_runs: 200
          ) do
      result = PrimitiveCodec.decode(buf)

      assert match?({:ok, _, _}, result) or match?({:error, _}, result),
             "untagged result for #{inspect(buf)}"
    end
  end

  # ---------------------------------------------------------------------------
  # P3/P4 — Hw.Frame round-trip, split-invariance, totality
  # ---------------------------------------------------------------------------

  defp split_binary(bin, []), do: [bin]
  defp split_binary(<<>>, _cuts), do: []

  defp split_binary(bin, [c | rest]) do
    size = min(c, byte_size(bin))
    <<head::binary-size(size), tail::binary>> = bin
    [head | split_binary(tail, rest)]
  end

  property "P3: Hw.Frame round-trips arbitrary payloads across arbitrary chunk splits" do
    check all(
            payload <- binary(max_length: 2048),
            cuts <- list_of(integer(1..256), max_length: 8),
            max_runs: 150
          ) do
      frame = Frame.encode(payload)
      chunks = split_binary(frame, cuts)

      decoder = Enum.reduce(chunks, Frame.decoder(), &Frame.push(&2, &1))
      assert {frames, _} = Frame.take(decoder)
      assert frames == [payload]
    end
  end

  property "P3b: Hw decoder drops frames with corrupted CRC" do
    check all(
            payload <- binary(max_length: 2048),
            max_runs: 100
          ) do
      frame = Frame.encode(payload)
      # Replace the trailing CRC pair (just before the closing flag) with
      # 0x00 0x00. Stuffed streams never contain a bare 0x7E, so this cannot
      # introduce a spurious flag; the body parses identically and only the
      # CRC changes.
      corrupt = binary_part(frame, 0, byte_size(frame) - 3) <> <<0x00, 0x00, 0x7E>>

      decoder = Frame.push(Frame.decoder(), corrupt)
      assert {frames, _} = Frame.take(decoder)
      assert frames == [], "corrupted-CRC frame was delivered: #{inspect(frames)}"
    end
  end

  property "P4: Hw decoder is total over arbitrary byte soup, any chunking" do
    check all(
            soup <- binary(max_length: 2048),
            chunk <- integer(1..97),
            max_runs: 200
          ) do
      decoder =
        soup
        |> :binary.bin_to_list()
        |> Enum.chunk_every(chunk, chunk, [])
        |> Enum.map(&IO.iodata_to_binary/1)
        |> Enum.reduce(Frame.decoder(), &Frame.push(&2, &1))

      assert {frames, _} = Frame.take(decoder)

      Enum.each(frames, fn f ->
        # Anything emitted from noise must itself be a well-formed body.
        {reframes, _} = Frame.take(Frame.push(Frame.decoder(), Frame.encode(f)))
        assert reframes == [f]
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # P5 — Store exactly-one-winner under generated concurrency
  # ---------------------------------------------------------------------------

  @cas_table :smalt_resources

  defp unique_key, do: "property-test-" <> Integer.to_string(System.unique_integer([:positive]))

  property "P5: N racing CAS/insert_new on generated keys keep exactly one winner" do
    check all(
            n <- integer(2..12),
            keys <- list_of(binary(min_length: 1, max_length: 12), min_length: 1, max_length: 4),
            initial <- integer(0..1000),
            max_runs: 25
          ) do
      assert :ok = SmaltTest.Lifecycle.ensure_store_up()

      full_keys = Enum.map(keys, fn k -> unique_key() <> "-" <> k end)

      try do
        Enum.each(full_keys, fn key ->
          Store.put(@cas_table, key, initial)

          cas_outs =
            1..n
            |> Task.async_stream(
              fn i -> {i, Store.compare_and_swap(@cas_table, key, initial, "winner-#{i}")} end,
              max_concurrency: n,
              timeout: 5_000
            )
            |> Enum.map(fn {:ok, r} -> r end)

          winners = Enum.filter(cas_outs, fn {_i, r} -> r == :ok end)
          assert length(winners) == 1, "expected exactly 1 CAS winner, got #{inspect(cas_outs)}"
          assert Enum.count(cas_outs, fn {_i, r} -> match?({:error, :conflict}, r) end) == n - 1

          [{winner_i, :ok}] = winners
          expected = "winner-" <> Integer.to_string(winner_i)
          assert {:ok, ^expected} = Store.get(@cas_table, key)

          # insert_new: same exactly-one-winner law on a fresh key.
          fresh = unique_key()

          ins_outs =
            1..n
            |> Task.async_stream(fn _ -> Store.insert_new(@cas_table, fresh, "first") end,
              max_concurrency: n,
              timeout: 5_000
            )
            |> Enum.map(fn {:ok, r} -> r end)

          assert Enum.count(ins_outs, &(&1 == :ok)) == 1
          assert Enum.count(ins_outs, &match?({:error, :exists}, &1)) == n - 1

          # R185i test-isolation fix: the insert_new probe's winner row is a
          # non-map value ("first") in the SHARED :smalt_resources table. It
          # previously leaked past the after-block (which only deletes the CAS
          # full_keys) and tripped the semantic projection's whole-table
          # non-map fence (Ash.read! at test/semantic_projection_test.exs:482)
          # on every subsequent full-suite run. Delete it here, same scope.
          Store.delete(@cas_table, fresh)
        end)
      after
        Enum.each(full_keys, &Store.delete(@cas_table, &1))
      end
    end
  end
end
