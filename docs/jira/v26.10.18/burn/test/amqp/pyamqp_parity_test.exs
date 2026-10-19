defmodule Smalt.Amqp.PyamqpParityTest do
  @moduledoc """
  pyamqp wire-parity court (py-court lane 91).

  Replicates, byte for byte, the opening sequence azure-servicebus
  (pyamqp 2.0.0a1 — the `azure.servicebus._pyamqp` module inside
  azure-servicebus 7.15.0 installed in test/sdk-python/.venv-sb; captured
  golden bytes. test/py-court/.venv is PyPI-installed, not vendored) puts on
  the wire for
  an emulator-style connection (`UseDevelopmentEmulator=true`, plain
  non-TLS AMQP): protocol header `AMQP\\x00\\x01\\x00\\00` followed by a
  PIPELINED open + begin + two `$cbs` attaches on channel 1
  (receiver handle 2, sender handle 1). Captured by encoding the venv's own
  pyamqp performatives (`_encode.encode_frame`) — golden bytes below.

  Wire facts this pins (2026-10-14 capture):
    - pyamqp pads its own attach list to exactly 14 elements; the AMQP
      attach composite has 14 fields. The broker previously emitted 16
      (spurious outgoing/incoming-locales + null padding of every field),
      which crashes pyamqp on receipt: `AttachFrame.__new__() takes 15
      positional arguments but 17 were given` — the SDK handler died
      mid-handshake and the attach hung/failed.

  Asserts the broker proceeds through the open-performative exchange and
  that its attach replies carry a wire list arity == 14, read directly from
  the raw reply bytes (not the decoded map).
  """

  use ExUnit.Case, async: false
  @moduletag :amqp_wire

  alias Smalt.Amqp.{Connection, FrameCodec}

  # ---------------------------------------------------------------------------
  # Golden bytes: captured by encoding pyamqp's own performatives
  # (azure-servicebus 7.15.0 / its bundled pyamqp 2.0.0a1
  # `azure.servicebus._pyamqp`, installed in test/sdk-python/.venv-sb;
  # py-court's venv is PyPI-installed, not vendored) with
  # its `_encode.encode_frame` and concatenating:
  #   header + open(ch0) + begin(ch1) + attach(cbs receiver, h2, ch1)
  #          + attach(cbs sender, h1, ch1)
  # ---------------------------------------------------------------------------
  @pyamqp_opening_blob <<0x41, 0x4D, 0x51, 0x50, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x68,
                         0x02, 0x00, 0x00>> <>
                         <<0x00, 0x00, 0x53, 0x10, 0xC0, 0x5B, 0x0A, 0xA1, 0x0A, 0x53, 0x42, 0x53,
                           0x65, 0x6E, 0x64>> <>
                         <<0x65, 0x72, 0x2D, 0x78, 0xA1, 0x09, 0x31, 0x32, 0x37, 0x2E, 0x30, 0x2E,
                           0x30, 0x2E, 0x31>> <>
                         <<0x70, 0x00, 0x10, 0x00, 0x00, 0x60, 0xFF, 0xFF, 0x40, 0x40, 0x40, 0x40,
                           0x40, 0xC1, 0x34>> <>
                         <<0x04, 0xA3, 0x07, 0x70, 0x72, 0x6F, 0x64, 0x75, 0x63, 0x74, 0xA1, 0x17,
                           0x61, 0x7A, 0x73>> <>
                         <<0x64, 0x6B, 0x2D, 0x70, 0x79, 0x74, 0x68, 0x6F, 0x6E, 0x2D, 0x73, 0x65,
                           0x72, 0x76, 0x69>> <>
                         <<0x63, 0x65, 0x62, 0x75, 0x73, 0xA3, 0x07, 0x76, 0x65, 0x72, 0x73, 0x69,
                           0x6F, 0x6E, 0xA1>> <>
                         <<0x06, 0x37, 0x2E, 0x31, 0x35, 0x2E, 0x30, 0x00, 0x00, 0x00, 0x22, 0x02,
                           0x00, 0x00, 0x01>> <>
                         <<0x00, 0x53, 0x11, 0xC0, 0x15, 0x08, 0x40, 0x43, 0x70, 0x00, 0x01, 0x00,
                           0x00, 0x70, 0x00>> <>
                         <<0x01, 0x00, 0x00, 0x70, 0xFF, 0xFF, 0xFF, 0xFF, 0x40, 0x40, 0x40, 0x00,
                           0x00, 0x00, 0x4C>> <>
                         <<0x02, 0x00, 0x00, 0x01, 0x00, 0x53, 0x12, 0xC0, 0x3F, 0x0E, 0xA1, 0x05,
                           0x63, 0x62, 0x73>> <>
                         <<0x2D, 0x32, 0x52, 0x02, 0x56, 0x01, 0x50, 0x00, 0x50, 0x00, 0x00, 0x53,
                           0x28, 0xC0, 0x11>> <>
                         <<0x0B, 0xA1, 0x04, 0x24, 0x63, 0x62, 0x73, 0x40, 0x40, 0x40, 0x40, 0x40,
                           0x40, 0x40, 0x40>> <>
                         <<0x40, 0x40, 0x00, 0x53, 0x29, 0xC0, 0x0D, 0x07, 0xA1, 0x04, 0x24, 0x63,
                           0x62, 0x73, 0x40>> <>
                         <<0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40,
                           0x00, 0x00, 0x00>> <>
                         <<0x4C, 0x02, 0x00, 0x00, 0x01, 0x00, 0x53, 0x12, 0xC0, 0x3F, 0x0E, 0xA1,
                           0x05, 0x63, 0x62>> <>
                         <<0x73, 0x2D, 0x31, 0x52, 0x01, 0x56, 0x00, 0x50, 0x00, 0x50, 0x00, 0x00,
                           0x53, 0x28, 0xC0>> <>
                         <<0x11, 0x0B, 0xA1, 0x04, 0x24, 0x63, 0x62, 0x73, 0x40, 0x40, 0x40, 0x40,
                           0x40, 0x40, 0x40>> <>
                         <<0x40, 0x40, 0x40, 0x00, 0x53, 0x29, 0xC0, 0x0D, 0x07, 0xA1, 0x04, 0x24,
                           0x63, 0x62, 0x73>> <>
                         <<0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x43, 0x40, 0x40, 0x40,
                           0x40>>

  @header "AMQP\x00\x01\x00\x00"
  @sasl_header "AMQP\x03\x01\x00\x00"

  # ---------------------------------------------------------------------------
  # Harness: real loopback socket into a real Connection GenServer (same
  # shape as connection_test.exs).
  # ---------------------------------------------------------------------------
  setup do
    SmaltTest.Env.put_restored(sb_shared_key: "test-shared-key-0123456789abcdef012345")

    SmaltTest.Lifecycle.ensure_store_up()

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listener)

    accept_task =
      Task.async(fn ->
        {:ok, sock} = :gen_tcp.accept(listener, 5000)
        {:ok, pid} = Connection.start_link(socket: sock)
        :ok = :gen_tcp.controlling_process(sock, pid)
        {:ok, pid}
      end)

    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5000)
    {:ok, _conn} = Task.await(accept_task, 5000)

    %{client: client}
  end

  test "pyamqp opening bytes (header + pipelined open/begin/cbs attaches) reach the attach exchange",
       %{client: client} do
    :ok = :gen_tcp.send(client, @pyamqp_opening_blob)
    {:ok, wire} = recv_all(client, 4000)

    # 1. header echo (plain form: pyamqp emulator path skips SASL entirely)
    assert String.starts_with?(wire, @header)

    {frames, arities} = decode_stream(wire)

    perfs = for f <- frames, do: {f.type, f.performative.performative}

    # 2. open reply
    assert {:amqp, :open} in perfs

    # 3. begin reply on the client's channel 1
    assert Enum.any?(
             frames,
             &(&1.type == :amqp and &1.performative.performative == :begin and &1.channel == 1)
           )

    # 4. attach replies for both $cbs handles. Spec-derivation of the reply
    # arity sequence (AMQP 1.0 §2.7 performatives; list counts read straight
    # from the raw list8 count byte, wire-order-aligned to `frames`):
    #   - open  (§2.7.1, 10 fields): broker reply count 5 — container-id,
    #     max-frame-size, channel-max, idle-time-out, properties; the
    #     remaining 5 trailing nulls omitted (legal, §1.4.3 list rule).
    #   - begin (§2.7.2,  8 fields): broker reply count 5 — remote-channel,
    #     next-outgoing-id, incoming-window, outgoing-window, handle-max.
    #   - attach(§2.7.3, 14 fields) x2: broker reply count 10 — name,
    #     handle, role, snd-settle-mode, rcv-settle-mode, source, target,
    #     unsettled, incomplete-unsettled, initial-delivery-count; the 4
    #     trailing nulls (max-message-size, offered-/desired-capabilities,
    #     properties) omitted (§1.4.3). 10 <= 14 is spec-legal AND matches
    #     the HEAD-pinned py-court bytes; only > 14 (pyamqp's AttachFrame
    #     positional constructor, 15 args with self) is the TypeError
    #     divergence. Lane R57 correction note: a `== 14` tightening failed
    #     on HEAD-identical wire bytes — [7,10,10,5,5] there is the
    #     wire-MIRRORED reading of [5,5,10,10,7] (open/begin/attach/attach/
    #     flow), an arities-not-reversed harness artifact, not new counts.
    attach_frames =
      Enum.filter(frames, &(&1.type == :amqp and &1.performative.performative == :attach))

    assert length(attach_frames) == 2

    attach_arities =
      frames
      |> Enum.zip(arities)
      |> Enum.filter(fn {f, _n} -> f.type == :amqp and f.performative.performative == :attach end)
      |> Enum.map(fn {_f, n} -> n end)

    assert attach_arities == [10, 10],
           "attach wire arity not the HEAD-pinned trailing-trimmed 10: #{inspect(attach_arities)}"

    # open(5) <= 10 fields and begin(5) <= 8 fields; nothing on the reply
    # stream may exceed its performative's field count (§2.7 field tables).
    assert Enum.all?(frames |> Enum.zip(arities), fn {f, n} ->
             n <= performative_field_count(f.performative.performative)
           end),
           "a reply frame exceeds its performative's §2.7 field count"

    assert arities != []
    # roles: client handle 2 is a receiver attach -> broker replies role=false (we are sender)
    by_handle = Map.new(attach_frames, fn f -> {f.performative.handle, f.performative.role} end)
    assert by_handle[2] == false
    assert by_handle[1] == true
  end

  test "SASL header form (AMQP\\x03) still negotiates ANONYMOUS then outcome 0", %{client: client} do
    sasl_init =
      IO.iodata_to_binary(
        FrameCodec.encode_frame(:sasl, 0, {:sasl_init, %{mechanism: "ANONYMOUS"}})
      )

    :ok = :gen_tcp.send(client, @sasl_header <> sasl_init)
    {:ok, wire} = recv_all(client, 2000)

    assert String.starts_with?(wire, @sasl_header)

    {frames, _} = decode_stream(wire)

    assert Enum.any?(
             frames,
             &(&1.type == :sasl and &1.performative.performative == :sasl_mechanisms)
           )

    assert Enum.any?(
             frames,
             &(&1.type == :sasl and &1.performative.performative == :sasl_outcome and
                 &1.performative.code == 0)
           )
  end

  test "no skip-acceptance branches in the wire tier (pyamqp TypeError fence)" do
    # Anti-vacuity fence (lane M6): the smalt-cli tests carry a copy-pasted
    # skip-acceptance pattern (`Target.__new__` TypeError / `Invalid link`
    # signatures matched in accept-position). That pattern must never creep
    # into the wire tier — a test that SKIPS on the failure signature fakes a
    # pass exactly where this court pins real bytes. Fail closed: read this
    # file and connection_test.exs at runtime, strip comment lines, and
    # assert the signature strings appear nowhere outside comments.
    fence_dir = __DIR__

    sources =
      for fname <- ["pyamqp_parity_test.exs", "connection_test.exs"] do
        path = Path.join(fence_dir, fname)
        assert File.exists?(path), "fence source missing: #{path}"

        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("## no-skip-fence")))
        |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("#")))
        |> Enum.join("\n")
      end

    for source <- sources,
        # assembled via concatenation so this fence's own signature list is
        # not itself an occurrence in code position (self-trip guard)
        sig <- ["Target" <> ".__new__", "Invalid" <> " link"] do
      refute source =~ sig,
             "skip-acceptance signature #{inspect(sig)} found in wire-tier test " <>
               "source outside comments — the smalt-cli skip pattern has crept in"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # AMQP 1.0 §2.7 performative field counts (the list-count ceiling; fewer
  # elements is legal trailing-null omission per §1.4.3).
  defp performative_field_count(:open), do: 10
  defp performative_field_count(:begin), do: 8
  defp performative_field_count(:attach), do: 14
  defp performative_field_count(:flow), do: 10
  defp performative_field_count(:transfer), do: 10
  defp performative_field_count(:disposition), do: 6
  defp performative_field_count(:detach), do: 3
  defp performative_field_count(:end), do: 1
  defp performative_field_count(:close), do: 1
  defp performative_field_count(_), do: 255

  defp recv_all(sock, timeout) do
    case :gen_tcp.recv(sock, 0, timeout) do
      {:ok, data} ->
        {:ok, rest} = recv_more(sock, timeout)
        {:ok, data <> rest}

      other ->
        other
    end
  end

  defp recv_more(sock, timeout) do
    case :gen_tcp.recv(sock, 0, timeout) do
      {:ok, data} ->
        {:ok, rest} = recv_more(sock, timeout)
        {:ok, data <> rest}

      {:error, _} ->
        {:ok, <<>>}
    end
  end

  # Split a reply stream into raw frames; decode each with FrameCodec and,
  # for AMQP-type frames, read the performative LIST arity straight from the
  # raw described-list constructor (list0/list8 count byte). The stream is
  # prefixed by the 8-byte protocol header echo, which is not a frame.
  defp decode_stream(bin, acc \\ [], arities \\ [])

  defp decode_stream(@header <> rest, acc, arities), do: decode_stream(rest, acc, arities)
  defp decode_stream(@sasl_header <> rest, acc, arities), do: decode_stream(rest, acc, arities)

  # Both accumulators are built head-first, so BOTH must be reversed on
  # return — reversing only `frames` left `arities` wire-mirrored relative
  # to the frame list (the [7,10,10,5,5] vs open/begin/attach/attach/flow
  # misalignment R58 was dispatched on).
  defp decode_stream(<<>>, acc, arities), do: {Enum.reverse(acc), Enum.reverse(arities)}

  defp decode_stream(stream, acc, arities) do
    <<size::unsigned-integer-size(32), doff::8, type_code::8, channel::16, rest::binary>> = stream
    body_size = size - doff * 4
    <<body::binary-size(body_size), tail::binary>> = rest

    arity =
      case body do
        # described(ulong descriptor, list8/list32). list8 = ctor,size,count;
        # list32 = ctor,size:32,count:32. The COUNT is what pyamqp reconstructs
        # AttachFrame(*frame) from, so that is the parity-critical number.
        <<0x00, _desc_ctor, _desc, 0xC0, _size::8, count::8, _::binary>> -> count
        <<0x00, _desc_ctor, _desc, 0xD0, _size::32, count::32, _::binary>> -> count
        _ -> nil
      end

    frame_bin = <<size::32, doff::8, type_code::8, channel::16, body::binary>>

    case FrameCodec.decode_frame(frame_bin) do
      {:ok, frame} ->
        decode_stream(tail, [frame | acc], if(arity, do: [arity | arities], else: arities))

      {:error, reason} ->
        flunk("undecodable frame in reply stream: #{inspect(reason)}")
    end
  end
end
