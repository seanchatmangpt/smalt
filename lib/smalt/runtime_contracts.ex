defmodule Smalt.RuntimeContracts do
  @moduledoc """
  Machine-checkable runtime integration contracts for smalt's planes.

  One contract module per plane asserts, in-process, the invariants the
  compliance courts pinned (`test/compliance/*`, `test/amqp/*`):

    * `Smalt.RuntimeContracts.ArmEnvelope` — control plane, ARM envelope
    * `Smalt.RuntimeContracts.CosmosHeader` — data plane, Cosmos header set
    * `Smalt.RuntimeContracts.AmqpDialect` — messaging plane, AMQP 1.0 dialect

  `verify/0` is the revops structural factory pass: it fans the verdict
  runner over every wired contract and returns one verdict map. Contract
  modules are injectable via `verify/1` for adversarial (mutation-court)
  testing: a deliberately broken contract must fail the verdict.

  Template source: ash-revops-structural-factory-pack +
  ash-runtime-integration-contract-pack (adapted; see
  `docs/PACK_INTEGRATION/runtime-contracts.md`).
  """

  alias Smalt.RuntimeContracts.{AmqpDialect, ArmEnvelope, CosmosHeader, Support}

  @typedoc "Full verdict map from `verify/0`."
  @type verdict :: %{
          pass: boolean(),
          contracts: %{atom() => Support.result()},
          planes: %{atom() => [atom()]},
          contract_count: non_neg_integer(),
          check_count: non_neg_integer(),
          failure_count: non_neg_integer()
        }

  @wired [ArmEnvelope, CosmosHeader, AmqpDialect]

  @doc "Wired contract modules (revops structural factory output)."
  @spec contracts() :: [module()]
  def contracts, do: @wired

  @doc "Runs every wired contract; returns a verdict map."
  @spec verify() :: verdict()
  def verify, do: verify(contracts())

  @doc "Runs the given contract modules (injection point for mutation courts)."
  @spec verify([module()]) :: verdict()
  def verify(contracts) when is_list(contracts) do
    results =
      Map.new(contracts, fn mod ->
        result = run_contract(mod)
        {result.name, result}
      end)

    check_count = results |> Map.values() |> Enum.map(& &1.checks) |> Enum.sum()

    failure_count =
      results |> Map.values() |> Enum.flat_map(& &1.failures) |> length()

    %{
      pass: failure_count == 0 and map_size(results) > 0,
      contracts: results,
      planes:
        results
        |> Map.new(fn {name, _result} ->
          {name, plane_of(contracts, name)}
        end)
        |> group_planes(),
      contract_count: map_size(results),
      check_count: check_count,
      failure_count: failure_count
    }
  end

  defp run_contract(mod) do
    name = name_of(mod)

    result =
      if Code.ensure_loaded(mod) == {:module, mod} and function_exported?(mod, :check, 0) do
        mod.check()
      else
        %{
          name: name,
          pass: false,
          checks: 0,
          failures: [%{check: :contract_not_loaded, detail: "#{inspect(mod)} does not export check/0"}]
        }
      end

    %{result | name: name}
  catch
    kind, reason ->
      %{
        name: name_of(mod),
        pass: false,
        checks: 0,
        failures: [%{check: :contract_crashed, detail: "#{kind}: #{inspect(reason)}"}]
      }
  end

  defp name_of(mod) do
    if Code.ensure_loaded(mod) == {:module, mod} and function_exported?(mod, :name, 0) do
      mod.name()
    else
      contract_name_guess(mod)
    end
  rescue
    _ -> contract_name_guess(mod)
  end

  defp contract_name_guess(mod), do: mod |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom()

  defp plane_of(contracts, name) do
    case Enum.find(contracts, &(&1.name() == name)) do
      nil -> :unknown
      mod -> mod.plane()
    end
  rescue
    _ -> :unknown
  end

  defp group_planes(pairs) do
    Enum.reduce(pairs, %{}, fn {name, plane}, acc ->
      Map.update(acc, plane, [name], fn prev -> [name | prev] end)
    end)
  end
end
