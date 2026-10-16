defmodule Smalt.RuntimeContracts do
  @moduledoc """
  Machine-checkable runtime integration contracts for smalt's planes.

  One contract module per plane asserts, in-process, the invariants the
  compliance courts pinned (`test/compliance/*`, `test/amqp/*`):

    * `Smalt.RuntimeContracts.ArmEnvelope` — control plane, ARM envelope
    * `Smalt.RuntimeContracts.CosmosHeader` — data plane, Cosmos header set
    * `Smalt.RuntimeContracts.AmqpDialect` — messaging plane, AMQP 1.0 dialect
    * `Smalt.RuntimeContracts.SentinelIngest` — data plane, Sentinel / Log Analytics DCR ingest + KQL query
    * `Smalt.RuntimeContracts.ResourceGraphQuery` — control plane, Resource Graph query + `$skipToken` pagination
    * `Smalt.RuntimeContracts.PurviewAtlas` — data plane, Purview Catalog (Atlas v2) entities + lineage

  `verify/0` is the revops structural factory pass: it fans the verdict
  runner over every wired contract and returns one verdict map. Contract
  modules are injectable via `verify/1` for adversarial (mutation-court)
  testing: a deliberately broken contract must fail the verdict.

  Template source: ash-revops-structural-factory-pack +
  ash-runtime-integration-contract-pack (adapted; see
  `docs/PACK_INTEGRATION/runtime-contracts.md`).
  """

  alias Smalt.RuntimeContracts.{AmqpDialect, ArmEnvelope, CosmosHeader, PurviewAtlas, ResourceGraphQuery, SentinelIngest, Support}

  @typedoc "Full verdict map from `verify/0`."
  @type verdict :: %{
          pass: boolean(),
          contracts: %{atom() => Support.result()},
          planes: %{atom() => [atom()]},
          contract_count: non_neg_integer(),
          check_count: non_neg_integer(),
          failure_count: non_neg_integer()
        }

  @wired [ArmEnvelope, CosmosHeader, AmqpDialect, SentinelIngest, ResourceGraphQuery, PurviewAtlas]

  @doc "Wired contract modules (revops structural factory output)."
  @spec contracts() :: [module()]
  def contracts, do: @wired

  @doc "Runs every wired contract; returns a verdict map."
  @spec verify() :: verdict()
  def verify, do: verify(contracts())

  @doc """
  Runs the given contract entries (injection point for mutation courts).
  Accepts any term: a non-module entry, a module without check/0, a crashing
  check/0, a malformed verdict, or a duplicate gate id each yield a typed
  registry failure (`:contract_not_loaded`, `:contract_crashed`,
  `:contract_malformed_verdict`, `:contract_name_collision`) — never a crash
  of the fan-out and never a silent shadow (fail closed).
  """
  @spec verify([term()]) :: verdict()
  def verify(contracts) when is_list(contracts) do
    # Verdict-shape guard FIRST: a contract returning a malformed verdict
    # (non-numeric checks, non-list failures, non-map failure entries,
    # non-boolean pass) is coerced to a typed registry failure before any
    # downstream aggregation or collision marking touches it. Running the
    # collision append on the RAW verdict crashed verify/1 with an
    # ArgumentError when a duplicate-id contract returned failures as a
    # non-list (witnessed lens-3 cycle 2: `"oops" ++ [...]`).
    results =
      contracts
      |> Enum.map(&(&1 |> run_contract() |> coerce_verdict()))
      |> Enum.reduce(%{}, fn result, acc ->
        # Name-collision guard: a later contract reusing an earlier gate id
        # must FAIL the registry, never silently shadow it (lens-2 cycle 1).
        # FIRST occurrence is kept in the map; each duplicate appends its
        # collision marker to the survivor's failures, so neither the first
        # contract's own typed failures nor the collision evidence is lost.
        Map.update(acc, result.name, result, fn first ->
          %{
            first
            | pass: false,
              failures:
                first.failures ++
                  [
                    %{
                      check: :contract_name_collision,
                      detail:
                        "gate id #{inspect(result.name)} already used by an earlier contract in this verify run"
                    }
                  ]
          }
        end)
      end)

    # Plane-typed guard: plane/0 returning a non-atom silently flowed into the
    # planes map as a string-keyed group — violating the documented
    # %{atom() => [atom()]} type — while the verdict still PASSED (witnessed
    # lens 4: plane/0 -> "not-an-atom" gave pass=true, planes keyed by binary).
    # The typed guard fails the registry instead: each malformed plane appends
    # a contract_malformed_plane failure and the contract is grouped under the
    # :contract_malformed_plane marker plane, never silently.
    {results, plane_pairs} =
      Enum.flat_map_reduce(results, [], fn {name, result}, acc ->
        case plane_of(contracts, name) do
          {:ok, plane} ->
            {[{name, result}], [{name, plane} | acc]}

          {:error, bad_plane} ->
            {[{name,
               %{
                 result
                 | pass: false,
                   failures:
                     result.failures ++
                       [
                         %{
                           check: :contract_malformed_plane,
                           detail:
                             "plane/0 returned a non-atom (#{inspect(bad_plane)}); planes is typed %{atom() => [atom()]}"
                         }
                       ]
             }}], [{name, :contract_malformed_plane} | acc]}
        end
      end)

    results = Map.new(results)

    # Name-typed guard (lens 5, sibling of the plane guard): name/0 is typed
    # `atom()` (Smalt.RuntimeContracts.Contract behaviour), but a binary or
    # other term was SILENTLY substituted by the module-name guess while the
    # verdict stayed pass=true — a documented-type violation flowing through
    # unflagged, and collision detection silently keying the wrong name.
    # Fail closed: append contract_malformed_name and fail the contract.
    {results, _} =
      Enum.flat_map_reduce(results, [], fn {name, result}, acc ->
        case typed_name(contracts, name) do
          {:ok, _atom} ->
            {[{name, result}], acc}

          {:error, bad_name} ->
            {[{name,
               %{
                 result
                 | pass: false,
                   failures:
                     result.failures ++
                       [
                         %{
                           check: :contract_malformed_name,
                           detail:
                             "name/0 returned a non-atom (#{inspect(bad_name)}); the contract behaviour types name/0 as atom()"
                         }
                       ]
               }}], acc}
        end
      end)

    results = Map.new(results)

    check_count = results |> Map.values() |> Enum.map(& &1.checks) |> Enum.sum()

    failure_count =
      results |> Map.values() |> Enum.flat_map(& &1.failures) |> length()

    %{
      pass: failure_count == 0 and map_size(results) > 0,
      contracts: results,
      planes: group_planes(plane_pairs),
      contract_count: map_size(results),
      check_count: check_count,
      failure_count: failure_count
    }
  end

  defp coerce_verdict(%{checks: checks, failures: failures} = result)
       when is_integer(checks) and checks >= 0 and is_list(failures) do
    # lens-3 boundary: the verdict's own pass flag must be a real boolean and
    # every failure entry a map with a check id — a string "pass" or a bare
    # atom failure flows past a bare is_list guard and poisons the contracts
    # map (non-map entries crash downstream .check readers; the contract-level
    # pass stays true while the registry fails — inconsistent verdict).
    if is_boolean(result.pass) and Enum.all?(failures, &valid_failure?/1) do
      result
    else
      malformed_verdict(result)
    end
  end

  defp coerce_verdict(result), do: malformed_verdict(result)

  defp valid_failure?(%{check: check, detail: detail}) when is_atom(check) and is_binary(detail),
    do: true

  defp valid_failure?(_), do: false

  defp malformed_verdict(result) do
    %{
      name: result.name,
      pass: false,
      checks: 0,
      failures: [
        %{
          check: :contract_malformed_verdict,
          detail:
            "check/0 returned a malformed verdict (checks must be a non-negative integer, failures a list of %{check: atom, detail: binary} maps, pass a boolean): #{inspect(result)}"
        }
      ]
    }
  end

  defp run_contract(entry) do
    name = name_of(entry)
    mod = entry

    result =
      if is_atom(mod) and Code.ensure_loaded(mod) == {:module, mod} and
           function_exported?(mod, :check, 0) do
        mod.check()
      else
        %{
          name: name,
          pass: false,
          checks: 0,
          failures: [
            %{check: :contract_not_loaded, detail: "#{inspect(mod)} does not export check/0"}
          ]
        }
      end

    %{result | name: name}
  catch
    kind, reason ->
      %{
        name: name_of(entry),
        pass: false,
        checks: 0,
        failures: [%{check: :contract_crashed, detail: "#{kind}: #{inspect(reason)}"}]
      }
  end

  defp name_of(entry) when is_atom(entry) do
    if Code.ensure_loaded(entry) == {:module, entry} and function_exported?(entry, :name, 0) do
      case entry.name() do
        name when is_atom(name) -> name
        other -> contract_name_guess(entry, other)
      end
    else
      contract_name_guess(entry)
    end
  rescue
    _ -> contract_name_guess(entry)
  end

  defp name_of(entry), do: contract_name_guess(entry, entry)

  defp contract_name_guess(entry),
    do: contract_name_guess(entry, entry)

  defp contract_name_guess(entry, _bad_name) when is_atom(entry) do
    entry
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  rescue
    _ -> String.to_atom(inspect(entry))
  end

  defp contract_name_guess(entry, _bad_name), do: String.to_atom(inspect(entry))

  # Mirrors plane_of/2: resolve the contract's declared name/0 and report a
  # typed error when it violates its atom() type. Missing name/0, a raising
  # name/0, or a non-module entry resolve via the guess (unchanged behavior —
  # those are already typed by name_of/1's fallback, not silent type breaks).
  defp typed_name(contracts, name) do
    case Enum.find(contracts, &is_atom(&1) and name_of(&1) == name) do
      nil ->
        {:ok, name}

      mod ->
        case mod.name() do
          n when is_atom(n) -> {:ok, n}
          other -> {:error, other}
        end
    end
  rescue
    _ -> {:ok, name}
  end

  # Resolve by the SAME guessed key name_of/1 keys the registry with — a
  # contract whose name/0 returns a non-atom still reaches its plane/0 here,
  # so a malformed plane is typed contract_malformed_plane even when the name
  # is malformed too (lens-6: resolving by raw name/0 masked the plane marker
  # behind contract_malformed_name — the plane violation resolved :unknown).
  defp plane_of(contracts, name) do
    case Enum.find(contracts, &name_of(&1) == name) do
      nil -> {:ok, :unknown}
      mod ->
        case mod.plane() do
          plane when is_atom(plane) -> {:ok, plane}
          other -> {:error, other}
        end
    end
  rescue
    _ -> {:ok, :unknown}
  end

  defp group_planes(pairs) do
    Enum.reduce(pairs, %{}, fn {name, plane}, acc ->
      Map.update(acc, plane, [name], fn prev -> [name | prev] end)
    end)
  end
end
