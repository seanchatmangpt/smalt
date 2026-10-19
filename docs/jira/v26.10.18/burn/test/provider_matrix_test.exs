defmodule Smalt.ArmGateway.ProviderMatrixTest do
  @moduledoc """
  Cross-checks `Smalt.ArmGateway.ProviderMatrix` against `Smalt.Registry`
  (the ontology projection), not against hand-typed literals — the matrix
  must stay a projection, so the test asserts Registry-derived truth.
  """
  use ExUnit.Case, async: true

  alias Smalt.ArmGateway.ProviderMatrix
  alias Smalt.Registry

  describe "registry_namespaces/0" do
    test "covers every namespace present in the Registry" do
      expected =
        Registry.admitted_resource_types()
        |> Enum.map(fn t -> t |> String.split("/") |> hd() end)
        |> Enum.uniq()
        |> Enum.sort()

      assert ProviderMatrix.registry_namespaces() == expected
    end
  end

  describe "provider/1" do
    test "every admitted type appears with apiVersions == [latest_version]" do
      for type <- Registry.admitted_resource_types() do
        ns = type |> String.split("/") |> hd()
        leaf = type |> String.split("/") |> tl() |> Enum.join("/")

        assert provider = ProviderMatrix.provider(ns)
        assert row = Enum.find(provider["resourceTypes"], &(&1["resourceType"] == leaf))
        assert row["apiVersions"] == [Registry.latest_version(type)]
      end
    end

    test "resourceTypes are sorted deterministically" do
      for ns <- ProviderMatrix.registry_namespaces() do
        rts = ProviderMatrix.provider(ns)["resourceTypes"]
        assert rts == Enum.sort_by(rts, & &1["resourceType"])
      end
    end

    test "registrationState is the Registered constant" do
      for ns <- ProviderMatrix.registry_namespaces() do
        assert ProviderMatrix.provider(ns)["registrationState"] == "Registered"
      end
    end

    test "unknown namespace returns nil (no fabricated provider)" do
      assert ProviderMatrix.provider("Microsoft.Fabricated") == nil
    end
  end

  describe "provider_listing/1" do
    test "value covers Registry namespaces plus the extra_types supplement" do
      listing = ProviderMatrix.provider_listing()
      namespaces = Enum.map(listing["value"], & &1["namespace"])

      for ns <- ProviderMatrix.registry_namespaces() do
        assert ns in namespaces
      end

      assert "Microsoft.Resources" in namespaces
    end

    test "is deterministic across calls (x2)" do
      assert ProviderMatrix.provider_listing() == ProviderMatrix.provider_listing()
    end

    test "is deterministic under sort_keys rendering (x2, canonical.ex pattern)" do
      render = fn ->
        ProviderMatrix.provider_listing() |> sort_keys() |> Jason.encode!()
      end

      assert render.() == render.()
    end

    test "accepts the reserved options map" do
      assert %{"value" => [_ | _]} = ProviderMatrix.provider_listing(%{"dryRun" => true})
    end
  end

  describe "default_locations/0" do
    test "non-empty sorted list" do
      locs = ProviderMatrix.default_locations()
      assert is_list(locs) and locs != []
      assert locs == Enum.sort(locs)
    end

    test "pinned §3.2 set in canonical ARM-names form (matches verbatim PUT/GET storage)" do
      assert ProviderMatrix.default_locations() == ["eastus", "local", "westus2"]
    end
  end

  describe "wave-2 listing shape (router provider listing contract)" do
    test "no row carries a subscriptionId; every row has namespace/resourceTypes/registrationState" do
      listing = ProviderMatrix.provider_listing()

      for p <- listing["value"] do
        refute Map.has_key?(p, "subscriptionId")
        assert is_binary(p["namespace"])
        assert is_list(p["resourceTypes"]) and p["resourceTypes"] != []
        assert p["registrationState"] in ["Registered", "Unregistering"]
      end
    end

    test "single-provider lookup matches the listing row for every namespace" do
      listing = ProviderMatrix.provider_listing()

      for p <- listing["value"] do
        assert ProviderMatrix.provider(p["namespace"]) == p
      end
    end
  end

  defp sort_keys(term) when is_map(term) do
    term |> Enum.map(fn {k, v} -> {to_string(k), sort_keys(v)} end) |> Map.new()
  end

  defp sort_keys(term) when is_list(term), do: Enum.map(term, &sort_keys/1)
  defp sort_keys(term), do: term
end
