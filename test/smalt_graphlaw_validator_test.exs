defmodule Smalt.GraphLaw.ValidatorTest do
  use ExUnit.Case, async: true

  alias Smalt.GraphLaw.NtSerializer
  alias Smalt.GraphLaw.Validator

  @admitted Smalt.Registry.admitted_resource_types()

  describe "compile-time shape parsing" do
    test "parses every NodeShape in the shapes file" do
      shapes = Validator.shapes()

      for name <- ~w(DefaultShape ResourceGroupShape VNetShape SubnetShape NsgShape
                     VirtualMachineShape KeyVaultShape ManagedHsmShape StorageAccountShape
                     CosmosAccountShape) do
        assert Map.has_key?(shapes, name), "missing shape #{name}"
      end

      # 11 shapes as of the ServiceBusNamespaceShape addition (was 10).
      assert length(Map.keys(shapes)) == 11
    end

    test "extracts required properties and messages" do
      vnet = Validator.shapes()["VNetShape"]
      paths = Enum.map(vnet.required, & &1.path)
      assert "location" in paths
      assert "addressPrefixes" in paths

      vm = Validator.shapes()["VirtualMachineShape"]
      assert Enum.map(vm.required, & &1.path) == ["location", "vmSize"]

      location = Enum.find(vm.required, &(&1.path == "location"))
      assert location.min_count == 1
      assert is_binary(location.message)
    end

    test "shapes without property blocks have empty required lists" do
      assert Validator.shapes()["NsgShape"].required == []
      assert Validator.shapes()["DefaultShape"].required != []
    end
  end

  describe "validate_resource/2 refusal matrix" do
    test "not-admitted types are refused" do
      assert Validator.validate_resource("Microsoft.Fake/unicorns", %{"location" => "x"}) ==
               {:refused, :type_not_admitted}
    end

    test "every admitted type gets a verdict, never an auto-pass" do
      shape_names = Validator.shapes()

      for type <- @admitted do
        result = Validator.validate_resource(type, %{})

        assert elem(result, 0) in [:invalid, :ok],
               "unexpected verdict for #{type}: #{inspect(result)}"

        shape = shape_for_admitted_type(type, shape_names)

        if shape && shape.required != [] do
          assert match?({:invalid, _}, result), "#{type} must not pass on an empty payload"
        end
      end
    end

    defp shape_for_admitted_type(type, shapes) do
      name = Smalt.Registry.shape_for(type)

      name =
        case name do
          n when is_binary(n) -> n
          {:ok, n} -> n
          _ -> nil
        end

      name && Map.get(shapes, name)
    end
  end

  describe "validate_resource/2 conforming payloads" do
    test "minimal conforming payload (location + properties map) passes for every shape" do
      for {_name, shape} <- Validator.shapes() do
        type = shape_type_for(shape)

        payload =
          %{
            "location" => "eastus",
            "properties" =>
              shape.required
              |> Enum.reject(&(&1.path == "location"))
              |> Map.new(fn prop -> {prop.path, "x"} end)
          }

        assert Validator.validate_resource(type, payload) == {:ok},
               "type #{inspect(type)} shape #{inspect(shape)} should accept #{inspect(payload)}"
      end
    end

    test "missing required property is invalid with minCount constraint" do
      result =
        Validator.validate_resource("Microsoft.Compute/virtualMachines", %{"location" => "eastus"})

      assert {:invalid, violations} = result

      assert Enum.any?(violations, &(&1.path == "vmSize" and &1.constraint == "minCount"))
    end

    test "malformed payload is invalid, not refused" do
      result =
        Validator.validate_resource("Microsoft.Network/virtualNetworks", %{"garbage" => true})

      assert {:invalid, violations} = result

      assert length(violations) == 2
      assert Enum.all?(violations, &(&1.constraint == "minCount"))
    end

    test "dotted properties.<prop> path resolves" do
      result =
        Validator.validate_resource("Microsoft.KeyVault/vaults", %{
          "location" => "eastus",
          "properties" => %{"skuName" => "standard"}
        })

      assert result == {:ok}
    end

    test "nil property value counts as absent" do
      result =
        Validator.validate_resource("Microsoft.Storage/storageAccounts", %{
          "location" => "eastus",
          "properties" => %{"skuName" => nil}
        })

      assert {:invalid, _} = result
    end

    test "violations carry shape-file messages" do
      {:invalid, [violation]} =
        Validator.validate_resource("Microsoft.Compute/virtualMachines", %{
          "properties" => %{"vmSize" => "Standard_D2s_v5"}
        })

      assert violation.path == "location"
      assert violation.message =~ "virtualMachines require location"
    end
  end

  describe "NtSerializer" do
    test "byte-stable across map insertion order" do
      a = %{"location" => "eastus", "properties" => %{"skuName" => "standard", "z" => 1}}
      b = %{"properties" => %{"z" => 1, "skuName" => "standard"}, "location" => "eastus"}

      assert NtSerializer.serialize(a) == NtSerializer.serialize(b)
      assert byte_size(NtSerializer.serialize(a)) > 0
    end

    test "nested maps become dotted-path predicates" do
      nt = NtSerializer.serialize(%{"properties" => %{"sku" => %{"name" => "standard"}}})

      assert nt ==
               ~s(<urn:smalt:payload> <https://ggen.io/ontology/smalt#properties.sku.name> "standard" .\n)
    end

    test "arrays produce repeated triples" do
      nt = NtSerializer.serialize(%{"addressPrefixes" => ["10.0.0.0/8", "10.1.0.0/16"]})

      lines = String.split(nt, "\n", trim: true)
      assert length(lines) == 2

      assert lines == [
               ~s(<urn:smalt:payload> <https://ggen.io/ontology/smalt#addressPrefixes> "10.0.0.0/8" .),
               ~s(<urn:smalt:payload> <https://ggen.io/ontology/smalt#addressPrefixes> "10.1.0.0/16" .)
             ]
    end

    test "typed literals and nil skipping" do
      nt = NtSerializer.serialize(%{"n" => 3, "flag" => true, "gone" => nil})

      assert nt =~ ~s("3"^^<http://www.w3.org/2001/XMLSchema#integer>)
      assert nt =~ ~s("true"^^<http://www.w3.org/2001/XMLSchema#boolean>)
      refute nt =~ "gone"
    end

    test "empty map serializes to empty string" do
      assert NtSerializer.serialize(%{}) == ""
    end
  end

  # ---------------------------------------------------------------------------
  # Stress / semantics-audit lane (lane: graphlaw-stress)
  # ---------------------------------------------------------------------------

  @moduletag :graphlaw_stress

  describe "closed semantics (sh:closed true enforced by evaluate/2)" do
    test "every shape in the file declares sh:closed false explicitly (vocabulary incomplete)" do
      for {name, shape} <- Validator.shapes() do
        assert shape.closed == false,
               "shape " <> name <> " must be sh:closed false: ARM payload vocabulary " <>
                 "(tags, sku, dnsPrefix, ...) exceeds its declared property list"

        for prop <- shape.required do
          assert Map.has_key?(prop, :datatype) and is_nil(prop.datatype),
                 "property " <> name <> "." <> prop.path <> " must record datatype (nil when absent)"
        end
      end
    end

    test "unknown top-level property is a closed violation" do
      shape = closed_location_shape()

      assert {:invalid, violations} =
               Validator.validate_shape(shape, %{"location" => "eastus", "tags" => %{"env" => "dev"}})

      assert Enum.any?(violations, &(&1.path == "tags" and &1.constraint == "closed"))
    end

    test "unknown key inside properties is a closed violation" do
      shape = closed_location_shape()

      assert {:invalid, violations} =
               Validator.validate_shape(shape, %{
                 "location" => "eastus",
                 "properties" => %{"ledgerType" => "Private"}
               })

      assert Enum.any?(violations, &(&1.path == "properties.ledgerType" and &1.constraint == "closed"))
    end

    test "closed shape accepts payloads carrying only declared paths (plus the properties container)" do
      shape = closed_location_shape()

      assert Validator.validate_shape(shape, %{"location" => "eastus"}) == {:ok}

      assert Validator.validate_shape(shape, %{
               "location" => "eastus",
               "properties" => %{}
             }) == {:ok}
    end

    test "closed shape with no declared properties rejects every payload property (nothing extra allowed)" do
      shape = %{target_class: nil, closed: true, required: []}

      assert {:invalid, violations} = Validator.validate_shape(shape, %{"location" => "eastus"})
      assert Enum.all?(violations, &(&1.constraint == "closed"))

      assert Validator.validate_shape(shape, %{}) == {:ok}
    end

    test "closed violations merge with minCount violations" do
      shape = closed_location_shape()

      assert {:invalid, violations} =
               Validator.validate_shape(shape, %{"properties" => %{"skuName" => "x"}})

      assert Enum.any?(violations, &(&1.constraint == "closed"))
      assert Enum.any?(violations, &(&1.constraint == "minCount"))
    end

    test "closed violations carry constraint/message/path" do
      shape = closed_location_shape()

      assert {:invalid, [violation]} =
               Validator.validate_shape(shape, %{"location" => "eastus", "tags" => %{}})

      assert violation.path == "tags"
      assert violation.constraint == "closed"
      assert violation.message =~ "unknown property path"
    end
  end

  describe "datatype enforcement (sh:datatype evaluated)" do
    test "string-typed property receiving a non-binary value is invalid" do
      shape = parsed_typed_shape()

      assert shape.closed == false
      assert [%{path: "location", datatype: :string, min_count: 1}] = shape.required

      # datatype round-trips
      assert Validator.validate_shape(shape, %{"location" => "eastus"}) == {:ok}
      assert match?({:invalid, _}, Validator.validate_shape(shape, %{"location" => 42}))
      assert match?({:invalid, _}, Validator.validate_shape(shape, %{"location" => true}))
      assert match?({:invalid, _}, Validator.validate_shape(shape, %{"location" => %{}}))

      assert {:invalid, [violation]} = Validator.validate_shape(shape, %{"location" => 42})
      assert violation.path == "location"
      assert violation.constraint == "datatype"
      assert violation.message =~ "xsd:string"
    end

    test "integer and boolean datatypes round-trip" do
      ttl = """
      smalt:TypedShape a sh:NodeShape ;
          sh:targetClass smalt:Thing ;
          sh:property [
              sh:path smalt:count ;
              sh:datatype xsd:integer ;
              sh:minCount 1 ;
          ] , [
              sh:path smalt:enabled ;
              sh:datatype xsd:boolean ;
          ] .
      """

      shape = Smalt.GraphLaw.Validator.ShapeFile.parse!(ttl, "inline-test.ttl")["TypedShape"]
      assert %{"count" => count_prop, "enabled" => enabled_prop} =
               Map.new(shape.required, &{&1.path, &1})

      assert count_prop.datatype == :integer
      assert enabled_prop.datatype == :boolean
      assert enabled_prop.min_count == 1

      assert Validator.validate_shape(shape, %{"properties" => %{"count" => 3, "enabled" => true}}) == {:ok}

      assert match?(
               {:invalid, _},
               Validator.validate_shape(shape, %{"properties" => %{"count" => "3", "enabled" => true}})
             )

      assert match?(
               {:invalid, _},
               Validator.validate_shape(shape, %{"properties" => %{"count" => 3, "enabled" => 1}})
             )
    end

    test "datatype check only fires when the value is present; absence stays a minCount matter" do
      shape = parsed_typed_shape()

      assert match?(
               {:invalid, [%{constraint: "minCount"}]},
               Validator.validate_shape(shape, %{"properties" => %{"vmSize" => "x"}})
             )

      # absence is a minCount violation, never a datatype violation
      assert match?(
               {:invalid, [%{constraint: "minCount"}]},
               Validator.validate_shape(shape, %{})
             )
    end
  end

  describe "sh:datatype / unknown-keyword parse errors name the real offender" do
    test "unsupported sh:datatype is a compile error naming the datatype" do
      ttl = """
      smalt:TypedShape a sh:NodeShape ;
          sh:targetClass smalt:Thing ;
          sh:property [
              sh:path smalt:location ;
              sh:datatype xsd:dateTime ;
              sh:minCount 1 ;
          ] .
      """

      assert_raise CompileError, ~r/unsupported sh:datatype "xsd:dateTime"/, fn ->
        Smalt.GraphLaw.Validator.ShapeFile.parse!(ttl, "inline-test.ttl")
      end
    end

    test "unknown property constraint keyword is a compile error naming that keyword (not sh:minCount)" do
      ttl = """
      smalt:WeirdShape a sh:NodeShape ;
          sh:targetClass smalt:Thing ;
          sh:property [
              sh:path smalt:location ;
              sh:quantumFlux true ;
              sh:minCount 1 ;
          ] .
      """

      assert_raise CompileError, ~r/unsupported sh:property constraint "sh:quantumFlux"/, fn ->
        Smalt.GraphLaw.Validator.ShapeFile.parse!(ttl, "inline-test.ttl")
      end
    end
  end

  describe "non-string payloads (pinned current verdicts)" do
    test "integer location passes the gate (file shapes declare no sh:datatype)" do
      assert Validator.validate_resource("Microsoft.Resources/resourceGroups", %{
               "location" => 42
             }) == {:ok}
    end

    test "boolean location passes the gate" do
      assert Validator.validate_resource("Microsoft.Network/networkSecurityGroups", %{
               "location" => false
             }) == {:ok}
    end

    test "false and 0 are present (only nil/absent count as missing)" do
      assert Validator.validate_resource("Microsoft.Network/virtualNetworks", %{
               "location" => 0,
               "properties" => %{"addressPrefixes" => []}
             }) == {:ok}
    end

    test "map-valued location passes the gate" do
      assert Validator.validate_resource("Microsoft.Resources/resourceGroups", %{
               "location" => %{"nested" => "object"}
             }) == {:ok}
    end
  end

  describe "unicode / oversized payloads" do
    @one_mb String.duplicate("é", 512 * 1024)

    test "1MB unicode location: no crash, deterministic verdict" do
      payload = %{"location" => @one_mb}

      assert Validator.validate_resource("Microsoft.Resources/resourceGroups", payload) == {:ok}
      # determinism: same input, same verdict on a repeat call
      assert Validator.validate_resource("Microsoft.Resources/resourceGroups", payload) == {:ok}
    end

    test "100-deep nested payload: no crash, deterministic verdict" do
      deep = Enum.reduce(1..100, %{"x" => 1}, fn _, acc -> %{"n" => acc} end)

      payload = %{
        "location" => "eastus",
        "properties" => Map.merge(%{"skuName" => "Standard_LRS"}, %{"extra" => deep})
      }

      type = "Microsoft.Storage/storageAccounts"

      assert Validator.validate_resource(type, payload) == {:ok}
      assert Validator.validate_resource(type, payload) == {:ok}
    end

    test "deeply nested value under a required path is still present (no depth blowup)" do
      deep = Enum.reduce(1..100, "bottom", fn _, acc -> %{"n" => acc} end)
      payload = %{"location" => deep}

      assert Validator.validate_resource("Microsoft.Resources/resourceGroups", payload) == {:ok}
    end
  end

  describe "concurrency: 32 parallel validate_resource/2 calls" do
    test "distinct types in parallel all get correct verdicts (pure, ETS-free)" do
      types = Enum.take(@admitted, 32)
      assert length(types) == 32

      jobs =
        Map.new(types, fn type ->
          shape = shape_for_admitted_type(type, Validator.shapes())

          payload =
            if shape && shape.required != [] do
              %{
                "location" => "eastus",
                "properties" =>
                  shape.required
                  |> Enum.reject(&(&1.path == "location"))
                  |> Map.new(fn prop -> {prop.path, "x"} end)
              }
            else
              %{}
            end

          {type, payload}
        end)

      results =
        jobs
        |> Task.async_stream(
          fn {type, payload} -> {type, Validator.validate_resource(type, payload)} end,
          max_concurrency: 32,
          order: :input,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, pair} -> pair end)

      for {type, verdict} <- results do
        assert verdict == {:ok}, "expected {:ok} for #{type}, got #{inspect(verdict)}"
      end

      assert length(results) == 32
    end

    test "mixed valid/invalid payloads in parallel stay correctly separated" do
      valid =
        Task.async_stream(1..32, fn _ ->
          Validator.validate_resource("Microsoft.Compute/virtualMachines", %{
            "location" => "eastus",
            "properties" => %{"vmSize" => "Standard_D2s_v5"}
          })
        end)

      invalid =
        Task.async_stream(1..32, fn _ ->
          Validator.validate_resource("Microsoft.Compute/virtualMachines", %{"location" => "eastus"})
        end)

      assert Enum.all?(valid, &match?({:ok, {:ok}}, &1))
      assert Enum.all?(invalid, &match?({:ok, {:invalid, _}}, &1))
    end
  end

  defp closed_location_shape do
    %{
      target_class: nil,
      closed: true,
      required: [
        %{path: "location", min_count: 1, max_count: nil, datatype: nil, message: nil}
      ]
    }
  end

  defp parsed_typed_shape do
    ttl = """
    smalt:TypedShape a sh:NodeShape ;
        sh:targetClass smalt:Thing ;
        sh:property [
            sh:path smalt:location ;
            sh:datatype xsd:string ;
            sh:minCount 1 ;
        ] .
    """

    Smalt.GraphLaw.Validator.ShapeFile.parse!(ttl, "inline-test.ttl")["TypedShape"]
  end

  defp shape_type_for(shape) do
    # Map each shape back to an admitted registry type via the registry's
    # shape_for seam; fall back to a zero-constraint admitted type.
    name = shape_name_of(shape)

    Enum.find(@admitted, fn type ->
      case Smalt.Registry.shape_for(type) do
        n when is_binary(n) -> n == name
        {:ok, n} -> n == name
        _ -> false
      end
    end) || "Microsoft.Network/networkSecurityGroups"
  end

  defp shape_name_of(shape) do
    Enum.find_value(Validator.shapes(), fn {key, val} ->
      if val == shape, do: key
    end)
  end
end
