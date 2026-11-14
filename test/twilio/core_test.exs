defmodule Smalt.Twilio.CoreTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn
  alias Smalt.Twilio.{Core, Router, Signature}

  @sid "AC" <> String.duplicate("a", 32)
  @token String.duplicate("b", 32)

  setup do
    {:ok, store} = Router.start_store()
    opts = [account_sid: @sid, auth_token: @token, base_url: "https://fnox.io", store: store]
    {:ok, store: store, opts: opts}
  end

  defp send_form(opts, path, params, headers \\ []) do
    conn(:post, path, URI.encode_query(params))
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> then(fn c -> Enum.reduce(headers, c, fn {k, v}, a -> put_req_header(a, k, v) end) end)
    |> Router.call(opts)
  end

  defp basic, do: [{"authorization", "Basic " <> Base.encode64("#{@sid}:#{@token}")}]

  test "signature equals independently computed HMAC-SHA1" do
    params = %{"To" => "+1555", "Body" => "hi"}
    expected = :crypto.mac(:hmac, :sha, @token, "https://x.test/hBodyhiTo+1555") |> Base.encode64()
    assert Signature.compute(@token, "https://x.test/h", params) == expected
    assert Signature.valid?(@token, "https://x.test/h", params, expected)
    refute Signature.valid?(@token, "https://x.test/h", params, "AAAA")
    refute Signature.valid?(@token, "https://x.test/h", params, nil)
  end

  test "typeid shape and parse refusals" do
    for _ <- 1..50 do
      id = Core.type_id("deal")
      assert {:ok, {"deal", ulid}} = Core.parse_typeid(id)
      assert byte_size(ulid) == 26 and String.first(ulid) in ~w(0 1 2 3 4 5 6 7)
    end

    assert {:error, _} = Core.parse_typeid("deal_8" <> String.duplicate("0", 25))
    assert {:error, _} = Core.parse_typeid("nounderscore")
  end

  test "route law: lead role allowed, cross-role refused 403", %{opts: opts} do
    ok = conn(:get, "/principal/#{Core.type_id("deal")}/app") |> Router.call(opts)
    assert ok.status == 200
    assert %{"fibo" => "MasterAgreement"} = Jason.decode!(ok.resp_body)

    bad = conn(:get, "/client/#{Core.type_id("deal")}/api") |> Router.call(opts)
    assert bad.status == 403
    assert %{"refused" => "cross_role_traversal"} = Jason.decode!(bad.resp_body)

    status = fn path -> conn(:get, path) |> Router.call(opts) |> Map.get(:status) end
    assert status.("/credit/#{Core.type_id("pool")}/app") == 200
    assert status.("/principal/#{Core.type_id("pool")}/app") == 403
    assert status.("/principal/#{Core.type_id("zzz")}/app") == 403
    assert status.("/principal/#{Core.type_id("deal")}/web") == 403
    assert status.("/nobody/#{Core.type_id("deal")}/app") == 403
  end

  test "REST numbers, messages, calls; OCEL events recorded", %{opts: opts, store: store} do
    base = "/2010-04-01/Accounts/#{@sid}"
    pn = send_form(opts, base <> "/IncomingPhoneNumbers.json", %{"PhoneNumber" => "+15005550006"}, basic())
    assert pn.status == 201 and String.starts_with?(Jason.decode!(pn.resp_body)["sid"], "PN")

    m = %{"To" => "+15551230000", "From" => "+15005550006", "Body" => "x"}
    sm = send_form(opts, base <> "/Messages.json", m, basic())
    assert sm.status == 201 and String.starts_with?(Jason.decode!(sm.resp_body)["sid"], "SM")

    c = %{"To" => "+15551230000", "From" => "+15005550006", "Url" => "https://fnox.io/v"}
    ca = send_form(opts, base <> "/Calls.json", c, basic())
    assert ca.status == 201 and String.starts_with?(Jason.decode!(ca.resp_body)["sid"], "CA")

    assert send_form(opts, base <> "/Messages.json", %{"Body" => "x"}, basic()).status == 400

    assert Enum.map(Router.events(store), & &1["ocel:type"]) ==
             ~w(number_provisioned message_created call_created)
  end

  test "auth: none refused; valid X-Twilio-Signature accepted", %{opts: opts} do
    path = "/2010-04-01/Accounts/#{@sid}/Messages.json"
    params = %{"To" => "+15551230000", "From" => "+15005550006", "Body" => "x"}
    assert send_form(opts, path, params).status == 401

    sig = Signature.compute(@token, "https://fnox.io" <> path, params)
    assert send_form(opts, path, params, [{"x-twilio-signature", sig}]).status == 201
    assert send_form(opts, path, params, [{"x-twilio-signature", "bad"}]).status == 401
  end
end
