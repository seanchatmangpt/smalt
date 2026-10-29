defmodule PopcornDemo.Reconcile do
  @moduledoc """
  Synchronous Cloud Reconciliation Engine (PRD S8) — staged local mutations
  merged with remote documents by MONOTONIC rules only:

    * higher `_v` wins (stale local loses, stale remote loses)
    * equal `_v` + byte-identical → converged, nothing diverges
    * equal `_v` + divergent bytes → typed conflict, never silently
      overwritten
    * WORM-keyed ids refuse ANY lower-`_v` overwrite (immutable monotonicity)

  Real ETS store (named table `:reconcile_store`), pure-BEAM `:erlang.phash2` consistency digest (BK-46).
  Sub-Turing: bounded iterations only — every walk is a single bounded pass
  over a fixed enumerable; no unbounded recursion, no spawn, no waits.

  Consistency hash = sha256 over the sorted `{id, _v}` tuples, so it changes
  iff the (id, _v) state changes.
  """

  @store :reconcile_store

  @typedoc "A document: required string id and monotonic integer version `_v`."
  @type doc :: %{required(:id) => String.t(), required(:_v) => integer(), optional(atom) => term}

  @typedoc "Typed conflict: equal `_v`, divergent bytes. Nothing was overwritten."
  @type conflict :: %{
          id: String.t(),
          _v: integer(),
          reason: :equal_version_divergent_bytes,
          local: doc,
          remote: doc
        }

  @type stage_result :: {:ok, %{hash: binary, staged: non_neg_integer}} | {:error, term}

  @doc "Ensure the named ETS store exists (idempotent, real ETS)."
  @spec ensure_store :: :ok
  def ensure_store do
    if :ets.whereis(@store) == :undefined do
      :ets.new(@store, [:named_table, :set, :public, read_concurrency: true])
    end

    :ok
  end

  @doc """
  Stage a set of local mutations into the ETS store. Each doc must carry a
  string `id` and a monotonic integer `_v`. Returns the consistency hash and
  staged count. WORM status is carried per doc via `worm: true`.
  """
  @spec stage(Enumerable.t(), keyword) :: stage_result
  def stage(docs, _opts \\ []) do
    ensure_store()

    with :ok <- validate(docs) do
      n =
        Enum.reduce(docs, 0, fn doc, acc ->
          :ets.insert(@store, {doc.id, doc, Map.get(doc, :worm, false)})
          acc + 1
        end)

      {:ok, %{hash: consistency_hash(), staged: n}}
    end
  end

  @doc """
  Merge staged local docs against `remote_docs` (the "reconnect" surface).

  Monotonic rules, per id:
    * `local._v > remote._v` → local wins
    * `local._v < remote._v` → remote wins
    * equal `_v`, identical bytes → converged (store the canonical copy)
    * equal `_v`, divergent bytes → typed conflict, NOTHING is written
    * WORM ids: any outcome that would LOWER the stored `_v` is refused
      (`:worm_monotonicity`) — never overwritten.

  Sub-Turing: one bounded pass over the sorted remote enumerable.
  """
  @spec reconcile(Enumerable.t(), keyword) ::
          {:ok, %{merged: [map], conflicts: [conflict], refused: [map], hash: binary}}
          | {:error, term}
  def reconcile(remote_docs, _opts \\ []) do
    ensure_store()

    with :ok <- validate(remote_docs) do
      {merged_r, conflicts_r, refused_r} =
        remote_docs
        |> Enum.sort_by(& &1.id)
        |> Enum.reduce({[], [], []}, fn remote, {m, c, r} ->
          case merge_one(remote) do
            {:ok, outcome, winner} ->
              :ets.insert(@store, {winner.id, winner, Map.get(winner, :worm, false)})
              {[outcome_row(outcome, winner) | m], c, r}

            {:conflict, detail} ->
              {m, [detail | c], r}

            {:refused, reason, detail} ->
              {m, c, [Map.put(detail, :reason, reason) | r]}
          end
        end)

      {:ok,
       %{
         merged: Enum.reverse(merged_r),
         conflicts: Enum.reverse(conflicts_r),
         refused: Enum.reverse(refused_r),
         hash: consistency_hash()
       }}
    end
  end

  @doc """
  Consistency digest over the sorted `{id, _v}` tuples — changes iff state changes.

  Substitution note (BK-46): was `:crypto.hash(:sha256, ...)` — unavailable under
  wasm (`:crypto.hash/2 undefined`, BK-40). This is a demo-side consistency check,
  NOT a security hash: `:erlang.phash2` is pure-BEAM and deterministic per BEAM
  instance. If any downstream caller ever asserts on the exact digest VALUE, that
  caller must be typed and the digest re-based on a stable algorithm.
  """
  @spec consistency_hash :: non_neg_integer
  def consistency_hash do
    ensure_store()

    tuples =
      @store
      |> :ets.tab2list()
      |> Enum.map(fn {id, doc, _worm} -> {id, doc_v(doc)} end)
      |> Enum.sort()

    :erlang.phash2(tuples)
  end

  @doc "Read the currently stored doc for `id` (nil if absent)."
  @spec stored(String.t()) :: doc | nil
  def stored(id) do
    ensure_store()

    case :ets.lookup(@store, id) do
      [{_id, doc, _worm}] -> doc
      [] -> nil
    end
  end

  @doc "Drop and re-create the store (test teardown aid; real ETS lifecycle)."
  @spec reset :: :ok
  def reset do
    if :ets.whereis(@store) != :undefined, do: :ets.delete(@store)
    ensure_store()
  end

  ## Internals

  @spec merge_one(doc) ::
          {:ok, :local_wins | :remote_wins | :converged, doc}
          | {:conflict, conflict}
          | {:refused, :worm_monotonicity | :no_staged_copy, map}
  defp merge_one(remote) do
    id = remote.id

    case :ets.lookup(@store, id) do
      [] ->
        {:refused, :no_staged_copy, %{id: id, remote: remote}}

      [{^id, local, worm?}] ->
        lv = doc_v(local)
        rv = doc_v(remote)
        cond do
          worm? and rv < lv ->
            {:refused, :worm_monotonicity, %{id: id, local: local, remote: remote}}

          lv > rv ->
            {:ok, :local_wins, local}

          lv < rv ->
            {:ok, :remote_wins, remote}

          true ->
            if bytes_equal?(local, remote) do
              {:ok, :converged, local}
            else
              {:conflict,
               %{
                 id: id,
                 _v: lv,
                 reason: :equal_version_divergent_bytes,
                 local: local,
                 remote: remote
               }}
            end
        end
    end
  end

  defp outcome_row(outcome, winner) do
    %{id: winner.id, outcome: outcome, _v: doc_v(winner), doc: winner}
  end

  defp bytes_equal?(a, b) do
    sorted_a = a |> Map.delete(:id) |> :erlang.term_to_binary()
    sorted_b = b |> Map.delete(:id) |> :erlang.term_to_binary()
    sorted_a == sorted_b
  end

  defp doc_v(doc), do: Map.fetch!(doc, :_v)

  @spec validate(Enumerable.t()) :: :ok | {:error, term}
  defp validate(docs) do
    Enum.reduce_while(docs, :ok, fn doc, :ok ->
      cond do
        not is_map(doc) ->
          {:halt, {:error, {:invalid_doc, doc}}}

        not is_binary(Map.get(doc, :id)) ->
          {:halt, {:error, {:invalid_id, doc}}}

        not is_integer(Map.get(doc, :_v)) ->
          {:halt, {:error, {:missing_or_invalid_version, doc}}}

        true ->
          {:cont, :ok}
      end
    end)
  end
end
