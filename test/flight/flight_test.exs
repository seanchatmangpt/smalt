defmodule Smalt.FlightTest do
  use ExUnit.Case, async: true
  alias Smalt.Flight
  alias Smalt.Flight.{Arrow, Row}

  defp row(id, over \\ %{}) do
    Map.merge(
      %{settlement_id: id, gross_cents: 1000, sub_cents: 600, orig_cents: 200,
        fee_cents: 50, net_cents: 150, gate_mask: 0xFF},
      over
    )
  end

  test "row is 128 bytes and round-trips" do
    {:ok, bin} = Row.encode(row(7))
    assert byte_size(bin) == 128
    assert Row.decode(bin) == row(7)
  end

  test "invariant violation refused before encoding" do
    bad = row(1, %{net_cents: 151})
    assert {:error, {:invariant_violation, :gross_ne_sum, 1000, 1001}} = Row.encode(bad)
    assert {:error, {1, {:invariant_violation, _, _, _}}} = Arrow.encode_stream([row(2), bad])
  end

  test "stream framing: schema, batch, eos, 8-aligned" do
    {:ok, s} = Arrow.encode_stream([row(1), row(2), row(3)])
    assert byte_size(s) |> rem(8) == 0
    assert binary_part(s, byte_size(s) - 8, 8) == <<0xFFFFFFFF::32-little, 0::32>>

    <<0xFFFFFFFF::32-little, l1::32-little, rest::binary>> = s
    assert rem(l1, 8) == 0
    <<fb1::binary-size(l1), rest::binary>> = rest
    assert header_type(fb1) == 1

    <<0xFFFFFFFF::32-little, l2::32-little, rest::binary>> = rest
    <<fb2::binary-size(l2), body::binary>> = rest
    assert header_type(fb2) == 3
    # 8 columns: 7*24 bytes + pad 3*72=216 -> 216 (already 8-aligned)
    assert byte_size(body) - 8 == 7 * 24 + 216
  end

  test "flight info JSON and do_get via ticket" do
    rows = [row(1), row(2)]
    {:ok, json} = Flight.get_flight_info(rows)
    info = JSON.decode!(json)
    assert info["total_records"] == 2
    assert info["row_bytes"] == 128
    [%{"ticket" => t}] = info["endpoint"]
    {:ok, stream} = Flight.do_get(t, rows)
    assert stream == elem(Arrow.encode_stream(rows), 1)
    assert {:error, :bad_ticket} = Flight.do_get("!!", rows)
  end

  # Minimal flatbuffer reader: Message.header_type (slot 1).
  defp header_type(fb) do
    <<root::32-little, _::binary>> = fb
    <<_::binary-size(root), soff::32-signed-little, _::binary>> = fb
    vt = root - soff
    <<_::binary-size(vt), _vsz::16-little, _osz::16-little, _s0::16-little, s1::16-little, _::binary>> = fb
    <<_::binary-size(root + s1), t::8, _::binary>> = fb
    t
  end
end
