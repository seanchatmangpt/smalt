# W2-14 — Chicago-school live leg over the REAL smalt substrate (ARM control
# plane 9443, Microsoft.App/containerApps family). No mocks: run/0 walks the
# real ARM face — STS mint, RG PUT, containerApp PUT via the generic provider
# resource route (Registry-admitted type), GET echo, type-scoped LIST — all
# over real :httpc. A down substrate surfaces as a loud FAIL/SKIP naming the
# step, never a fake pass.
#
# Context: solo (live substrate leg, host-side :httpc).

defmodule PopcornDemo.LiveContainersTest do
  use ExUnit.Case, async: false

  alias PopcornDemo.LiveContainers

  describe "run/0 full walk over live substrate" do
    test "returns OK with the containerApp listed" do
      assert {:ok, "containers=OK(" <> rest} = LiveContainers.run()
      n = rest |> String.split("-listed") |> hd() |> String.to_integer()
      assert n >= 1
    end
  end

  describe "real wire state" do
    test "GET echo carries the generic-provider id convention (/providers/)" do
      record = fetch_via_http!()
      assert record["id"] == LiveContainers.expected_id()
      assert record["type"] == LiveContainers.resource_type()
    end

    test "tokenless GET is refused 401 with a WWW-Authenticate challenge" do
      # Transport now surfaces headers; the KD-15 challenge is witnessed at
      # header level (real wire state, not a status-only proxy).
      assert {:ok, %{status: 401, headers: headers}} = LiveContainers.fetch_tokenless()

      assert {"www-authenticate", challenge} =
               Enum.find(headers, fn {k, _} -> k == "www-authenticate" end),
             "no www-authenticate header in #{inspect(headers)}"

      assert challenge =~ "Bearer"
    end
  end

  # -- Real collaborator -----------------------------------------------------
  # A real :httpc GET (with fresh STS mint) against the same endpoint run/0
  # uses, so the slice assertions consume the real wire record, not
  # module-internal state.

  defp fetch_via_http! do
    # Test-order independence: ExUnit may run this before run/0's PUT, so
    # ensure the resource exists (real walk, no setup-fixture shortcut)
    # when the GET answers 404, then retry the real GET once.
    case LiveContainers.fetch_container_app() do
      {:ok, record} ->
        record

      {:error, "containers=FAIL(get_container_app:HTTP-404" <> _} ->
        assert {:ok, _} = LiveContainers.run()
        assert {:ok, record} = LiveContainers.fetch_container_app()
        record

      other ->
        flunk("live containerApp GET failed: #{inspect(other)}")
    end
  end
end
