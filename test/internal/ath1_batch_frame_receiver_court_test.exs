defmodule Smalt.Test.Internal.Ath1BatchFrameReceiverCourtTest do
  @moduledoc """
  ATH-1 court (v26.10.22): the domain-blind batch-frame receiver on the real
  wire gateway — real HTTP (curl subprocess) against the REAL
  `Smalt.EgressRouter` served by the self-booting app on the ephemeral test
  egress port, real `Smalt.Sync.Store` ETS, the nil-guard admit seam, and a
  configured REAL law function (never a mock) for the ANDON leg. Bounded
  polls via real transport attempts; no sleeps as coordination.

  Gates:
    a) valid 3-frame batch -> 3 admits + receipt round-trip (320-byte seal,
       sha256-chain root recomputed over the admitted frame wires)
    b) frame with bad CRC -> typed 400 BAD_CRC32 + serverHeadSeq, prior
       admits stand (committed head == 1)
    c) corrupt header -> batch-fatal 400 BAD_MAGIC + connection close,
       Store untouched
    d) ANDON (configured refuse law) -> 422 typed refusal, zero Store mutation
    e) seq regression -> typed 409 SEQ_REGRESSION (within-batch and
       cross-batch vs the committed head)

  Wire contract pinned to the landed ATH-2 codec
  (`workspace/lib/engine/codec.ts`): 41-byte header incl. 4-byte reserved
  pad, IEEE CRC-32 over payload, big-endian. Receipt contract pinned to
  `workspace/lib/engine/receipt.ts` (`mintReceiptToken`): 320-byte BE seal —
  magic 0x534D4C54 / version 1 / leafCount u64 / 32-byte sha256-chain root /
  zero reserved.
  """

  use ExUnit.Case, async: false

  alias Smalt.Sync.Frame
  alias Smalt.Sync.Receipt
  alias Smalt.Sync.Store

  @path "/sync/journal/batch"

  # -- pure codec legs -------------------------------------------------------

  describe "codec (pure legs)" do
    test "frame encode/decode round-trips and pins the 41-byte header" do
      payload = "opaque-bytes-1"

      wire = Frame.encode(%{client_id: 7, seq: 42, ts_ms: 1_765_000_000_000, op: 3, payload: payload})

      assert byte_size(wire) == 41 + byte_size(payload)
      assert {:ok, f, <<>>} = Frame.decode(wire)
      assert f.client_id == 7
      assert f.seq == 42
      assert f.ts_ms == 1_765_000_000_000
      assert f.op == 3
      assert f.crc32 == :erlang.crc32(payload)
      assert f.crc_ok
      assert f.wire == wire

      # reserved pad bytes are zero on the wire (offset 37..40)
      <<_::size(37 * 8), pad::24, _::binary>> = wire
      assert pad == 0
    end

    test "typed decode failures: SHORT_FRAME / BAD_MAGIC / BAD_LEN" do
      assert {:error, {:bad_frame, "SHORT_FRAME"}} = Frame.decode(<<1, 2, 3>>)

      bad_magic = <<0xDEAD_BEEF::32, 0::32, 1::64, 1::64, 0::64, 0::32, 0::8, 0::32, "x">>
      assert {:error, {:bad_frame, "BAD_MAGIC"}} = Frame.decode(bad_magic)

      good = Frame.encode(%{client_id: 1, seq: 1, ts_ms: 0, payload: "abc"})
      assert byte_size(good) == 44
      assert {:error, {:bad_frame, "BAD_LEN"}} = Frame.decode(binary_part(good, 0, 43))
    end

    test "crc vector: IEEE CRC-32 of \"123456789\" is 0xCBF43926" do
      frame = Frame.encode(%{client_id: 1, seq: 1, ts_ms: 0, payload: "123456789"})
      {:ok, f, _} = Frame.decode(frame)
      assert f.crc32 == 0xCBF43926
    end

    test "EXPL8-R residue: out-of-range :op is a typed refusal at the encode boundary" do
      base = %{client_id: 1, seq: 1, ts_ms: 0, payload: "x"}

      assert_raise ArgumentError,
                   ~r/:op must be an integer in 0\.\.255/,
                   fn -> Frame.encode(Map.put(base, :op, 256)) end

      assert_raise ArgumentError,
                   ~r/:op must be an integer in 0\.\.255/,
                   fn -> Frame.encode(Map.put(base, :op, -1)) end

      assert_raise ArgumentError,
                   ~r/:op must be an integer in 0\.\.255/,
                   fn -> Frame.encode(Map.put(base, :op, :read)) end

      # boundary values still encode; default (absent) op is 0
      assert byte_size(Frame.encode(Map.put(base, :op, 0))) == 42
      assert byte_size(Frame.encode(Map.put(base, :op, 255))) == 42
      assert byte_size(Frame.encode(base)) == 42
    end

    test "EXPL8-R residue: nonzero reserved pad is a typed BAD_RESERVED decode refusal" do
      good = Frame.encode(%{client_id: 1, seq: 1, ts_ms: 0, payload: "abc"})

      <<head::binary-size(37), _pad::binary-size(4), tail::binary>> = good
      bad_pad = <<head::binary, 0, 0, 0, 1, tail::binary>>
      assert {:error, {:bad_frame, "BAD_RESERVED"}} = Frame.decode(bad_pad)

      # all-zero pad still decodes (the wire contract: reserved is zero pad)
      assert {:ok, f, <<>>} = Frame.decode(good)
      assert f.payload == "abc"
      assert f.crc_ok
    end
  end

  describe "receipt seal (pure legs)" do
    test "mint mirrors the client layout: magic/version/leafCount/root/reserved" do
      w1 = frame_wire(1, 1)
      w2 = frame_wire(1, 2)

      chain = Receipt.absorb(Receipt.absorb(Receipt.empty_chain(), w1), w2)
      token = Receipt.mint(chain)
      raw = Base.decode16!(token, case: :lower)

      assert byte_size(raw) == 320
      assert String.length(token) == 640
      <<0x534D_4C54::32, 1::32, 2::64, root::binary-size(32), reserved::binary-size(272)>> = raw
      assert reserved == :binary.copy(<<0>>, 272)

      # root == the sha256-chain recomputed here (the client Accumulator law)
      leaf1 = :crypto.hash(:sha256, w1)
      leaf2 = :crypto.hash(:sha256, w2)
      expected = :crypto.hash(:sha256, :crypto.hash(:sha256, leaf1) <> leaf2)
      assert root == expected

      # empty chain: leafCount 0, zero root, still a valid 320-byte seal
      empty = Base.decode16!(Receipt.mint(Receipt.empty_chain()), case: :lower)
      <<0x534D_4C54::32, 1::32, 0::64, zero_root::binary-size(32), _::binary>> = empty
      assert zero_root == <<0::256>>
    end

    test "chain is order-sensitive" do
      w1 = frame_wire(1, 1)
      w2 = frame_wire(1, 2)

      a = Receipt.absorb(Receipt.absorb(Receipt.empty_chain(), w1), w2)
      b = Receipt.absorb(Receipt.absorb(Receipt.empty_chain(), w2), w1)
      assert Receipt.mint(a) != Receipt.mint(b)
    end
  end

  # -- wire court ------------------------------------------------------------

  describe "wire court (real HTTP over the real router)" do
    test "gate a: valid 3-frame batch admits with receipt round-trip" do
      cid = 0xAA00_0000_0000_0001

      wires =
        Enum.map(1..3, fn seq ->
          Frame.encode(%{client_id: cid, seq: seq, ts_ms: ts(), payload: "a-gate-payload"})
        end)

      assert {:ok, 200, %{"frames" => frames, "lastSeq" => 3, "receiptToken" => token}} =
               post(@path, Enum.join(wires))

      assert length(frames) == 3
      assert Enum.all?(frames, &(&1["verdict"] == "admit"))
      assert_receipt(token, wires)
      assert {:ok, 3, _} = Store.baseline(cid)
    end

    test "gate b: bad CRC -> typed refusal, prior admits stand" do
      cid = 0xAA00_0000_0000_0002

      f1 = Frame.encode(%{client_id: cid, seq: 1, ts_ms: ts(), payload: "intact"})
      f2 = Frame.corrupt_payload(one(cid, 2, "crc-victim"))

      assert {:ok, 400, %{"refusal" => "BAD_CRC32", "serverHeadSeq" => 1}} = post(@path, f1 <> f2)
      assert {:ok, 1, _} = Store.baseline(cid)
    end

    test "gate c: corrupt header -> 400 refusal frame + connection close, Store untouched" do
      cid = 0xAA00_0000_0000_0003
      before = Store.row_count()

      body = <<0xDEAD_BEEF::32, 0::32, cid::64, 9::64, 0::64, 0::32, 0::8, 0::32>>

      assert {:ok, 400, %{"refusal" => "BAD_MAGIC", "serverHeadSeq" => 0}} = post(@path, body)
      assert Store.row_count() == before
      assert {:ok, 0, _} = Store.baseline(cid)
    end

    test "gate d: ANDON -> typed 422 refusal, zero store mutation" do
      cid = 0xAA00_0000_0000_0004
      before = Store.row_count()

      law = fn _payload ->
        reason = "andon-court"
        {:andon, <<1::8, byte_size(reason)::16, reason::binary>>}
      end

      Application.put_env(:smalt, :sync_guard, {:fun, law})

      try do
        body = batch(cid, [1, 2], "d-gate-payload")

        assert {:ok, 422, %{"refusal" => "andon-court", "serverHeadSeq" => 0}} =
                 post(@path, body)

        assert Store.row_count() == before
        assert {:ok, 0, _} = Store.baseline(cid)
      after
        Application.delete_env(:smalt, :sync_guard)
      end
    end

    test "gate e: seq regression -> typed 409, within and across batches" do
      cid = 0xAA00_0000_0000_0005

      f1 = Frame.encode(%{client_id: cid, seq: 4, ts_ms: ts(), payload: "e1"})
      f2 = Frame.encode(%{client_id: cid, seq: 4, ts_ms: ts(), payload: "e1-dup"})

      assert {:ok, 409, %{"refusal" => "SEQ_REGRESSION", "serverHeadSeq" => 4}} =
               post(@path, f1 <> f2)

      f3 = Frame.encode(%{client_id: cid, seq: 2, ts_ms: ts(), payload: "e-old"})

      assert {:ok, 409, %{"refusal" => "SEQ_REGRESSION", "serverHeadSeq" => 4}} =
               post(@path, f3)

      assert {:ok, 4, _} = Store.baseline(cid)
    end

    test "persistence leg: second batch continues chain and head" do
      cid = 0xAA00_0000_0000_0006

      w1 = Frame.encode(%{client_id: cid, seq: 1, ts_ms: ts(), payload: "chain-1"})
      w2 = Frame.encode(%{client_id: cid, seq: 2, ts_ms: ts(), payload: "chain-2"})

      assert {:ok, 200, %{"lastSeq" => 1, "receiptToken" => t1}} = post(@path, w1)
      assert_receipt(t1, [w1])

      assert {:ok, 200, %{"lastSeq" => 2, "receiptToken" => t2}} = post(@path, w2)
      assert t1 != t2
      assert_receipt(t2, [w1, w2])
    end
  end

  # -- fixtures --------------------------------------------------------------

  defp frame_wire(cid, seq), do: Frame.encode(%{client_id: cid, seq: seq, ts_ms: 0, payload: "p"})

  defp one(cid, seq, payload) do
    Frame.encode(%{client_id: cid, seq: seq, ts_ms: ts(), payload: payload})
  end

  defp batch(cid, seqs, payload) do
    Enum.map_join(seqs, fn seq ->
      Frame.encode(%{client_id: cid, seq: seq, ts_ms: ts(), payload: payload})
    end)
  end

  defp ts, do: System.system_time(:millisecond)

  defp base, do: "http://127.0.0.1:#{Application.fetch_env!(:smalt, :egress_port)}"

  defp post(path, body) do
    tmp = Path.join(System.tmp_dir!(), "ath1-#{System.unique_integer()}.bin")
    File.write!(tmp, body)

    args = [
      "-s",
      "-S",
      "-w",
      "\n%{http_code}",
      "-X",
      "POST",
      "-H",
      "Content-Type: application/octet-stream",
      "--max-time",
      "10",
      "--data-binary",
      "@" <> tmp,
      base() <> path
    ]

    {out, rc} = System.cmd("curl", args)
    File.rm(tmp)

    case {rc, String.split(out, "\n", parts: 2)} do
      {0, [code]} ->
        # empty body: the -w trailer alone
        {:ok, String.to_integer(String.trim(code)), %{}}

      {0, [json, code]} ->
        # curl prints the response body first, then the -w trailer
        {:ok, String.to_integer(String.trim(code)), Jason.decode!(json)}

      _ ->
        {:transport_error, out}
    end
  end

  # Asserts the receipt token is the exact client-layout seal over `wires`:
  # sha256-chain root recomputed independently (the client Accumulator law).
  defp assert_receipt(token, wires) do
    raw = Base.decode16!(token, case: :lower)
    assert byte_size(raw) == 320

    <<0x534D_4C54::32, 1::32, count::64, root::binary-size(32), reserved::binary-size(272)>> =
      raw

    assert count == length(wires)
    assert reserved == :binary.copy(<<0>>, 272)

    expected =
      Enum.reduce(wires, nil, fn w, acc ->
        leaf = :crypto.hash(:sha256, w)

        case acc do
          nil -> :crypto.hash(:sha256, leaf)
          prev -> :crypto.hash(:sha256, prev <> leaf)
        end
      end)

    assert root == expected
  end
end
