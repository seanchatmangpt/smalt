defmodule Smalt.Posh.Ingress.Admission do
  @moduledoc """
  Port In admission (POSH-002). Fail-closed route+payload validation against a
  policy compiled from a plain map. v1 policy is map-compiled; SHACL shapes
  arrive later from the ggen pack.

  Let-it-crash: `validate_task/2` runs admission in a spawned Task with a
  restart budget; admission never nurses corrupt state — a crashing validator
  crashes the task, is restarted within budget, and the caller gets a typed
  result.
  """

  defstruct routes: %{}, __meta__: :v1

  @type t :: %__MODULE__{routes: %{optional(term()) => route_policy()}, __meta__: :v1}
  @type route_policy :: %{
          required(:required_keys) => [atom()],
          required(:types) => %{optional(atom()) => type_spec()}
        }
  @type type_spec :: :string | :integer | :binary | :map | :list | {:one_of, [term()]}

  @doc """
  Compiles a policy from a plain map:

      Admission.compile(%{
        "arm/read" => %{required: [:path], types: %{path: :string}}
      })

  Unknown route at validate time is a refusal, not an error.
  """
  @spec compile(map()) :: t()
  def compile(policy_map) when is_map(policy_map) do
    routes =
      Map.new(policy_map, fn {route, spec} ->
        {route,
         %{
           required_keys: Enum.map(spec_key(spec, :required, []), &normalize_key/1),
           types: Map.new(spec_key(spec, :types, %{}), fn {k, v} -> {normalize_key(k), v} end)
         }}
      end)

    %__MODULE__{routes: routes}
  end

  @doc """
  Validates `(route, payload_map)` against the policy. Fail-closed:

      {:admitted, delta}
      {:refused, :no_admission_policy}
      {:refused, {:shape_violation, details}}
  """
  @spec validate(t(), term(), map()) ::
          {:admitted, map()} | {:refused, :no_admission_policy} | {:refused, {:shape_violation, map()}}
  def validate(policy, route, payload) do
    case Map.fetch(policy.routes, route) do
      :error ->
        {:refused, :no_admission_policy}

      {:ok, route_policy} ->
        case check_shape(route_policy, payload) do
          :ok -> {:admitted, delta_for(route, payload)}
          {:violations, violations} -> {:refused, {:shape_violation, %{violations: violations}}}
        end
    end
  end

  @doc """
  Let-it-crash admission: runs `validate/3` in a spawned Task with a restart
  budget. If the admission computation crashes, it is retried up to `:max_restarts`
  (default 2) times; exhaustion returns a typed refusal rather than a raised
  error in the caller.
  """
  @spec validate_task(t(), term(), map(), keyword()) ::
          {:admitted, map()}
          | {:refused, :no_admission_policy | {:shape_violation, map()} | {:admission_crash, term()}}
  def validate_task(policy, route, payload, opts \\ []) do
    max_restarts = Keyword.get(opts, :max_restarts, 2)

    run_admission(policy, route, payload, max_restarts)
  end

  defp run_admission(_policy, _route, _payload, attempts_left) when attempts_left < 0 do
    {:refused, {:admission_crash, :restart_budget_exhausted}}
  end

  defp run_admission(policy, route, payload, attempts_left) do
    task = Task.Supervisor.async_nolink(Smalt.Posh.Ingress.TaskSupervisor, fn ->
      validate(policy, route, payload)
    end)

    case Task.await(task, 5_000) do
      {:admitted, _} = ok -> ok
      {:refused, _} = refused -> refused
    end
  catch
    :exit, _reason -> run_admission(policy, route, payload, attempts_left - 1)
  end

  defp check_shape(_route_policy, payload) when not is_map(payload) do
    {:violations, [%{path: "$", issue: "payload_not_map"}]}
  end

  defp check_shape(route_policy, payload) do
    missing =
      for k <- route_policy.required_keys,
          not key_present?(payload, k),
          do: %{path: "$.#{k}", issue: "missing_required_key"}

    type_violations =
      for {k, spec} <- Map.to_list(route_policy.types),
          value = payload_value(payload, k),
          value != :__posh_missing__,
          not type_ok?(spec, value),
          do: %{path: "$.#{k}", issue: "type_violation", expected: inspect(spec)}

    case missing ++ type_violations do
      [] -> :ok
      violations -> {:violations, violations}
    end
  end

  defp type_ok?(:string, v), do: is_binary(v)
  defp type_ok?(:integer, v), do: is_integer(v)
  defp type_ok?(:binary, v), do: is_binary(v)
  defp type_ok?(:map, v), do: is_map(v)
  defp type_ok?(:list, v), do: is_list(v)
  defp type_ok?({:one_of, values}, v), do: v in values
  defp type_ok?(_, _), do: true

  defp delta_for(route, payload), do: %{route: route, payload: payload}

  defp normalize_key(k) when is_atom(k), do: k
  defp normalize_key(k) when is_binary(k), do: String.to_atom(k)

  defp spec_key(spec, key, default) when is_map(spec), do: Map.get(spec, key, default)
  defp spec_key(spec, key, default) when is_list(spec), do: Keyword.get(spec, key, default)

  # JSON-shaped payloads carry string keys; policy keys are atoms.
  defp key_present?(payload, k), do: payload_value(payload, k) != :__posh_missing__

  defp payload_value(payload, k) when is_map(payload) do
    cond do
      Map.has_key?(payload, k) -> Map.fetch!(payload, k)
      Map.has_key?(payload, Atom.to_string(k)) -> Map.fetch!(payload, Atom.to_string(k))
      true -> :__posh_missing__
    end
  end
end
