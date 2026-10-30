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
          required(:types) => %{optional(atom()) => type_spec()},
          optional(:shape) => shape_spec()
        }
  @type type_spec :: :string | :integer | :binary | :map | :list | {:one_of, [term()]}

  @typedoc """
  Compiled SHACL-subset shape spec (G32 Option C, lane 44) — projected from
  the pack's ingress.ttl by `Smalt.Posh.Ingress.ShapeValidator.shape_spec/1`:

    * `:closed` — extra payload keys (outside `:allowed`) are refused
    * `:banned` — keys with sh:maxCount 0 (posh:emits on a route) are refused
    * `:class_checks` — key => MapSet of admissible individual local names;
      an EMPTY set refuses every value (fail-closed, never a vacuous pass)
  """
  @type shape_spec :: %{
          optional(:closed) => boolean(),
          optional(:allowed) => MapSet.t(),
          optional(:banned) => MapSet.t(),
          optional(:required) => [atom()],
          optional(:types) => map(),
          optional(:class_checks) => %{optional(atom()) => MapSet.t()}
        }

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
           types: Map.new(spec_key(spec, :types, %{}), fn {k, v} -> {normalize_key(k), v} end),
           shape: spec_key(spec, :shape, nil)
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
    try do
      task = Task.Supervisor.async_nolink(Smalt.Posh.Ingress.TaskSupervisor, fn ->
        validate(policy, route, payload)
      end)

      case Task.await(task, 5_000) do
        {:admitted, _} = ok -> ok
        {:refused, _} = refused -> refused
      end
    rescue
      # TaskSupervisor is not running (default boots carry no
      # `config :smalt, :posh`): the task ISOLATION domain is absent, not
      # the validation — validate inline with the SAME real validator
      # instead of crash-looping into a bogus admission_crash refusal.
      ArgumentError -> validate(policy, route, payload)
      # a crashing validator re-raises its own exception through Task.await
      # (not only :exit) — raises must be contained by the budget too, or a
      # hostile payload crashes the CALLER, defeating let-it-crash containment
      _other_exception -> run_admission(policy, route, payload, attempts_left - 1)
    catch
      # :noproc exit = the isolation supervisor is down (name not
      # registered): inline validation, not a crash-loop.
      :exit, {:noproc, _reason} -> validate(policy, route, payload)

      # Any other exit is a real admission crash: retry within budget.
      :exit, _reason -> run_admission(policy, route, payload, attempts_left - 1)
    end
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

    shape_violations = shape_violations(Map.get(route_policy, :shape), payload)

    case missing ++ type_violations ++ shape_violations do
      [] -> :ok
      violations -> {:violations, violations}
    end
  end

  # -- compiled SHACL-subset shape enforcement (G32 Option C, lane 44) ---------

  defp shape_violations(nil, _payload), do: []

  defp shape_violations(shape, payload) when is_map(payload) do
    ban_violations(shape, payload) ++
      closed_violations(shape, payload) ++
      class_violations(shape, payload)
  end

  # sh:maxCount 0 ban (ingress.ttl Law 2: posh:emits never on a route)
  defp ban_violations(shape, payload) do
    for key <- MapSet.to_list(Map.get(shape, :banned, MapSet.new())),
        key_present?(payload, String.to_atom(key)) do
      %{path: "$.#{key}", issue: "banned_key", constraint: "maxCount"}
    end
  end

  # sh:closed: payload keys outside the shape's declared+ignored vocabulary
  defp closed_violations(shape, payload) do
    if Map.get(shape, :closed, false) do
      allowed = Map.get(shape, :allowed, MapSet.new())

      payload
      |> Map.keys()
      |> Enum.map(&key_string/1)
      |> Enum.reject(&MapSet.member?(allowed, &1))
      |> Enum.map(fn k -> %{path: "$.#{k}", issue: "unknown_key", constraint: "closed"} end)
    else
      []
    end
  end

  # sh:class: present values must name a compiled individual of the class;
  # an empty compiled set refuses every value (fail-closed).
  defp class_violations(shape, payload) do
    for {k, admissible} <- Map.to_list(Map.get(shape, :class_checks, %{})),
        value = payload_value(payload, k),
        value != :__posh_missing__,
        not class_ok?(admissible, value) do
      %{path: "$.#{k}", issue: "class_violation", expected: MapSet.size(admissible)}
    end
  end

  defp class_ok?(admissible, value) when is_binary(value) do
    local = value |> String.split(["#", "/"]) |> List.last()
    MapSet.member?(admissible, local)
  end

  defp class_ok?(_admissible, _value), do: false

  defp key_string(k) when is_binary(k), do: k
  defp key_string(k), do: to_string(k)

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

  # class_checks keys come from shape specs (binary local names); payload
  # lookups need the atom form payload_value/2 expects.
  defp payload_value(payload, k) when is_binary(k), do: payload_value(payload, String.to_atom(k))

  defp payload_value(payload, k) when is_map(payload) do
    cond do
      Map.has_key?(payload, k) -> Map.fetch!(payload, k)
      Map.has_key?(payload, Atom.to_string(k)) -> Map.fetch!(payload, Atom.to_string(k))
      true -> :__posh_missing__
    end
  end
end
