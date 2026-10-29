# X7 — Chicago-school live leg over the REAL smalt substrate (ARM control
# plane 9443, resource-group exportTemplate, KD-59 export face). No mocks:
# run/0 walks the real ARM face — STS mint, RG PUT, storage account +
# containerApp seeding via the generic provider PUT, exportTemplate 200 with
# both resources, typed 404 on an absent RG — all over real :httpc. A down
# substrate surfaces as a loud SKIP/FAIL naming the step, never a fake pass.
#
# Context: solo (live substrate leg, host-side :httpc).

defmodule PopcornDemo.LiveExportTest do
  use ExUnit.Case, async: false

  alias PopcornDemo.LiveExport

  describe "run/0 full walk over live substrate" do
    test "returns OK with the exported-resource count" do
      assert {:ok, "export=OK(" <> rest} = LiveExport.run()
      n = rest |> String.split("-resources-exported") |> hd() |> String.to_integer()
      assert n >= 2
    end
  end

  describe "real wire state" do
    test "re-export via test seam still carries both seeded resources" do
      # Re-run the real walk to mint fresh run-unique resources, then a real
      # exportTemplate POST through the seam; if a 404 lands (test-order
      # independence), re-run the real walk and retry once.
      case LiveExport.fetch_export() do
        {:ok, tpl} ->
          assert both_seeded?(tpl["resources"])

        {:error, "export=FAIL(fetch_export:HTTP-404" <> _} ->
          assert {:ok, _} = LiveExport.run()
          assert {:ok, tpl} = LiveExport.fetch_export()
          assert both_seeded?(tpl["resources"])

        other ->
          flunk("live exportTemplate failed: #{inspect(other)}")
      end
    end

    test "tokenless exportTemplate is refused 401" do
      assert {:ok, %{status: 401}} = LiveExport.fetch_tokenless()
    end
  end

  # -- Real collaborator --------------------------------------------------------

  defp both_seeded?(resources) when is_list(resources) do
    types = MapSet.new(resources, & &1["type"])
    MapSet.member?(types, LiveExport.sa_type()) and MapSet.member?(types, LiveExport.ca_type())
  end

  defp both_seeded?(other), do: flunk("resources not a list: #{inspect(other)}")
end
