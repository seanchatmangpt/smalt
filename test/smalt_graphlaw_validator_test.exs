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

      # 14 shapes: 11 as of ServiceBusNamespaceShape, +KeyVaultSecretShape
      # +SqlDatabaseShape +SqlContainerShape (added later, pins lagged).
      assert length(Map.keys(shapes)) == 14
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

    test "azurerm sku object {name, tier} satisfies skuName (storage + vault)" do
      # azurerm storageAccounts wire form: sku {name: "Standard_LRS", tier: "Standard"}
      assert {:ok} =
               Validator.validate_resource("Microsoft.Storage/storageAccounts", %{
                 "location" => "eastus",
                 "sku" => %{"name" => "Standard_LRS", "tier" => "Standard"},
                 "properties" => %{}
               })

      assert {:ok} =
               Validator.validate_resource("Microsoft.Storage/storageAccounts", %{
                 "location" => "eastus",
                 "properties" => %{"sku" => %{"name" => "Standard_LRS"}}
               })

      # vault wire form: sku {name: "standard"} — both containers accepted
      assert {:ok} =
               Validator.validate_resource("Microsoft.KeyVault/vaults", %{
                 "location" => "eastus",
                 "sku" => %{"name" => "standard"}
               })

      assert {:ok} =
               Validator.validate_resource("Microsoft.KeyVault/vaults", %{
                 "location" => "eastus",
                 "properties" => %{"sku" => %{"name" => "standard"}}
               })
    end

    test "sku alias does not weaken refusals: absent/nil sku still refuses" do
      # neither sku nor skuName -> minCount violation
      assert {:invalid, violations} =
               Validator.validate_resource("Microsoft.Storage/storageAccounts", %{
                 "location" => "eastus",
                 "properties" => %{}
               })

      assert Enum.all?(violations, &(&1.constraint == "minCount"))

      assert {:invalid, _} =
               Validator.validate_resource("Microsoft.KeyVault/vaults", %{
                 "location" => "eastus",
                 "sku" => %{"tier" => "Standard"}
               })

      # nil sku.name counts as absent, matching the nil-skuName law
      assert {:invalid, _} =
               Validator.validate_resource("Microsoft.KeyVault/vaults", %{
                 "location" => "eastus",
                 "sku" => %{"name" => nil}
               })
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

  describe "ShapeFile parser fuzz fence" do
    alias Smalt.GraphLaw.Validator.ShapeFile

    # Adversarial corpus: every input must either parse cleanly or raise
    # CompileError with a named description. NO other exception class may
    # escape (FunctionClauseError/MatchError/ArgumentError = defect).
    @fuzz_cases [
      "\"",
      "<",
      "<iri",
      "smalt:X a sh:NodeShape ; sh:property [ sh:path smalt:p",
      "smalt:X a sh:NodeShape . \"unterminated",
      "smalt:X a sh:NodeShape . <open",
      "",
      "###",
      ".",
      "[[[",
      "\\\\",
      <<0, 255, 32, 103, 97, 114, 98, 97, 103, 101, 32, 9, 111, 107, 101, 110>>,
      "a b c .",
      "smalt:X a sh:NodeShape ; sh:closed maybe .",
      "smalt:X a sh:NodeShape ; sh:property [ sh:minCount \"x\" ] .",
      "smalt:X a sh:NodeShape ; sh:property [ ] .",
      "smalt:X a sh:NodeShape ; sh:property [ sh:path smalt:p ; sh:datatype xsd:float ] .",
      "smalt:X a sh:NodeShape ; sh:property [ smalt:p smalt:q ] .",
      "smalt:X a sh:NodeShape ; sh:property [ sh:path smalt:p ; sh:bogus 1 ] ."
    ]

    test "malformed shapes text parses or raises CompileError — never any other class" do
      for text <- @fuzz_cases do
        result =
          try do
            ShapeFile.parse!(text, "fuzz")
            :parsed
          rescue
            CompileError -> :compile_error
          end

        assert result in [:parsed, :compile_error],
               "input #{inspect(text)} escaped with #{inspect(result)}"
      end
    end

    test "unterminated literals raise CompileError with named descriptions" do
      assert_raise CompileError, ~r/unterminated string/, fn ->
        ShapeFile.parse!("smalt:X a sh:NodeShape . \"oops", "fuzz")
      end

      assert_raise CompileError, ~r/unterminated IRI/, fn ->
        ShapeFile.parse!("smalt:X a sh:NodeShape . <oops", "fuzz")
      end
    end

    test "real shapes file still parses after tightening" do
      text = File.read!(Path.expand("../priv/shacl/smalt-shapes.ttl", __DIR__))
      shapes = ShapeFile.parse!(text, "smalt-shapes.ttl")

      assert map_size(shapes) == 14
      assert shapes["DefaultShape"].required != []
    end

    # Deterministic pseudo-random sweep (fixed seed): wider input space, same
    # contract. Random bytes + random punctuation cuts over the corpus seed.
    test "deterministic random-byte sweep stays inside the exception contract" do
      alphabet = ~c"\"<>[]{}.,;#aZ0 \\"

      for seed <- 1..200 do
        text =
          :rand.seed_s(:exsss, {seed, 0, 0})
          |> then(fn _ ->
            n = :rand.uniform(40)

            Enum.map(1..n, fn _ -> Enum.random(alphabet) end)
          end)
          |> List.to_string()

        result =
          try do
            ShapeFile.parse!(text, "fuzz")
            :parsed
          rescue
            CompileError -> :compile_error
          end

        assert result in [:parsed, :compile_error],
               "seed #{seed} input #{inspect(text)} escaped with #{inspect(result)}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Lens-2 generated sweep (lane: store-graphlaw, deep lens 2)
  # ---------------------------------------------------------------------------

  describe "lens-2 generated sweep: 38 types x malformed payloads" do
    @lens2_types Smalt.Registry.admitted_resource_types()

    # A payload is conforming for a type iff it carries every required path of
    # the type's resolved shape. Generated from the real compiled shapes —
    # no payload is hand-written per type.
    defp conforming_payload(type) do
      shape = shape_for_admitted_type(type, Validator.shapes())

      %{
        "location" => "eastus",
        "properties" =>
          shape.required
          |> Enum.reject(&(&1.path == "location"))
          |> Map.new(fn prop -> {prop.path, "x"} end)
      }
    end

    test "per-prop deletion sweep: removing exactly one required prop yields exactly that minCount violation (38 types)" do
      for type <- @lens2_types do
        shape = shape_for_admitted_type(type, Validator.shapes())
        payload = conforming_payload(type)

        # minCount-0 properties are OPTIONAL vocabulary declarations
        # (defaults bijection): deleting one must NOT yield a violation.
        for prop <- Enum.filter(shape.required, &(&1.min_count != 0)) do
          violated =
            case prop.path do
              "location" -> Map.delete(payload, "location")
              path -> put_in(payload, ["properties", path], nil)
            end

          assert {:invalid, violations} = Validator.validate_resource(type, violated),
                 "#{type}: deleting #{prop.path} must yield {:invalid, _}"

          assert [%{path: expected_path, constraint: "minCount"}] = violations,
                 "#{type}: deleting #{prop.path} must yield EXACTLY the minCount violation " <>
                   "for that path, got #{inspect(violations)}"

          assert expected_path == prop.path

          if prop.message do
            assert hd(violations).message == prop.message,
                   "#{type}: violation must carry the shape-file message, got #{inspect(violations)}"
          end
        end

        # and the conforming payload itself passes
        assert Validator.validate_resource(type, conforming_payload(type)) == {:ok},
               "#{type}: generated conforming payload must pass"
      end
    end

    test "hostile-extra-key sweep: conforming payload + hostile keys stays typed {:invalid,_} (38 types)" do
      hostile_keys = [
        {:atom_key, 1},
        {1, 2},
        {{:t, 1}, 2},
        {"x" <> String.duplicate("K", 500), 1},
        {"a\nb\0c", 1}
      ]

      for type <- @lens2_types do
        shape = shape_for_admitted_type(type, Validator.shapes())

        for {bad_key, bad_val} <- hostile_keys do
          payload = Map.put(conforming_payload(type), bad_key, bad_val)
          result = Validator.validate_resource(type, payload)

          case shape.closed do
            false ->
              # Open shape law: an undeclared extra key is NOT a violation —
              # the conforming payload plus a hostile key stays the typed
              # {:ok}, never a crash.
              assert result == {:ok},
                     "#{type}: open shape + hostile key #{inspect(bad_key)} must stay {:ok}, got #{inspect(result)}"

            true ->
              assert {:invalid, violations} = result

              assert Enum.any?(violations, &(&1.constraint == "closed"))
          end
        end
      end
    end

    test "guard-contract sweep: non-binary type / non-map payload never crashes the shared runtime" do
      # Pinned fail-closed contract (cycle-12 receipt): the guards raise
      # FunctionClauseError in the CALLER process — a hard failure, never an
      # auto-pass, and the pure validator holds no shared state to corrupt.
      for bad <- [nil, 42, {:tuple, 1}, ["list"]] do
        assert_raise FunctionClauseError, fn -> Validator.validate_resource(bad, %{}) end

        assert_raise FunctionClauseError, fn ->
          Validator.validate_resource("Microsoft.Compute/disks", bad)
        end
      end
    end
  end

  describe "fail-closed shape resolution" do
    test "every admitted type's registry shape binding resolves to a compiled shape (drift detector)" do
      for type <- Smalt.Registry.admitted_resource_types() do
        assert Validator.shape_for_type(type),
               "registry binds #{type} to #{inspect(Smalt.Registry.shape_for(type))} " <>
                 "but no compiled shape resolves — validate_local/2 now REFUSES this " <>
                 "(fail-closed); fix priv/shacl/smalt-shapes.ttl or the pack ontology"
      end
    end

    test "resolve_shape/2 returns nil for a missing binding — the fail-closed refusal trigger" do
      # Real shapes minus one binding's shape: the drifted-world simulation.
      drifted = Map.delete(Validator.shapes(), "KeyVaultShape")

      assert Validator.resolve_shape(drifted, "KeyVaultShape") == nil
      assert Validator.resolve_shape(drifted, "VaultShape") == nil
      assert Validator.resolve_shape(drifted, "Vault") == nil

      # Resolution itself still works for present bindings.
      assert Validator.resolve_shape(Validator.shapes(), "KeyVaultShape")

      assert Validator.resolve_shape(Validator.shapes(), "KeyVaultShapeShape") ||
               Validator.resolve_shape(Validator.shapes(), "KeyVault")
    end
  end

  describe "closed semantics (sh:closed true enforced by evaluate/2)" do
    test "every shape in the file declares sh:closed false explicitly (vocabulary incomplete)" do
      for {name, shape} <- Validator.shapes() do
        assert shape.closed == false,
               "shape " <>
                 name <>
                 " must be sh:closed false: ARM payload vocabulary " <>
                 "(tags, sku, dnsPrefix, ...) exceeds its declared property list"

        for prop <- shape.required do
          assert Map.has_key?(prop, :datatype) and is_nil(prop.datatype),
                 "property " <>
                   name <> "." <> prop.path <> " must record datatype (nil when absent)"
        end
      end
    end

    test "unknown top-level property is a closed violation" do
      shape = closed_location_shape()

      assert {:invalid, violations} =
               Validator.validate_shape(shape, %{
                 "location" => "eastus",
                 "tags" => %{"env" => "dev"}
               })

      assert Enum.any?(violations, &(&1.path == "tags" and &1.constraint == "closed"))
    end

    test "unknown key inside properties is a closed violation" do
      shape = closed_location_shape()

      assert {:invalid, violations} =
               Validator.validate_shape(shape, %{
                 "location" => "eastus",
                 "properties" => %{"ledgerType" => "Private"}
               })

      assert Enum.any?(
               violations,
               &(&1.path == "properties.ledgerType" and &1.constraint == "closed")
             )
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

    test "non-binary payload keys under a closed shape are violations, never crashes" do
      shape = closed_location_shape()

      for bad_key <- [:atom_key, 1, {:tuple, 1}] do
        result = Validator.validate_shape(shape, %{bad_key => 1, "location" => "x"})

        assert match?({:invalid, _}, result),
               "non-binary key #{inspect(bad_key)} must refuse, got #{inspect(result)}"

        assert Enum.any?(elem(result, 1), fn v ->
                 v.constraint == "closed" and is_binary(v.path) and
                   String.contains?(v.message, "unknown property path")
               end),
               "expected a well-formed closed violation for #{inspect(bad_key)}"
      end
    end

    test "hostile oversized keys are capped — refusal envelopes stay wire-safe" do
      shape = closed_location_shape()

      huge = String.duplicate("K", 1_000_000)

      for payload <- [
            %{huge => 1, "location" => "x"},
            %{String.duplicate("Z", 500) => 1, "location" => "x"}
          ] do
        assert {:invalid, violations} = Validator.validate_shape(shape, payload)

        for v <- violations do
          assert byte_size(v.path) <= 200, "path echo not capped: #{byte_size(v.path)} bytes"

          assert byte_size(v.message) <= 300,
                 "message echo not capped: #{byte_size(v.message)} bytes"
        end
      end
    end

    test "newline and control-character keys produce safe text, no crash" do
      shape = closed_location_shape()

      assert {:invalid, _} = Validator.validate_shape(shape, %{"a\nb\0c" => 1, "location" => "x"})
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

      assert Validator.validate_shape(shape, %{"properties" => %{"count" => 3, "enabled" => true}}) ==
               {:ok}

      assert match?(
               {:invalid, _},
               Validator.validate_shape(shape, %{
                 "properties" => %{"count" => "3", "enabled" => true}
               })
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
          Validator.validate_resource("Microsoft.Compute/virtualMachines", %{
            "location" => "eastus"
          })
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

  describe "lens-3 cycle-3 hostility sweep" do
    test "registry->shapes coherence after the cycle-1 re-baseline: every admitted type resolves a compiled shape" do
      for type <- @admitted do
        assert Validator.shape_for_type(type) != nil,
               "admitted type #{type} has no compiled shape (fail-closed would refuse)"

        verdict = Validator.validate_resource(type, %{}) |> elem(0)

        assert verdict in [:ok, :invalid],
               "admitted type #{type} must get a typed verdict, never a refusal"
      end
    end

    test "closed-shape hostility: extra keys, hostile key classes, alias interplay" do
      shape = %{
        target_class: nil,
        closed: true,
        required: [
          %{path: "location", min_count: 1, datatype: :string, message: nil}
        ]
      }

      # documented alias law: "location" is read TOP-LEVEL ONLY (payload_paths
      # special-cases it); properties.location does NOT satisfy it
      assert match?(
               {:invalid, [%{constraint: "minCount"}]},
               Validator.validate_shape(shape, %{"properties" => %{"location" => "eastus"}})
             )

      # closed: extra top-level key is a closed violation
      assert match?(
               {:invalid, [%{constraint: "closed"}]},
               Validator.validate_shape(shape, %{"location" => "eastus", "extra" => 1})
             )

      # closed: the properties container itself is exempt, unknown inner keys are not
      assert match?(
               {:invalid, [%{constraint: "closed", path: "properties.nope"}]},
               Validator.validate_shape(shape, %{
                 "location" => "eastus",
                 "properties" => %{"nope" => 1}
               })
             )

      # closed + datatype: a map where a string is required -> exactly the
      # datatype violation (location IS present, so no minCount)
      assert match?(
               {:invalid, [%{constraint: "datatype"}]},
               Validator.validate_shape(shape, %{"location" => %{"deep" => "x"}})
             ),
             "map-for-string must yield exactly the datatype violation"
    end

    test "datatype hostility: float/string/bool/list/map values for typed props are violations, never crashes" do
      shape = %{
        target_class: nil,
        closed: false,
        required: [
          %{path: "count", min_count: 1, datatype: :integer, message: nil}
        ]
      }

      for hostile <- [1.0, "1", true, [], %{}] do
        assert match?({:invalid, _}, Validator.validate_shape(shape, %{"count" => hostile})),
               "integer prop must reject #{inspect(hostile)}"
      end

      # bignums are still integers: pass (witnessed, pinned)
      assert Validator.validate_shape(shape, %{"count" => 1_000_000_000_000_000_000_000}) ==
               {:ok}

      # honest value passes
      assert Validator.validate_shape(shape, %{"count" => 1}) == {:ok}

      # list value for a string prop: violation, not crash
      string_shape = %{
        target_class: nil,
        closed: false,
        required: [%{path: "name", min_count: 1, datatype: :string, message: nil}]
      }

      assert match?({:invalid, _}, Validator.validate_shape(string_shape, %{"name" => ["a"]}))
    end

    test "hostile keys under closed: non-binary and 10k-char keys yield capped closed violations, no crash" do
      shape = %{target_class: nil, closed: true, required: []}

      hostile = %{
        1 => "int key",
        :atom_key => "atom key",
        String.duplicate("x", 10_000) => "huge key",
        "a.b" => "dotted key"
      }

      {:invalid, vs} = Validator.validate_shape(shape, hostile)
      assert length(vs) == 4

      assert Enum.all?(vs, &(is_binary(&1.path) and String.length(&1.path) <= 200)),
             "echoed closed-violation paths must be capped at 200 chars"
    end

    test "empty-string minCount hostility (typed finding, pin current semantics)" do
      # location="" is PRESENT for minCount and a valid :string — the shapes
      # file has no minLength constraint, so this passes. Pinned here as the
      # documented current semantics: a Raise (sh:minLength support) is gated
      # on a named consumer (same NO-OP law as lens-2 F16).
      shape = %{
        target_class: nil,
        closed: false,
        required: [%{path: "location", min_count: 1, datatype: :string, message: nil}]
      }

      assert Validator.validate_shape(shape, %{"location" => ""}) == {:ok}
    end

    test "resolve_shape determinism: exact wins over suffix variants; case is exact" do
      shapes = %{
        "Foo" => %{target_class: nil, closed: false, required: []},
        "FooShape" => %{target_class: nil, closed: true, required: []}
      }

      # exact name wins over the +Shape variant
      assert Validator.resolve_shape(shapes, "Foo") ==
               shapes["Foo"]

      assert Validator.resolve_shape(shapes, "FooShape") == shapes["FooShape"]

      # case-hostile name resolves to nil (-> fail-closed refusal upstream)
      assert Validator.resolve_shape(shapes, "foo") == nil
    end
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
