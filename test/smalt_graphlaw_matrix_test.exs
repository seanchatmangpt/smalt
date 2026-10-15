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
  # sh:minCount constraints, else :none.
  defp shape_requirements(type, shapes) do
    case Registry.type_shapes()[type] && shapes[Registry.type_shapes()[type]] do
      %{required: required} when is_list(required) and required != [] ->
        {:required, Enum.map(required, & &1.path)}

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
