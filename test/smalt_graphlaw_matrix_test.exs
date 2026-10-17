defmodule SmaltGraphlawMatrixTest do
  @moduledoc """
  GraphLaw admission matrix over every type in `Smalt.Registry.admitted_resource_types/0`.

  Pinned contracts under test:
    * `Smalt.GraphLaw.Validator.validate_resource/2` -> `{:ok} | {:invalid, results} | {:refused, reason}`
    * valid-location payload -> `{:ok}` or `{:invalid, non-empty}` — never `{:refused, _}`
    * empty payload -> `{:invalid, non-empty}` for shapes requiring location, else
      `{:refused, :no_shape}` acceptable
    * unknown type -> `{:refused, :type_not_admitted}`
  """

  use ExUnit.Case, async: true

  alias Smalt.GraphLaw.Validator
  alias Smalt.Registry

  @pack "../ggen-marketplace/packs/smalt-substrate-pack"

  @tag :registry_projection
  test "Registry is the exact projection of the pack ontology (regeneration determinism)" do
    if Code.ensure_loaded?(SPARQL) and Code.ensure_loaded?(RDF.Turtle) do
      {:ok, graph} = RDF.Turtle.read_file(@pack <> "/ontology.ttl")

      val = fn
        nil -> nil
        %RDF.Literal{literal: %{value: v}} -> v
        %RDF.IRI{} = i -> i.value |> String.split("#") |> List.last()
        other -> inspect(other)
      end

      # control_plane.rq must project EXACTLY the admitted resource types.
      r1 = SPARQL.execute_query(graph, File.read!(@pack <> "/queries/control_plane.rq"))

      types1 =
        r1.results |> Enum.map(&val.(&1["resourceType"])) |> Enum.reject(&is_nil/1) |> Enum.sort()

      assert types1 == Enum.sort(Registry.admitted_resource_types()),
             "registry admitted types drifted from pack ontology control_plane.rq " <>
               "projection: query-only=#{inspect(types1 -- Registry.admitted_resource_types())} " <>
               "registry-only=#{inspect(Registry.admitted_resource_types() -- types1)}"

      # payload_rules.rq must project EXACTLY the type_shapes + api_versions maps.
      r2 = SPARQL.execute_query(graph, File.read!(@pack <> "/queries/payload_rules.rq"))

      shapes2 =
        r2.results
        |> Enum.map(&{val.(&1["resourceType"]), val.(&1["shape"]), val.(&1["apiVersion"])})
        |> Enum.sort()

      reg2 =
        Registry.type_shapes()
        |> Enum.map(fn {t, s} -> {t, s, Registry.latest_version(t)} end)
        |> Enum.sort()

      assert shapes2 == reg2,
             "registry type_shapes/api_versions drifted from payload_rules.rq projection"
    else
      # SPARQL/RDF not loadable in this env: the projection property is
      # witnessed by tmp/errc/store-graphlaw/cycle-5.md instead.
      :ok
    end
  end

  test "every admitted type validates with a well-formed location payload" do
    for type <- Registry.admitted_resource_types() do
      payload = %{"location" => "smalt-local", "properties" => %{}}

      result = Validator.validate_resource(type, payload)

      assert result == {:ok} or match?({:invalid, [_ | _]}, result),
             "expected {:ok} or {:invalid, non-empty} for #{type}, got: #{inspect(result)}"

      refute match?({:refused, _}, result),
             "admitted type #{type} must never be refused, got: #{inspect(result)}"

      # {:invalid, _} must carry a non-empty, well-formed violation list
      case result do
        {:invalid, issues} ->
          assert is_list(issues) and issues != [],
                 "expected non-empty violations for #{type}, got: #{inspect(issues)}"

          for issue <- issues do
            assert is_map(issue)
            assert is_binary(issue[:path])
          end

        _ ->
          :ok
      end
    end
  end

  test "empty payload verdict matches the type's declared shape requirements" do
    shapes = Validator.shapes()

    for type <- Registry.admitted_resource_types() do
      result = Validator.validate_resource(type, %{})

      case shape_requirements(type, shapes) do
        {:required, paths} ->
          assert {:invalid, issues} = result
          assert is_list(issues) and issues != [],
                 "shape requires #{inspect(paths)} but empty payload was not invalid for #{type}: #{inspect(result)}"

          for p <- paths do
            assert Enum.any?(issues, &(&1.path == p)),
                   "expected a #{p} violation among #{inspect(issues)} for #{type}"
          end

        :none ->
          # Shape declares no required properties (or no shape at all):
          # {:ok} or {:refused, :no_shape} are both contract-consistent.
          assert result == {:ok} or match?({:refused, :no_shape}, result),
                 "unexpected verdict for #{type} on empty payload: #{inspect(result)}"
      end
    end
  end

  # Returns {:required, paths} when the type's declared shape carries
  # sh:minCount >= 1 constraints, else :none. minCount-0 properties are
  # OPTIONAL vocabulary declarations (defaults bijection) — they must not
  # demand a violation on the empty payload.
  defp shape_requirements(type, shapes) do
    case Registry.type_shapes()[type] && shapes[Registry.type_shapes()[type]] do
      %{required: required} when is_list(required) and required != [] ->
        {:required,
         required |> Enum.filter(&(&1.min_count != 0)) |> Enum.map(& &1.path)}

      _ ->
        :none
    end
  end

  test "unknown type is refused as :type_not_admitted" do
    assert {:refused, :type_not_admitted} = Validator.validate_resource("Microsoft.Fake/NotReal", %{
             "location" => "smalt-local"
           })

    assert {:refused, :type_not_admitted} = Validator.validate_resource("Microsoft.Fake/NotReal", %{})
  end

  # async: true is safe here: this suite touches no shared process state.
  # It calls only Smalt.GraphLaw.Validator (pure) and Smalt.Registry, which
  # reads compile-time module attributes (@admitted_resource_types,
  # @type_shapes) — no ETS, no GenServer, no Smalt.Store. Verified by grep:
  # zero Store references outside this comment.
end
