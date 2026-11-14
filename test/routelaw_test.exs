defmodule Smalt.RoutelawTest do
  use ExUnit.Case, async: true
  import Plug.Test
  alias Smalt.Routelaw

  @cases "test/fixtures/routelaw_vectors.json" |> File.read!() |> Jason.decode!() |> Map.fetch!("cases")

  for c <- @cases do
    @c c
    test "vector #{c["id"]}" do
      c = @c

      case c do
        %{"ok" => ok} ->
          expected = Map.new(ok, fn {k, v} -> {String.to_atom(k), v} end)
          assert {:ok, ^expected} = Routelaw.parse(c["path"])

        %{"refused" => r} ->
          assert {:refused, String.to_atom(r)} == Routelaw.parse(c["path"])
      end
    end

    test "guard #{c["id"]}" do
      c = @c
      conn = Smalt.Routelaw.Guard.call(conn(:get, c["path"]), [])

      case c do
        %{"ok" => _} ->
          refute conn.halted
          assert conn.assigns.route.role == c["ok"]["role"]

        %{"refused" => r} ->
          assert conn.halted
          assert conn.status in [400, 403]
          assert Jason.decode!(conn.resp_body) == %{"refused" => r}
          refute Map.has_key?(conn.assigns, :route)
      end
    end
  end

  test "twilio signature round trip, order-independent, tamper-evident" do
    tok = "0123456789abcdef0123456789abcdef"
    url = "https://fnox.io/client/po_01ARZ3NDEKTSV4RRFFQ69G5FAV/api"
    p = %{"To" => "+15005550006", "From" => "+15005550001", "Body" => "hi"}
    sig = Routelaw.twilio_signature(tok, url, p)
    assert Routelaw.twilio_valid?(tok, url, p, sig)
    assert Routelaw.twilio_valid?(tok, url, Enum.reverse(Map.to_list(p)), sig)
    refute Routelaw.twilio_valid?(tok, url, Map.put(p, "Body", "ho"), sig)
    refute Routelaw.twilio_valid?(tok, url <> "x", p, sig)
    refute Routelaw.twilio_valid?(tok, url, p, nil)
    manual = :crypto.mac(:hmac, :sha, tok, url <> "Body" <> "hi" <> "From+15005550001" <> "To+15005550006")
    assert sig == Base.encode64(manual)
  end
end
