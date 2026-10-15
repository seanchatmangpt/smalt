defmodule Smalt.GraphLaw.SHACLProjectionTest do
  @moduledoc """
  Courts for the SHACL projection law adopted from
  `shacl-projection-pack` v0.2.0. Real collaborators, no mocks: the
  projections are exercised against real payloads with a tiny stdlib
  JSON-Schema checker, and determinism is asserted on encoded bytes.
  """

  use ExUnit.Case, async: true

  alias Smalt.GraphLaw.SHACLProjection

  @shapes_path Path.expand("../priv/shacl/smalt-shapes.ttl", __DIR__)

  setup_all do
    text = File.read!(@shapes_path)
    parsed = Smalt.GraphLaw.Validator.ShapeFile.parse!(text, "smalt-shapes.ttl")
    %{parsed: parsed}
  end

  # -- tiny stdlib JSON-Schema checker (draft subset used by the projection) ----

  defp check(nil, _payload), do: :ok

  defp check(%{"properties" => _} = schema, payload) when is_map(payload) do
    with :ok <- check_required(Map.get(schema, "required", []), payload),
         :ok <- check_props(Map.get(schema, "properties", %{}), payload) do
      :ok
    end
  end

  # an object schema applied to a non-map payload is a violation — never
  # silently admitted by a catch-all clause
  defp check(%{"properties" => _} = schema, value) do
    case Map.get(schema, "type") do
      nil -> {:error, "expected object, got #{inspect(value)}"}
      _ -> {:error, "expected #{schema["type"]}, got #{inspect(value)}"}
    end
  end

  # field schema without a "type" keyword (smalt's TTL declares no
  # sh:datatype) — description-only, presence-only, any value admitted
  defp check(%{"description" => _}, _value), do: :ok

  defp check(%{"type" => type}, value) do
    ok =
      case type do
        "string" -> is_binary(value)
        "integer" -> is_integer(value)
        "number" -> is_number(value)
        "boolean" -> is_boolean(value)
      end

    if ok, do: :ok, else: {:error, "expected #{type}, got #{inspect(value)}"}
  end

  # unrecognized schema shape: admit explicitly (empty map / no constraints),
  # never via an implicit crash — a future unknown keyword is a conscious
  # extension point here
  defp check(_schema, _value), do: :ok

  defp check_required(required, payload) do
    missing = Enum.reject(required, &Map.has_key?(payload, &1))

    case missing do
      [] -> :ok
      _ -> {:error, "missing required: " <> Enum.join(missing, ", ")}
    end
  end

  defp check_props(props, payload) do
    Enum.reduce_while(props, :ok, fn {key, prop_schema}, :ok ->
      case Map.get(payload, key) do
        nil ->
          {:cont, :ok}

        value ->
          case check(prop_schema, value) do
            :ok -> {:cont, :ok}
            err -> {:halt, err}
          end
      end
    end)
  end

  # -- coverage: doc form covers all shapes --------------------------------------

  describe "projection coverage" do
    test "shapes identity with the admission gate's parsed shapes", %{parsed: parsed} do
      assert SHACLProjection.shapes() == parsed
      assert SHACLProjection.shapes() == Smalt.GraphLaw.Validator.shapes()
    end

    test "markdown doc covers every shape and every property" , %{parsed: parsed} do
      doc = SHACLProjection.docs_markdown()

      assert String.starts_with?(doc, "# SHACL Shape Documentation")

      Enum.each(parsed, fn {name, shape} ->
        assert doc =~ "## #{name}"

        if shape.target_class do
          local = shape.target_class |> String.split(["#", "/"]) |> List.last()
          assert doc =~ "`#{local}`"
        end

        Enum.each(shape.required, fn prop ->
          assert doc =~ "`#{prop.path}`"
        end)
      end)
    end

    test "json schema has a def per shape, keyed by target class", %{parsed: parsed} do
      schema = SHACLProjection.json_schema()

      assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
      defs = schema["$defs"]

      assert MapSet.new(Map.keys(defs)) ==
               MapSet.new(Enum.map(parsed, fn {_n, s} ->
                 s.target_class |> String.split(["#", "/"]) |> List.last()
               end))

      Enum.each(parsed, fn {_name, shape} ->
        class = shape.target_class |> String.split(["#", "/"]) |> List.last()
        def = defs[class]

        assert def["type"] == "object"

        expected_required =
          shape.required |> Enum.filter(&(&1.min_count >= 1)) |> Enum.map(& &1.path) |> Enum.sort()

        assert Enum.sort(def["required"]) == expected_required

        expected_props = shape.required |> Enum.map(& &1.path) |> Enum.sort()
        assert Enum.sort(Map.keys(def["properties"])) == expected_props
      end)
    end
  end

  # -- semantics: checker accepts conforming, rejects violating ------------------

  describe "json-schema semantics via stdlib checker" do
    test "conforming VNet payload validates" do
      vnet = SHACLProjection.json_schema()["$defs"]["VNet"]

      assert check(vnet, %{
               "location" => "eastus",
               "addressPrefixes" => ["10.0.0.0/16"]
             }) == :ok
    end

    test "violating payload (missing required addressPrefixes) is rejected" do
      vnet = SHACLProjection.json_schema()["$defs"]["VNet"]
      assert {:error, msg} = check(vnet, %{"location" => "eastus"})
      assert msg =~ "addressPrefixes"
    end

    test "violating payload (missing location) is rejected for ResourceGroup" do
      rg = SHACLProjection.json_schema()["$defs"]["ResourceGroup"]
      assert {:error, msg} = check(rg, %{})
      assert msg =~ "location"
    end

    test "conforming payload with extra (open-shape) keys validates" do
      vm = SHACLProjection.json_schema()["$defs"]["VirtualMachine"]

      assert check(vm, %{
               "location" => "westus",
               "vmSize" => "Standard_D2s_v3",
               "tags" => %{"env" => "dev"}
             }) == :ok
    end

    test "Nsg (no declared properties) accepts any payload" do
      nsg = SHACLProjection.json_schema()["$defs"]["Nsg"]
      assert check(nsg, %{"anything" => "goes"}) == :ok
    end

    test "description-only property schema admits any present value" do
      # smalt's TTL declares no sh:datatype, so every field schema carries
      # only "description" (the sh:message) — the checker must admit any
      # value for a present field rather than fall through vacuously
      vnet = SHACLProjection.json_schema()["$defs"]["VNet"]
      location_schema = vnet["properties"]["location"]

      refute Map.has_key?(location_schema, "type")
      assert Map.has_key?(location_schema, "description")

      assert check(location_schema, "eastus") == :ok
      assert check(location_schema, 42) == :ok
      assert check(location_schema, %{"nested" => true}) == :ok
    end

    test "object schema applied to a non-map payload is rejected" do
      vnet = SHACLProjection.json_schema()["$defs"]["VNet"]
      assert {:error, msg} = check(vnet, "not-a-map")
      assert msg =~ "expected object"
    end
  end

  # -- determinism -----------------------------------------------------------------

  describe "determinism" do
    test "two json_schema_json runs are byte-identical" do
      run1 = SHACLProjection.json_schema_json()
      run2 = SHACLProjection.json_schema_json()
      assert run1 == run2
      assert String.valid?(run1)
      assert run1 =~ "$defs"
    end

    test "two docs_markdown runs are byte-identical" do
      run1 = SHACLProjection.docs_markdown()
      run2 = SHACLProjection.docs_markdown()
      assert run1 == run2
    end

    test "json_schema_json round-trips through Jason" do
      decoded = SHACLProjection.json_schema_json() |> Jason.decode!()
      assert decoded == SHACLProjection.json_schema()
    end
  end

  describe "shacl-projection-pack law cross-validation (pack read-only)" do
    # Pack gates/010_shape_validity.rq law subset applicable to smalt's
    # presence-only shapes (no sp: consumer vocabulary in smalt's TTL).
    @admitted_xsd ~w(string boolean integer long decimal float double)

    test "every property shape carries a path whose local name is a valid projected identifier" do
      for {shape_name, shape} <- Smalt.GraphLaw.Validator.shapes(),
          prop <- shape.required do
        assert prop.path != nil and prop.path != "",
               "pack law: property shape without sh:path in #{shape_name}"

        assert prop.path =~ ~r/^[a-zA-Z_][a-zA-Z0-9_.]*$/,
               "pack law: path local name #{inspect(prop.path)} in #{shape_name} " <>
                 "is not a valid projected identifier"
      end
    end

    test "no duplicate field names within one shape (pack law)" do
      for {shape_name, shape} <- Smalt.GraphLaw.Validator.shapes() do
        paths = Enum.map(shape.required, & &1.path)

        assert paths -- Enum.uniq(paths) == [],
               "pack law: duplicate field names in #{shape_name}: #{inspect(paths)}"
      end
    end

    test "every declared sh:datatype is in the pack's admitted XSD set" do
      for {shape_name, shape} <- Smalt.GraphLaw.Validator.shapes(),
          prop <- shape.required,
          dt <- List.wrap(prop.datatype) do
        assert Atom.to_string(dt) in @admitted_xsd,
               "pack law: datatype #{inspect(dt)} in #{shape_name} not in the " <>
                 "admitted XSD set #{inspect(@admitted_xsd)}"
      end
    end
  end
end
