defmodule Smalt.AshGenTest do
  use ExUnit.Case, async: false

  alias Smalt.AshGen.Generator
  alias Smalt.AshGen.Model

  @vnet_row %{
    "resource_type" => "Microsoft.Network/virtualNetworks",
    "api_version" => "2026-03-01",
    "ash_resource" => "VirtualNetwork",
    "arm_uri_template" => "/subs/providers/Microsoft.Network/virtualNetworks/{virtualNetwork}",
    "bicep_ref" => "network/microsoft.network/2026-03-01/types.json#/3586"
  }

  @subnet_row %{
    "resource_type" => "Microsoft.Network/virtualNetworks/subnets",
    "api_version" => "2026-03-01",
    "ash_resource" => "Subnet",
    "arm_uri_template" => "/subs/.../subnets/{subnet}",
    "bicep_ref" => nil
  }

  @sb_queue_row %{"resource_type" => "Microsoft.ServiceBus/queues", "api_version" => "2024-01-01"}

  @placement_row %{
    "resource_type" => "Microsoft.Compute/locations/placementScores",
    "api_version" => "2023-09-01-preview"
  }

  @parent_rows [
    %{"child_type" => "Microsoft.Network/virtualNetworks/subnets", "parent_type" => "Microsoft.Network/virtualNetworks"},
    %{"child_type" => "Microsoft.Compute/locations/placementScores", "parent_type" => "Microsoft.Compute/locations"}
  ]

  defp models do
    Model.from_sparql_rows(%{
      bindings: [@vnet_row, @subnet_row, @sb_queue_row, @placement_row],
      parents: @parent_rows
    })
  end

  defp content(igniter, path) do
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end

  describe "Model.from_sparql_rows/1" do
    test "derives modules, prunes dangling parent, derives pack-vocab fields" do
      by_type = Map.new(models(), &{&1.resource_type, &1})

      vnet = by_type["Microsoft.Network/virtualNetworks"]
      assert vnet.resource_module == Smalt.Network.VirtualNetwork
      assert vnet.parent_module == nil

      subnet = by_type["Microsoft.Network/virtualNetworks/subnets"]
      assert subnet.resource_module == Smalt.Network.Subnet
      assert subnet.parent_module == Smalt.Network.VirtualNetwork

      queue = by_type["Microsoft.ServiceBus/queues"]
      assert queue.resource_module == Smalt.ServiceBus.Queue
      assert queue.arm_uri_template =~ "{queue}"

      placement = by_type["Microsoft.Compute/locations/placementScores"]
      assert placement.parent_module == nil
    end

    test "sorted by resource_type" do
      types = Enum.map(models(), & &1.resource_type)
      assert types == Enum.sort(types)
    end
  end

  describe "Generator" do
    test "domain + resources + registry generated and registered" do
      igniter = Igniter.Test.test_project() |> Generator.generate(models())

      domain_diff = Igniter.Test.diff(igniter, only: "lib/smalt/network.ex")
      assert domain_diff =~ "Smalt.Network.VirtualNetwork"
      assert domain_diff =~ "Smalt.Network.Subnet"

      subnet = content(igniter, "lib/smalt/network/subnet.ex")
      assert subnet =~ "belongs_to :parent"
      assert subnet =~ "Smalt.Network.VirtualNetwork"

      placement = content(igniter, "lib/smalt/compute/placement_score.ex")
      assert placement =~ "use Ash.Resource"
      refute placement =~ "belongs_to"

      registry = content(igniter, "lib/smalt/ash_gen/registry.ex")
      assert registry =~ "Smalt.Network.VirtualNetwork"
    end
  end

  describe "Generator idempotency + real-Ash validation" do
    test "second generate over applied project is zero-diff (idempotent)" do
      models = models()

      {:ok, applied, _meta} =
        Igniter.Test.test_project() |> Generator.generate(models) |> Igniter.Test.apply_igniter()

      files =
        Map.new(applied.rewrite.sources, fn {path, source} ->
          {path, Rewrite.Source.get(source, :content)}
        end)

      second =
        Igniter.Test.test_project(files: files)
        |> Generator.generate(models)

      assert Igniter.Test.diff(second) == "",
             "second run must be zero-diff, got:\n#{Igniter.Test.diff(second)}"
    end

    @tag :ash_compile_smoke
    test "generated DSL compiles + roundtrips under real Ash (ETS upsert, read, destroy)" do
      models = models()

      {:ok, applied, _meta} =
        Igniter.Test.test_project() |> Generator.generate(models) |> Igniter.Test.apply_igniter()

      vnet_code = content(applied, "lib/smalt/network/virtual_network.ex")
      subnet_code = content(applied, "lib/smalt/network/subnet.ex")
      domain_code = content(applied, "lib/smalt/network.ex")

      Code.compile_string(vnet_code)
      Code.compile_string(subnet_code)
      Code.compile_string(domain_code)

      assert Code.ensure_loaded?(Smalt.Network.VirtualNetwork)
      assert Code.ensure_loaded?(Smalt.Network.Subnet)
      assert Code.ensure_loaded?(Smalt.Network)

      arm_id = "/subscriptions/s/resourcegroups/rg/providers/microsoft.network/virtualnetworks/vnet1"

      assert {:ok, rec} =
               Ash.create(Smalt.Network.VirtualNetwork, %{arm_id: arm_id, name: "vnet1", location: "westus"},
                 action: :arm_put
               )

      # upsert: second put with same arm_id updates in place
      assert {:ok, rec2} =
               Ash.create(Smalt.Network.VirtualNetwork, %{arm_id: arm_id, tags: %{"k" => "v"}},
                 action: :arm_put
               )

      assert rec2.tags == %{"k" => "v"}

      assert {:ok, recs} = Ash.read(Smalt.Network.VirtualNetwork)
      assert length(recs) == 1

      q = Ash.Query.for_read(Smalt.Network.VirtualNetwork, :get_by_arm_id, %{arm_id: arm_id})
      assert {:ok, [got]} = Ash.read(q)
      assert got.arm_id == arm_id

      # relationship wire: subnet's parent_id points at the vnet arm_id
      assert {:ok, subnet} =
               Ash.create(Smalt.Network.Subnet, %{arm_id: arm_id <> "/subnets/s1", name: "s1"},
                 action: :arm_put
               )

      # attribute_writable? false: the envelope cannot set the FK — the router
      # layer derives it from the URI. Assert the relationship wire itself.
      rel = Ash.Resource.Info.relationship(Smalt.Network.Subnet, :parent)
      assert rel.destination == Smalt.Network.VirtualNetwork
      assert rel.destination_attribute == :arm_id
      assert subnet.parent_id == nil

      assert :ok = Ash.destroy(rec2, action: :arm_delete)
    end
  end
end
