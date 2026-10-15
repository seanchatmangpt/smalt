defmodule SmaltRouteNegativeTest do
  @moduledoc """
  Negative-path route tests for `Smalt.ArmGateway.Router` (Plug.Test, in-process).

  Pinned ARM behaviors:
    * unknown path -> 404 with a MAP-shaped `error` object
    * missing api-version on a provider PUT -> 400 `MissingApiVersionParameter`
    * bad api-version on an admitted type -> 400 `InvalidApiVersionParameter`
    * PUT of an unadmitted type -> 400 GraphLaw refusal envelope
      (code `InvalidResourceShape`, target `AshGraphLaw.Enforcement`)
  """

  use ExUnit.Case, async: false
  use Plug.Test

  alias Smalt.ArmGateway.Router
  alias Smalt.Store

  @opts Router.init([])

  setup do
    ensure_store()
    Store.clear()
    :ok
  end

  test "unknown path -> 404 with a map-shaped error envelope" do
    conn =
      conn(:get, "/definitely/not/a/route")
      |> Router.call(@opts)

    assert conn.status == 404

    body = Jason.decode!(conn.resp_body)
    assert is_map(body["error"])
    assert is_binary(body["error"]["code"])
    assert is_binary(body["error"]["message"])
  end

  test "provider PUT without api-version -> 400 MissingApiVersionParameter" do
    conn =
      conn(:put, "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Storage/storageAccounts/acct1", %{
        "location" => "smalt-local"
      })
      |> Router.call(@opts)

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "MissingApiVersionParameter"
  end

  test "provider PUT with bad api-version -> 400 InvalidApiVersionParameter" do
    path =
      "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Storage/storageAccounts/acct1?api-version=1999-01-01"

    conn =
      conn(:put, path, %{"location" => "smalt-local"})
      |> Router.call(@opts)

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "InvalidApiVersionParameter"
    assert body["error"]["message"] =~ "1999-01-01"
  end

  test "PUT of an unadmitted type -> 400 GraphLaw refusal envelope" do
    path =
      "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Fake/things/thing-1?api-version=2021-04-01"

    conn =
      conn(:put, path, %{"location" => "smalt-local"})
      |> Router.call(@opts)

    assert conn.status == 400

    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "InvalidResourceShape"
    assert body["error"]["target"] == "AshGraphLaw.Enforcement"
    assert is_binary(body["error"]["message"])
  end

  # The router itself is stateless over public ETS; the Store GenServer is
  # started defensively so this file also runs under `mix test --no-start`
  # when the shared tree's application start is blocked by a concurrent lane.
  defp ensure_store do
    if GenServer.whereis(Smalt.Store) == nil do
      {:ok, _} = Smalt.Store.start_link([])
    end

    :ok
  end
end
