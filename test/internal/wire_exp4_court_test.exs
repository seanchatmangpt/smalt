defmodule Smalt.Internal.WireExp4CourtTest do
  @moduledoc """
  EXPL-4 F2 court (lane WIRE-EXP4): sized-element truncation in
  `Smalt.Amqp10.FrameDecoder` must answer a typed error, never raise.

  Real binary-frame probes (Chicago): each leg builds a hostile frame body by
  hand and pushes it through the public `decode_frame/1` boundary. Falsifier:
  a truncated declared length returns `{:error, :truncated_frame}` — a bare
  MatchError here is a court failure. 0xC0/0xD0/0xC1/0xD1 declared sizes are
  binding: truncation and trailing bytes inside the declared slice are both
  refused.
  """

  use ExUnit.Case, async: true

  alias Smalt.Amqp10.FrameDecoder

  # 8-byte header + body; doff=2 (no extended headers), type 0 (amqp).
  defp frame(body) do
    size = 8 + byte_size(body)
    <<size::32, 2::8, 0::8, 0::16, body::binary>>
  end

  # Body: described performative (attach, 0x12); its first positional field
  # is decoded generically, so any constructor can ride in first position.
  defp hostile_body(element), do: <<0x00, 0x53, 0x12, element::binary>>

  @truncated_constructor_classes [
    # {label, element bytes} — declared length exceeds what follows
    {:bin8, <<0xA0, 200, "abc">>},
    {:str8, <<0xA1, 200, "abc">>},
    {:sym8, <<0xA3, 200, "abc">>},
    {:bin32, <<0xB0, 200::32, "abc">>},
    {:str32, <<0xB1, 200::32, "abc">>},
    {:sym32, <<0xB3, 200::32, "abc">>},
    # declared 16-byte uuid, only 5 bytes follow
    {:uuid, <<0x98, "short">>}
  ]

  test "truncated sized elements answer typed error, never raise" do
    for {label, element} <- @truncated_constructor_classes do
      result = FrameDecoder.decode_frame(frame(hostile_body(element)))

      assert {:error, :truncated_frame} = result,
             "constructor #{inspect(label)} answered #{inspect(result)}"
    end
  end

  test "EXPL-4 F2 witness: declared 200-byte string, 3 bytes follow" do
    # The exact witnessed shape from the finding — pre-repair this raised a
    # bare MatchError in the sized-element constructor.
    assert {:error, :truncated_frame} =
             FrameDecoder.decode_frame(frame(<<0x00, 0x53, 0x12, 0xA1, 200, "abc">>))
  end

  test "0xC0 declared size is binding: truncation refused" do
    # declared size 10, only <<3, 0x50, 1>> follows (3 bytes < 10)
    body = <<0x00, 0x53, 0x12, 0xC0, 10, 3, 0x50, 1>>
    assert {:error, :truncated_frame} = FrameDecoder.decode_frame(frame(body))

    # declared size 2 covers only the count: zero elements buffered
    body = <<0x00, 0x53, 0x12, 0xC0, 2, 1>>
    assert {:error, _} = FrameDecoder.decode_frame(frame(body))
  end

  test "0xC0 declared size is binding: trailing bytes inside the slice refused" do
    # size 4 = count 1 + ubyte 9 + one trailing byte inside the declared slice
    body = <<0x00, 0x53, 0x12, 0xC0, 4, 1, 0x50, 9, 0xFF>>
    assert {:error, :bad_element} = FrameDecoder.decode_frame(frame(body))
  end

  test "0xD0 declared size is binding: truncation and trailing bytes refused" do
    # declared size 20, only count + one short element follow
    body = <<0x00, 0x53, 0x12, 0xD0, 20::32, 1::32, 0x52, 7>>
    assert {:error, :truncated_frame} = FrameDecoder.decode_frame(frame(body))

    # size 7 = count(4) + ubyte(2) + one trailing byte inside the declared slice
    body = <<0x00, 0x53, 0x12, 0xD0, 7::32, 1::32, 0x50, 9, 0xFF>>
    assert {:error, :bad_element} = FrameDecoder.decode_frame(frame(body))
  end

  test "0xC1/0xD1 (map constructors) truncation refused" do
    body = <<0x00, 0x53, 0x12, 0xC1, 10, 1, 0xA3, 3>>
    assert {:error, :truncated_frame} = FrameDecoder.decode_frame(frame(body))

    body = <<0x00, 0x53, 0x12, 0xD1, 20::32, 1::32, 0xA3, 3>>
    assert {:error, :truncated_frame} = FrameDecoder.decode_frame(frame(body))
  end

  test "BK-SKEP F1: spec-invalid odd element count in maps answers typed error, never raises" do
    # 0xC1, size=2, count=1, single nil — odd count, slice exact.
    # Pre-repair this raised an untyped FunctionClauseError from pairs/1.
    body = <<0x00, 0x53, 0x12, 0xC1, 2, 1, 0x40>>
    assert {:error, :bad_element} = FrameDecoder.decode_frame(frame(body))

    # 0xD1, size=5, count=1, single nil — same odd-count raise path on the 32-bit form.
    body = <<0x00, 0x53, 0x12, 0xD1, 5::32, 1::32, 0x40>>
    assert {:error, :bad_element} = FrameDecoder.decode_frame(frame(body))

    # count=3, three nils — odd, exact slice, same clause miss.
    body = <<0x00, 0x53, 0x12, 0xC1, 4, 3, 0x40, 0x40, 0x40>>
    assert {:error, :bad_element} = FrameDecoder.decode_frame(frame(body))
  end

  test "BK-SKEP F2: structurally impossible declared sizes answer bad_element, not truncated_frame" do
    # 0xC0 size=0 — no room for the count byte; malformed size, not truncation.
    body = <<0x00, 0x53, 0x12, 0xC0, 0>>
    assert {:error, :bad_element} = FrameDecoder.decode_frame(frame(body))

    # 0xD0 size=2 (<4) — count needs 4 bytes; malformed size.
    body = <<0x00, 0x53, 0x12, 0xD0, 2::32, 0x40>>
    assert {:error, :bad_element} = FrameDecoder.decode_frame(frame(body))

    # 0xB0 declared 0xFFFFFFFF — above the frame-size bound; malformed size.
    body = <<0x00, 0x53, 0x12, 0xB0, 0xFFFFFFFF::32, "abc">>
    assert {:error, :bad_element} = FrameDecoder.decode_frame(frame(body))

    # 32-bit siblings of the same impossible-size class.
    body = <<0x00, 0x53, 0x12, 0xB1, 0xFFFFFFFF::32, "abc">>
    assert {:error, :bad_element} = FrameDecoder.decode_frame(frame(body))

    body = <<0x00, 0x53, 0x12, 0xB3, 0xFFFFFFFF::32, "abc">>
    assert {:error, :bad_element} = FrameDecoder.decode_frame(frame(body))

    body = <<0x00, 0x53, 0x12, 0xC1, 0>>
    assert {:error, :bad_element} = FrameDecoder.decode_frame(frame(body))

    body = <<0x00, 0x53, 0x12, 0xD1, 2::32, 0x40>>
    assert {:error, :bad_element} = FrameDecoder.decode_frame(frame(body))
  end

  test "BK-SKEP F2 non-vacuity: genuine short input still answers truncated_frame" do
    # The same constructors with a lawful declared size but missing payload
    # bytes keep the truncation label — the fix moved only the impossible-size
    # class, not the truncation class.
    body = <<0x00, 0x53, 0x12, 0xB0, 200::32, "abc">>
    assert {:error, :truncated_frame} = FrameDecoder.decode_frame(frame(body))

    body = <<0x00, 0x53, 0x12, 0xD0, 20::32, 1::32, 0x52, 7>>
    assert {:error, :truncated_frame} = FrameDecoder.decode_frame(frame(body))

    body = <<0x00, 0x53, 0x12, 0xC0, 10, 3, 0x50, 1>>
    assert {:error, :truncated_frame} = FrameDecoder.decode_frame(frame(body))
  end

  test "every proper prefix of a valid frame answers a tagged tuple" do
    # Well-formed attach frame: name "ch", handle 0, role sender(0)...
    elem = fn bin -> <<0x00, 0x53, 0x12, bin::binary>> end
    good = elem.(<<0xA1, 2, "ch", 0x50, 0, 0x43, 0x50, 0, 0x50, 0>>)

    for n <- 8..byte_size(good) do
      <<prefix::binary-size(^n), _::binary>> = good
      result = FrameDecoder.decode_frame(prefix)

      assert match?({:ok, _, _}, result) or match?({:more, _}, result) or
               match?({:error, _}, result),
             "prefix #{n} answered #{inspect(result)}"
    end

    # Sub-header fragments are buffering, not errors.
    assert {:more, _} = FrameDecoder.decode_frame(binary_part(good, 0, 4))
  end

  test "non-vacuity: the same bodies with the full payload decode to frames" do
    # Full 200-byte string decodes — the truncation legs fail on missing bytes,
    # not on the constructor being unrepresentable.
    long = String.duplicate("x", 200)
    body = <<0x00, 0x53, 0x12, 0xA1, 200, long::binary>>

    assert {:ok, %{performative: {:attach, %{name: ^long}}}, <<>>} =
             FrameDecoder.decode_frame(frame(body))

    # Well-formed 0xC0 list with exact declared slice decodes.
    body = <<0x00, 0x53, 0x12, 0xC0, 3, 1, 0x50, 9>>
    assert {:ok, %{performative: {:attach, _}}, <<>>} = FrameDecoder.decode_frame(frame(body))
  end
end
