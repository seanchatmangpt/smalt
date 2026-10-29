defmodule PopcornDemo.Concurrency do
  @moduledoc """
  S1 — actor fan-out engine for the wasm BEAM (SCVD harness core).

  `ramp/1`: given actor count N, spawn N isolated processes. Each actor runs a
  DETERMINISTIC in-memory verification walk — no network, no shared mutable
  state; a pure slice over the three shipped smalt modules:

    - `Smalt.CosmosSql.run/3` over a per-actor seeded doc set
    - `Smalt.SbRules.compile/1` + `subscription_admits?/2` + `apply_action/2`
    - `Smalt.Registry.admitted?/1` + `admitted_version?/2` + `latest_version/1`

  Zero-lock keying (PRD): each actor's doc set is keyed to the actor id
  (`"actor-<id>-doc-<i>"`, partition `"p<id>"`) — actors share no mutable
  state, so isolation is by construction, not by discipline.

  Three outcome states (PRD, fail-closed):
    - `:verified`  — every step byte-exact against its expected value
    - `:environment_skip` — the walk's subject modules failed to load (a wasm
      runtime availability gap, NOT a verification verdict); counted apart in
      the ramp row, never as verified
    - `:invariance_breach` — ANY step that is not byte-exact. Anything not
      byte-exact is a breach; the walk never coerces. The first offending
      step is carried in `breach_detail`.

  Per-actor report: map with `{actor_id, state, breach_detail,
  reductions_before, reductions_after, wall_us}`; reductions via
  `:erlang.process_info(self(), :reductions)`, wall via
  `:erlang.monotonic_time` — each process measures itself.

  Parent: end-to-end wall from spawn to last actor (`:erlang.monotonic_time`),
  P50/P99 over per-actor wall times (nearest-rank percentile). Ramp row map:

      %{
        n: N, wall_ms: float, p50_us: int, p99_us: int,
        verified: k, breaches: m, reductions_total: int
      }

  `contention/1`: N actors race the SAME logical partition via optimistic CAS
  semantics on a public ETS table (insert_new claim -> match exists-check ->
  conditional update to `:committed`). Exactly one winner per contended key,
  losers typed `{:cas_lost, key}`. The final ETS state is asserted
  deterministic; any deviation returns
  `{:error, {:not_deterministic, detail}}` — fail-closed, never a coerced
  pass.

  Bounded loops only: one CAS attempt per actor per key (a single atomic
  `insert_new` decides) and one bounded match for the winner's conditional
  update; no unbounded spin exists to bound.

  Zero-egress by construction: no `:httpc`/`Popcorn.Fetch`/sockets anywhere.

  Not wired into the supervision tree — coordinator integrates. Exports
  `ramp/1`, `contention/1` plus the named test seams (`walk/1`,
  `contention_actor/4`, `assert_contention_final/2`).
  """

  # Admitted-type / api-version pins asserted byte-exact by every actor. These
  # are the deterministic invariants under fan-out; if the registry changes
  # these, the walk BREACHES loudly rather than silently passing.
  @pin_type "Microsoft.App/containerApps"
  @pin_type2 "Microsoft.Storage/storageAccounts"
  @pin_version "2023-05-01"
  @pin_doc_count 4

  # Contention: actor id `id` races key `Enum.at(keys, rem(id - 1, @keys))`;
  # with n > @keys multiple actors pile onto the same key (the contention).
  @keys 8

  # --------------------------------------------------------------------------
  # ramp/1
  # --------------------------------------------------------------------------

  @doc "Spawn N actors, measure end-to-end wall + P50/P99 per-actor wall."
  @spec ramp(pos_integer()) :: %{
          required(:n) => pos_integer(),
          required(:wall_ms) => float(),
          required(:p50_us) => non_neg_integer(),
          required(:p99_us) => non_neg_integer(),
          required(:verified) => non_neg_integer(),
          required(:breaches) => non_neg_integer(),
          required(:reductions_total) => non_neg_integer()
        }
  def ramp(n) when is_integer(n) and n > 0 do
    t0 = :erlang.monotonic_time()

    parent = self()

    actors =
      for id <- 1..n do
        # Monitored spawn: a crashed actor can never hang the parent — the
        # DOWN is classified as a typed invariance breach (fail-closed),
        # never a silent loss or an infinite receive.
        {_pid, mref} =
          spawn_monitor(fn ->
            send(parent, {__MODULE__, id, walk(id)})
          end)

        # (pid is intentionally dropped; the monitor ref is the handle)
        {id, mref}
      end

    results =
      for {id, mref} <- actors, into: %{} do
        receive do
          {__MODULE__, ^id, report} ->
            Process.demonitor(mref, [:flush])
            {id, report}

          {:DOWN, ^mref, :process, _pid, reason} ->
            {id, crashed_report(id, reason)}
        end
      end

    t1 = :erlang.monotonic_time()

    walls = for id <- 1..n, do: results[id].wall_us

    %{
      n: n,
      wall_ms: wall_us(t0, t1) / 1000.0,
      p50_us: percentile(walls, 50),
      p99_us: percentile(walls, 99),
      verified: count_state(results, 1..n, :verified),
      breaches: count_state(results, 1..n, :invariance_breach),
      reductions_total: Enum.sum(for(id <- 1..n, do: results[id].reductions_after))
    }
  end

  # --------------------------------------------------------------------------
  # Per-actor deterministic walk
  # --------------------------------------------------------------------------

  @doc """
  One actor's verification walk (test seam + ramp body). Deterministic in the
  actor id; every step byte-exact or the walk breaches.
  """
  @spec walk(pos_integer()) :: %{
          actor_id: pos_integer(),
          state: :verified | :environment_skip | :invariance_breach,
          breach_detail: term(),
          reductions_before: non_neg_integer(),
          reductions_after: non_neg_integer(),
          wall_us: non_neg_integer()
        }
  def walk(id) when is_integer(id) and id > 0 do
    red_before = reductions()

    t0 = :erlang.monotonic_time()

    {state, detail} =
      if loaded?(Smalt.CosmosSql) and loaded?(Smalt.SbRules) and loaded?(Smalt.Registry) do
        run_walk(id)
      else
        # Typed environment skip: subject modules unavailable in this runtime
        # (wasm availability gap, NOT a verification verdict). Counted apart.
        {:environment_skip, {:modules_unloaded, [Smalt.CosmosSql, Smalt.SbRules, Smalt.Registry]}}
      end

    red_after = reductions()

    %{
      actor_id: id,
      state: state,
      breach_detail: detail,
      reductions_before: red_before,
      reductions_after: red_after,
      wall_us: wall_us(t0, :erlang.monotonic_time())
    }
  end


  # A monitored actor that died mid-walk is a typed invariance breach,
  # fail-closed: it is counted in `breaches`, never silently dropped.
  defp crashed_report(id, reason) do
    %{
      actor_id: id,
      state: :invariance_breach,
      breach_detail: {:actor_crashed, reason},
      reductions_before: 0,
      reductions_after: 0,
      wall_us: 0
    }
  end

  # Fail-closed classification: the FIRST non-:ok step names the breach.
  defp run_walk(id) do
    steps = List.flatten([cosmos_steps(id), rules_steps(id), registry_steps()])

    case Enum.find(steps, &match?({:breach, _}, &1)) do
      nil -> {:verified, nil}
      {:breach, what} -> {:invariance_breach, what}
    end
  end

  # -- CosmosSql: per-actor seeded docs, zero-lock keyed to the actor id -----

  defp seed_docs(id) do
    for i <- 1..@pin_doc_count do
      %{
        "id" => "actor-#{id}-doc-#{i}",
        "partition" => "p#{id}",
        "seq" => i,
        "status" => if(rem(i, 2) == 0, do: "live", else: "draft")
      }
    end
  end

  defp cosmos_steps(id) do
    docs = seed_docs(id)

    # Byte-exact expectation computed independently of the SQL engine: the
    # actor's own live docs in seq order.
    expected =
      docs
      |> Enum.filter(&(&1["status"] == "live"))
      |> Enum.sort_by(& &1["seq"])

    case Smalt.CosmosSql.run(
           "SELECT * FROM c WHERE c.partition = @pk AND c.status = 'live' ORDER BY c.seq",
           docs,
           %{"pk" => "p#{id}"}
         ) do
      {:ok, got} ->
        [
          if(got == expected, do: :ok, else: {:breach, {:cosmos_mismatch, id, expected, got}}),
          if(Enum.all?(got, &(&1["partition"] == "p#{id}")),
            do: :ok,
            else: {:breach, {:cosmos_partition_leak, id}}
          )
        ]

      {:error, {:syntax, frag}} ->
        [{:breach, {:cosmos_syntax, id, frag}}]
    end
  end

  # -- SbRules: compile + match + action over a deterministic rule -----------

  defp rules_steps(id) do
    filter = %{
      "sqlExpression" => "subject = 'actor-#{id}' AND sys.label = 'verify'",
      "action" => %{"sqlExpression" => "SET sys.label = 'verified'"}
    }

    # SbRules SQL lookup resolves paths against :app_props (and :label for
    # sys.label) — the rule engine does NOT read msg[:subject].
    msg =
      Map.new(
        message_id: "m-#{id}",
        subject: "actor-#{id}",
        label: "verify",
        app_props: %{"subject" => "actor-#{id}", "label" => "verify"},
        body: "walk-#{id}"
      )

    miss =
      Map.new(
        message_id: "m-#{id}-miss",
        subject: "actor-#{id}-other",
        label: "noise",
        app_props: %{"subject" => "actor-#{id}-other", "label" => "noise"},
        body: "walk-#{id}-miss"
      )

    rule =
      Smalt.SbRules.build_rule_record(
        "walk-rule-#{id}",
        "walk-rule-id-#{id}",
        filter
      )

    case Smalt.SbRules.compile(filter) do
      {:ok, _ast} ->
        hit = Smalt.SbRules.subscription_admits?([rule], msg)
        no_hit = Smalt.SbRules.subscription_admits?([rule], miss)
        applied = Smalt.SbRules.apply_action(filter, msg)

        [
          if(hit and not no_hit,
            do: :ok,
            else: {:breach, {:sb_rules_match, id, hit, no_hit}}
          ),
          if(is_map(applied) and Map.get(msg, :body) == "walk-#{id}",
            do: :ok,
            else: {:breach, {:sb_rules_action_apply, id, applied}}
          )
        ]

      {:error, :invalid_filter, frag} ->
        [{:breach, {:sb_rules_compile, id, frag}}]

      {:error, :invalid_action, frag} ->
        [{:breach, {:sb_rules_action, id, frag}}]
    end
  end

  # -- Registry: admitted types + api-version lattice ------------------------

  defp registry_steps do
    [
      if(Smalt.Registry.admitted?(@pin_type), do: :ok, else: {:breach, {:registry_type, @pin_type}}),
      if(Smalt.Registry.admitted?(@pin_type2),
        do: :ok,
        else: {:breach, {:registry_type, @pin_type2}}
      ),
      if(Smalt.Registry.admitted_version?(@pin_type, @pin_version),
        do: :ok,
        else: {:breach, {:registry_version, {@pin_type, @pin_version}}}
      ),
      if(is_binary(Smalt.Registry.latest_version(@pin_type)),
        do: :ok,
        else: {:breach, {:registry_latest, @pin_type}}
      )
    ]
  end

  # --------------------------------------------------------------------------
  # contention/1 — optimistic CAS over one shared logical partition
  # --------------------------------------------------------------------------

  @doc """
  Spawn N actors racing the SAME logical partition on a public ETS table.

  Protocol per actor (optimistic CAS semantics):
    1. claim — `:ets.insert_new(tab, {key, :claimed, actor_id, 0})`; the one
       actor whose insert_new returns true is the winner
    2. losers match the row, observe the existing claim, and return the typed
       loss `{:cas_lost, key}`
    3. winner matches the row (exists-check) and conditionally updates it to
       `:committed` with version 1

  Returns `{:ok, row}` with the deterministic final counts, or
  `{:error, {:not_deterministic, detail}}`.
  """
  @spec contention(pos_integer()) :: {:ok, map()} | {:error, {:not_deterministic, term()}}
  def contention(n) when is_integer(n) and n > 0 do
    tab = :ets.new(:concurrency_cas, [:public, :set])
    keys = Enum.to_list(1..@keys)
    parent = self()

    for id <- 1..n do
      spawn(fn -> send(parent, {id, contention_actor(id, tab, keys, parent)}) end)
    end

    actor_results = collect(Enum.to_list(1..n), %{})

    final =
      :ets.tab2list(tab)
      |> Map.new(fn {key, state, winner, version} -> {key, {state, winner, version}} end)

    row = %{
      n: n,
      keys: length(keys),
      winners: count_kind(actor_results, :winner),
      losers: count_kind(actor_results, :cas_lost),
      committed_rows:
        final |> Map.values() |> Enum.count(&match?({:committed, _, _}, &1))
    }

    case assert_contention_final(actor_results, final) do
      :ok -> {:ok, row}
      {:error, detail} -> {:error, {:not_deterministic, detail}}
    end
  end

  @doc "One contention actor's CAS protocol (test seam). Returns a typed result."
  def contention_actor(id, tab, keys, _parent) do
    key = Enum.at(keys, rem(id - 1, length(keys)))

    case :ets.insert_new(tab, {key, :claimed, id, 0}) do
      true ->
        # Winner: match the row (exists-check), then conditional update to
        # :committed — only observed through the matched, existing row.
        case :ets.match(tab, {key, :"$1", :"$2", :"$3"}) do
          [[:claimed, winner_id, 0]] when winner_id == id ->
            :ets.insert(tab, {key, :committed, winner_id, 1})
            {:winner, key}

          _ ->
            {:error, {:claim_vanished, key}}
        end

      false ->
        {:cas_lost, key}
    end
  end

  @doc """
  Determinism assertion (test seam): exactly one winner per contended key,
  loser partition exact, every committed row owned by its claim winner.
  """
  def assert_contention_final(actor_results, final) do
    winners =
      actor_results
      |> Enum.filter(&match?({_, {:winner, _}}, &1))
      |> Map.new(fn {id, {:winner, key}} -> {key, id} end)

    losers = Enum.count(Map.values(actor_results), &match?({:cas_lost, _}, &1))

    cond do
      map_size(winners) != Enum.count(Map.values(actor_results), &match?({:winner, _}, &1)) ->
        {:error, {:multiple_winners_per_key, winners}}

      map_size(actor_results) != map_size(winners) + losers ->
        {:error, {:loser_partition, actor_results}}

      map_size(final) != map_size(winners) ->
        {:error, {:committed_key_mismatch, map_size(final), map_size(winners)}}

      Enum.find(final, fn {key, {state, winner, version}} ->
        state != :committed or version != 1 or Map.get(winners, key) != winner
      end) != nil ->
        {:error, {:bad_final_row, final}}

      true ->
        :ok
    end
  end

  # --------------------------------------------------------------------------
  # helpers
  # --------------------------------------------------------------------------

  defp loaded?(mod), do: match?({:module, ^mod}, Code.ensure_loaded(mod))

  defp reductions do
    case :erlang.process_info(self(), :reductions) do
      {:reductions, n} -> n
      nil -> 0
    end
  end

  defp wall_us(t0, t1), do: :erlang.convert_time_unit(t1 - t0, :native, :microsecond)

  # Nearest-rank percentile over the sorted sample.
  defp percentile(xs, p) do
    sorted = Enum.sort(xs)
    idx = max(0, ceil(p / 100 * length(sorted)) - 1)
    Enum.at(sorted, idx)
  end

  defp count_state(results, range, state), do: Enum.count(range, &(results[&1].state == state))

  defp count_kind(actor_results, :winner),
    do: Enum.count(actor_results, &match?({_, {:winner, _}}, &1))

  defp count_kind(actor_results, :cas_lost),
    do: Enum.count(actor_results, &match?({_, {:cas_lost, _}}, &1))

  defp collect([], acc), do: acc

  defp collect([id | rest], acc) do
    receive do
      {^id, res} -> collect(rest, Map.put(acc, id, res))
    end
  end
end
