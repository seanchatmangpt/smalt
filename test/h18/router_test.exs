defmodule Smalt.H18.RouterTest do
  use ExUnit.Case, async: false
  alias Smalt.H18.PlaneTable

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)
    port = 40_000 + :rand.uniform(9_000)
    start_supervised!({Bandit, plug: Smalt.H18.Router, port: port, ip: :loopback})
    {:ok, port: port}
  end

  defp get(port, path) do
    {:ok, {{_, status, _}, _, body}} =
      :httpc.request(:get, {~c"http://127.0.0.1:#{port}#{path}", []}, [], body_format: :binary)

    {status, Jason.decode!(body)}
  end

  test "inventory derives from the table", %{port: port} do
    {200, %{"planes" => planes}} = get(port, "/planes")
    assert Enum.map(planes, & &1["prefix"]) == PlaneTable.prefixes()
    assert Enum.all?(planes, &(&1["health"] == "/#{&1["prefix"]}/healthz"))
  end

  test "each plane has health and readiness", %{port: port} do
    for p <- PlaneTable.all() do
      assert {200, %{"status" => "alive"}} = get(port, "/#{p.prefix}/healthz")
      {status, body} = get(port, "/#{p.prefix}/readyz")
      assert {status, body["status"]} in [{200, "ready"}, {503, "not_ready"}]
      assert (status == 200) == PlaneTable.ready?(p)
    end
  end

  test "unknown plane yields typed 404", %{port: port} do
    assert {404, %{"type" => "unknown_plane", "plane" => "nope", "known" => known}} =
             get(port, "/nope/x")

    assert known == PlaneTable.prefixes()
  end
end
