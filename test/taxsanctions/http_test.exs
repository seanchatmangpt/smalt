defmodule Smalt.TaxSanctions.HttpTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Smalt.TaxSanctions.Http

  defp post_json(path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Http.call(Http.init([]))
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  test "tin-match returns code and meaning" do
    c =
      post_json("/tin-match", %{
        name: "Acme, LLC",
        tin: "12-3456789",
        registry: %{"123456789" => %{name: "Acme LLC", type: "ein"}}
      })

    assert c.status == 200
    assert %{"code" => 7, "meaning" => "matched_ein", "matched" => true} = json(c)
    assert post_json("/tin-match", %{tin: "1"}).status == 400
  end

  test "withholding in cents" do
    c = post_json("/withholding", %{amount_cents: 10_000, code: 3})
    assert %{"withheld_cents" => 2400, "payee_cents" => 7600} = json(c)
    assert post_json("/withholding", %{amount_cents: -1, code: 3}).status == 400
  end

  test "1099 nec ok and typed error" do
    a = %{payer_tin: "123456789", payee_tin: "987654321", payee_name: "J", tax_year: 2026,
          nonemployee_comp_cents: 70_000}

    assert %{"form" => "1099-NEC", "filing_required?" => true} = json(post_json("/1099/nec", a))
    c = post_json("/1099/nec", %{a | payee_tin: "1"})
    assert c.status == 422
    assert %{"error" => "bad_tin"} = json(c)
  end

  test "1099 k" do
    k = %{filer_tin: "123456789", payee_tin: "987654321", payee_name: "J", tax_year: 2026,
          monthly_gross_cents: List.duplicate(100, 12)}

    assert %{"box1a_gross_cents" => 1200} = json(post_json("/1099/k", k))
    assert post_json("/1099/k", %{k | monthly_gross_cents: [1]}).status == 422
  end

  test "w8ben-e valid and US refusal" do
    f = %{entity_name: "GmbH", country_of_incorporation: "DE", chapter3_status: "corporation",
          permanent_address: "x", signature: "s", signed_on: "2026-01-01", capacity: "dir"}

    assert %{"valid" => true, "expires_on" => "2029-12-31"} = json(post_json("/w8ben-e", f))
    c = post_json("/w8ben-e", %{f | country_of_incorporation: "US"})
    assert c.status == 422
    assert %{"error" => "invalid"} = json(c)
  end

  test "vies lookup uses configured registry" do
    Application.put_env(:smalt, :vies_registry, ["DE123456789"])
    on_exit(fn -> Application.delete_env(:smalt, :vies_registry) end)
    c = conn(:get, "/vies/DE/123456789") |> Http.call(Http.init([]))
    assert %{"valid" => true} = json(c)
    c2 = conn(:get, "/vies/DE/999999999") |> Http.call(Http.init([]))
    assert %{"valid" => false, "reason" => "not_registered"} = json(c2)
  end

  test "dac7 filters reportable sellers" do
    s = %{name: "S", tin: "t", residence: "DE", listings: 1, activities: 31,
          quarterly_consideration_cents: [1, 1, 1, 1]}

    c = post_json("/dac7", %{platform_id: "p", year: 2026, sellers: [s, %{s | activities: 1}]})
    assert %{"sellers" => [%{"total_consideration_cents" => 4}]} = json(c)
  end

  test "screen clear and potential match" do
    list = [%{id: "1", name: "Ivan Petrov", aliases: [], program: "SDN"}]
    assert %{"status" => "potential_match", "hits" => [_]} = json(post_json("/screen", %{name: "Petrov Ivan", list: list}))
    assert %{"status" => "clear"} = json(post_json("/screen", %{name: "Zed Q", list: list}))
    assert post_json("/screen", %{name: "x"}).status == 400
  end

  test "unknown route 404" do
    assert conn(:get, "/nope") |> Http.call(Http.init([])) |> Map.get(:status) == 404
  end
end
