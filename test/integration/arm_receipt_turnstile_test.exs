# DoD Gate 4 integration court — turnstile receipt headers on the ARM gateway.
#
# Chicago discipline: real in-process dispatch through Smalt.ArmGateway.Router,
# real BodyCache raw-body capture, real pure-Elixir BLAKE3 (Settlement.digest/3).
# Falsifier: if the plug is removed from the router pipeline, the header
# disappears and these tests fail — presence of the header IS the state flip.
defmodule Smalt.Internal.ArmReceiptTurnstileTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn, only: [get_resp_header: 2]

  alias Smalt.ArmGateway.Router

  @sub "sub-rcpt-lane9"
  @av "api-version=2021-04-01"

  test "authenticated ARM GET carries turnstile receipt + matching timestamp" do
    conn = dispatch(:get, "/subscriptions/#{@sub}/resourcegroups?#{@av}")

    assert conn.status == 200

    ts = get_resp_header(conn, "x-smalt-receipt-timestamp") |> List.first()
    receipt = get_resp_header(conn, "x-smalt-receipt-turnstile") |> List.first()

    assert ts =~ ~r/^\d+$/
    assert receipt =~ ~r/^[0-9a-f]{64}$/

    # Cross-language byte contract: BLAKE3("arm.request" || u64BE(ts) || body)
    expected =
      Smalt.Posh.Egress.Settlement.digest("arm.request", String.to_integer(ts), "")

    assert receipt == Base.encode16(expected, case: :lower)
  end

  test "pinned cross-language vector: op || u64BE(ts_ns) || raw body" do
    # Shared byte contract with posh/internal/receipt (Go verifier).
    assert Base.encode16(
             Smalt.Posh.Egress.Settlement.digest(
               "arm.request",
               1_730_000_000_000_000_000,
               ~s({"k":"v"})
             ),
             case: :lower
           ) == "0c39d201b2fc87a2171046f1e76f8afc5398263d888381ee9f24cae4cabdb834"
  end

  test "receipt binds the raw body on a POST" do
    body = %{"location" => "eastus-rcpt"}

    conn =
      :put
      |> conn(
        "/subscriptions/#{@sub}/resourcegroups/rg-rcpt?#{@av}",
        Jason.encode!(body)
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Router.call([])

    assert conn.status in [200, 201]

    ts = get_resp_header(conn, "x-smalt-receipt-timestamp") |> List.first()
    receipt = get_resp_header(conn, "x-smalt-receipt-turnstile") |> List.first()
    raw = Jason.encode!(body)

    assert receipt ==
             Base.encode16(
               Smalt.Posh.Egress.Settlement.digest(
                 "arm.request",
                 String.to_integer(ts),
                 raw
               ),
               case: :lower
             )
  end

  test "GET with no body hashes the empty binary — same convention the Go verifier uses" do
    conn = dispatch(:get, "/providers?#{@av}")

    assert conn.status == 200

    ts = String.to_integer(get_resp_header(conn, "x-smalt-receipt-timestamp") |> List.first())
    receipt = get_resp_header(conn, "x-smalt-receipt-turnstile") |> List.first()

    expected = Smalt.Posh.Egress.Settlement.digest("arm.request", ts, "")

    assert receipt == Base.encode16(expected, case: :lower)
  end

  defp dispatch(method, path) do
    Router.call(conn(method, path), [])
  end
end
