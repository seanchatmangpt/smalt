defmodule Smalt.Planes.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test

  @opts Smalt.Planes.Router.init([])

  defp req(method, path), do: Smalt.Planes.Router.call(conn(method, path), @opts)

  test "unknown path is 404" do
    assert req(:get, "/nope").status == 404
  end

  test "erp qbo query is mounted" do
    c = req(:get, "/erp/qbo/v3/company/1/query")
    assert c.status == 200
    assert %{"QueryResponse" => _} = Jason.decode!(c.resp_body)
  end

  test "treasury prefix reaches the treasury router" do
    c = req(:get, "/treasury/does-not-exist")
    assert c.status in [400, 404, 405]
  end

  test "twilio prefix reaches the twilio router" do
    c = req(:get, "/twilio/does-not-exist")
    assert is_integer(c.status)
    refute c.status == 501
  end

  test "tax and rates are 501 or served by the http module" do
    for {p, mod} <- [{"/tax/ping", Smalt.TaxSanctions.Http}, {"/rates/ping", Smalt.Rates.Http}] do
      c = req(:get, p)

      if Code.ensure_loaded?(mod),
        do: assert(is_integer(c.status)),
        else: assert(c.status == 501)
    end
  end
end
