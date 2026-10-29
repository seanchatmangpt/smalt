defmodule Smalt.Egress.LatencyPlug do
  @moduledoc """
  Config-gated added latency for the egress listener (latency-realism lane).

  Wraps `Smalt.EgressRouter` on the data-plane Bandit listener. When the
  gate is OFF (default: no `:latency` application env and no
  `SMALT_LATENCY_*` env vars) the plug costs ONE `Application.get_env/2`
  call and then delegates straight to the router — no clock reads, no RNG,
  no sleeps. The config-off court fences this path at <= 1.5x baseline.

  When the gate is ON, each request samples a delay from a two-point
  distribution described by `:p50_ms` and `:p99_ms`: the injected RNG draw
  lands on `p50_ms` with probability 0.99 and on `p99_ms` otherwise —
  the tail is exercisable deterministically in tests by pinning the RNG.
  The delay is applied as one `Process.sleep/1` in the connection process
  (the handler genuinely models a real-world network interval).

  ## Configuration

  Resolution order (first match wins):

    1. `config :smalt, :latency, [p50_ms: n, p99_ms: n, planes: %{}, rng: fun]`
       — a keyword list. `:planes` maps a plane key to its own
       `[p50_ms:, p99_ms:]`; `:_` is the catch-all plane.

  ### ARM control-plane route classes (AZURE-FIDELITY lane 18)

  ARM-shaped paths (`/subscriptions/...`, `/providers/...`) do not key on the
  first path segment; they classify into ROUTE CLASSES:

    * `"deployments"` — `*/providers/Microsoft.Resources/deployments*`
      (deployment PUT / status-poll; real Azure is slow here: p99 ~800ms)
    * `"graph"` — `POST /providers/Microsoft.ResourceGraph/resources`
      (graph queries; p99 ~150ms)
    * `"cost"` — `*/providers/Microsoft.CostManagement/query`
      (cost queries; p99 ~400ms)

  A class absent from the configured `:planes` map falls back to the built-in
  default profile (deployments 250/800, graph 60/150, cost 150/400), so arming
  the gate alone buys realistic control-plane latency. The built-in profile
  never arms the gate by itself — `:latency` staying `:off` keeps every path
  undelayed.
    2. `SMALT_LATENCY_P50_MS` / `SMALT_LATENCY_P99_MS` env vars.
    3. OFF.

  `:rng` is an injectable zero-arity fun returning a float in [0.0, 1.0)
  (deterministic tests pin it); default is `:rand.uniform/0`.

  ## Example

      config :smalt, :latency,
        p50_ms: 120,
        p99_ms: 800,
        planes: %{"keys" => [p50_ms: 800, p99_ms: 1600]}
  """

  @behaviour Plug

  @tail_probability 0.99

  # AZURE-FIDELITY lane 18: built-in per-route-class profile for the ARM
  # control plane (deployment PUT/status-poll p99 ~800ms, graph ~150ms,
  # cost ~400ms). Applied to ARM route classes missing from the configured
  # `:planes` map; never arms the gate by itself.
  @arm_default_profile %{
    "deployments" => [p50_ms: 250, p99_ms: 800],
    "graph" => [p50_ms: 60, p99_ms: 150],
    "cost" => [p50_ms: 150, p99_ms: 400]
  }

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    case resolve() do
      :off ->
        # Gate-off fast path: single get_env, zero clock/RNG/sleep work.
        router(opts).call(conn, [])

      cfg ->
        plane = plane_of(conn.request_path)
        delay_ms = delay_ms(plane, cfg)

        if delay_ms > 0 do
          # SLEEP-CLASS: SCHEDULING — the process genuinely has nothing to do
          # until the modeled network interval elapses; this IS the feature.
          Process.sleep(delay_ms)
        end

        router(opts).call(conn, [])
    end
  end

  # The wrapped router: the egress router by default, the ARM gateway when the
  # plug fronts the control-plane listener (`{LatencyPlug, router: Mod}`).
  defp router(opts), do: opts[:router] || Smalt.EgressRouter

  @doc """
  Samples the delay in ms for `plane` (first path segment or `:_`) from `cfg`.
  Two-point distribution: `p50_ms` with probability 0.99, `p99_ms` otherwise.
  """
  def delay_ms(plane, cfg) when is_map(cfg) do
    {p50, p99} = bounds(plane, cfg)
    rng = Map.get(cfg, :rng) || (&:rand.uniform/0)

    if rng.() < @tail_probability do
      p50
    else
      p99
    end
  end

  defp bounds(plane, cfg) do
    case Map.get(cfg, :planes) || %{} do
      planes when map_size(planes) > 0 ->
        case Map.get(planes, plane) do
          kw when is_list(kw) ->
            {kw[:p50_ms] || 0, kw[:p99_ms] || 0}

          _ ->
            arm_fallback(plane, cfg)
        end

      _ ->
        arm_fallback(plane, cfg)
    end
  end

  # An ARM route class with no explicit entry gets the built-in class profile;
  # everything else falls back to the top-level p50/p99 (unchanged behavior).
  defp arm_fallback(plane, cfg) do
    case Map.get(@arm_default_profile, plane) do
      kw when is_list(kw) -> {kw[:p50_ms], kw[:p99_ms]}
      _ -> {cfg[:p50_ms] || 0, cfg[:p99_ms] || 0}
    end
  end

  @doc """
  Plane key for a request path: the first path segment, or `:_` — except
  ARM-shaped paths (`/subscriptions/...`, `/providers/...`), which key on the
  control-plane route class ("deployments", "graph", "cost").
  """
  def plane_of(path) when is_binary(path) do
    case String.split(path, "/", parts: 3) do
      ["", "" | _] ->
        :_

      ["", seg | _] when seg in ["subscriptions", "providers"] ->
        arm_class(path)

      ["", plane | _] ->
        plane

      _ ->
        :_
    end
  end

  defp arm_class(path) do
    cond do
      String.contains?(path, "Microsoft.ResourceGraph") -> "graph"
      String.contains?(path, "Microsoft.CostManagement") -> "cost"
      String.contains?(path, "Microsoft.Resources/deployments") -> "deployments"
      true -> :_
    end
  end

  defp resolve do
    case Application.get_env(:smalt, :latency) do
      :off ->
        :off

      kw when is_list(kw) ->
        cfg = Map.new(kw)
        if any_delay?(cfg), do: cfg, else: :off

      _ ->
        env_cfg()
    end
  end

  defp env_cfg do
    p50 = env_int("SMALT_LATENCY_P50_MS")
    p99 = env_int("SMALT_LATENCY_P99_MS")

    if p50 + p99 > 0 do
      %{p50_ms: p50, p99_ms: p99}
    else
      :off
    end
  end

  defp env_int(name) do
    case System.get_env(name) do
      nil -> 0
      "" -> 0
      str -> String.to_integer(String.trim(str))
    end
  end

  defp any_delay?(cfg) do
    cfg[:p50_ms] not in [nil, 0] or cfg[:p99_ms] not in [nil, 0] or
      ((planes = cfg[:planes]) && map_size(planes) > 0 &&
         Enum.any?(planes, fn {_p, kw} -> kw[:p50_ms] not in [nil, 0] end))
  end
end
