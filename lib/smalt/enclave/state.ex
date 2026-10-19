defmodule Smalt.Enclave.State do
  @moduledoc """
  NFR-4 law: the terraform.tfstate-shaped state file is an EXACT
  read-projection of the Store (ETS) tables — synthesis never writes to the
  store, and destroy is an in-process reverse-topological DELETE walk
  dispatched through the real ARM router (`Smalt.ArmGateway.Router.call/2`),
  so the verified cascade (descendant sweep + data-plane drop) does the
  deletion, not this module.

  Three operations:

    * `synthesize/1` — engine outcome `%{label => %{id, type, status}}` →
      `%{label => %{"id" => id, "attributes" => <stored record>}}`, labels
      sorted deterministically; `encode/1` / `write/2` emit the JSON state
      file (Jason sorts map keys, so bytes are deterministic too).
    * `destroy/1` — DELETE each id deepest-first (path-segment count is a
      sound reverse-topological order for ARM id trees: every descendant's
      id has strictly more `/`), asserting 200/202 per delete, polling any
      202 LRO to terminal, then verifying a 404 GET per id and a zero
      residue over the resource-bearing Store tables.
    * `plan/1` — the zero-drift dry pass: compares HCL-derived terms
      (id/type plus optional declared `attributes`) against the stored
      records and returns the sorted diff list. `[]` = no drift (second
      apply), any tuple = drift to report after external mutation.
  """

  alias Smalt.ArmGateway.Router
  alias Smalt.Store

  @rg_type "Microsoft.Resources/resourceGroups"

  # Metadata bookkeeping tables, not resource state: LRO operation records
  # legitimately survive a destroy (terminal ops are history, not residue),
  # counters/lock tokens are monotonic plumbing.
  #
  # NFR-3 (SMALT_OPERATIONS_UNBOUNDED_ROWS, 500-cycle receipt: +3 rows/cycle):
  # destroy reclaims its own terminal operation rows through the sweeper's OWN
  # public passes — flip_pass first (terminalizes any past-due InProgress rows,
  # exactly what the periodic at-rest sweep would do), then retention-0
  # eviction (terminal rows only; InProgress is never evicted at any
  # retention). Poll-to-terminal is untouched: this runs AFTER the
  # reverse-topological walk, and a flipped row still polls 200 through the
  # router. No global :lro_retention_ms mutation.

  # W1b projection: the destroy-residue exclusion list is the generated
  # registry (metadataOnly rows, lib/smalt/store_tables.ex). Equivalent to
  # the hand-written list it replaced (replay-identity fence). DO NOT
  # re-introduce a local list — regenerate with `mix smalt.gen`.
  @metadata_tables Smalt.StoreTables.metadata_tables()

  @lro_poll_max 400
  @lro_poll_ms 5

  @router_opts Router.init([])

  # ===========================================================================
  # 1. synthesize — exact read-projection
  # ===========================================================================

  @doc """
  Projects the engine outcome into tfstate shape from the LIVE store:
  `%{label => %{"id" => id, "attributes" => record-or-nil}}`. Read-only.
  Labels sorted; a label whose record is gone projects `nil` attributes
  (visible drift, never a silent skip).
  """
  @spec synthesize(map()) :: %{String.t() => %{String.t() => term()}}
  def synthesize(outcome) when is_map(outcome) do
    outcome
    |> Enum.sort_by(fn {label, _} -> to_string(label) end)
    |> Map.new(fn {label, term} ->
      id = fetch_id(term)

      record =
        case lookup(id, fetch_type(term)) do
          {:ok, rec} -> rec
          :error -> nil
        end

      {to_string(label), %{"id" => id, "attributes" => record}}
    end)
  end

  @doc "Deterministic JSON encoding of the projection (Jason sorts map keys)."
  @spec encode(map()) :: String.t()
  def encode(outcome), do: Jason.encode!(synthesize(outcome))

  @doc "Writes the tfstate-shaped JSON state file."
  @spec write(map(), Path.t()) :: :ok
  def write(outcome, path), do: File.write!(path, [encode(outcome), "\n"])

  # ===========================================================================
  # 2. destroy — reverse-topological in-process cascade
  # ===========================================================================

  @doc """
  Reverse-topological DELETE walk through the real router. Deepest ids first
  (path-segment count = ARM id tree depth; ties broken by downcased id for
  determinism). Returns:

      %{
        deleted: [%{label, id, status, lro_terminal, verified}, ...],
        residue: %{table => remaining-keys}
      }

  Raises on any delete that is not 200/202, on a non-terminal LRO, or on a
  post-delete GET that is not 404. Fail-closed.
  """
  @spec destroy(map()) :: %{deleted: [map()], residue: %{atom() => [term()]}}
  def destroy(outcome) when is_map(outcome) do
    ordered =
      outcome
      |> Enum.map(fn {label, term} ->
        %{label: to_string(label), id: fetch_id(term), type: fetch_type(term)}
      end)
      |> Enum.sort_by(fn e -> {-depth(e.id), String.downcase(e.id)} end)

    deleted =
      for e <- ordered do
        delete_one(e)
      end

    # NFR-3: reclaim this lifecycle's terminal operation rows through the
    # sweeper's own passes (see the module-comment above @metadata_tables).
    :ok = Smalt.ArmGateway.LRO.Sweeper.flip_pass()
    :ok = Smalt.ArmGateway.LRO.Sweeper.eviction_pass(0)

    # Metrics cascade: a deleted resource leaves no :smalt_metrics rows.
    # The router DELETE routes drop their own series; this pass covers
    # resources deleted through paths that bypass those routes.
    Enum.each(deleted, fn %{id: id} -> Smalt.Metrics.drop(id) end)

    # AZB-10 bridge purge: the resource-write fan-out
    # (Smalt.EgressRouter.Peers.emit_resource_write_success/2) enqueues each
    # ResourceWriteSuccess event on the Service Bus bridge queue
    # "resourcewritesuccess" — a queue row (+ {queue, :seq} counter) in
    # :smalt_sb_queues and message rows in :smalt_sb_messages. The queue is
    # auto-created by the enclave's own control-plane writes, never
    # ARM-declared, so the router's cascade can never reach it. Product
    # contract: the enclave destroyed ⇒ its queues gone; purge explicitly.
    :ok = purge_resource_write_bridge()

    %{deleted: deleted, residue: residue()}
  end

  defp delete_one(e) do
    conn = dispatch(:delete, e.id, api_version(e.type))
    status = conn.status

    unless status in [200, 202] do
      raise "destroy: DELETE #{e.id} -> #{status} (expected 200/202)"
    end

    lro_terminal =
      if status == 202, do: poll_lro(conn), else: nil

    final_status = get_status(e.id, e.type)

    unless final_status == 404 do
      raise "destroy: post-delete GET #{e.id} -> #{final_status} (expected 404)"
    end

    %{label: e.label, id: e.id, status: status, lro_terminal: lro_terminal, verified: true}
  end

  defp poll_lro(delete_conn) do
    [loc] = resp_headers(delete_conn, "location")
    poll_loop(loc, @lro_poll_max)
  end

  defp poll_loop(_loc, 0),
    do: raise("destroy: LRO never reached terminal within #{@lro_poll_max} polls")

  defp poll_loop(loc, n) do
    conn = plain_request(:get, loc)
    # SLEEP-CLASS: SIGNALABLE-PENDING-REDESIGN (LRO.await; see
    # docs/jira/v26.10.18/rewrite-drafts/lib-redesign-wasm-lro.md). Fixed
    # 2026-10-18: predicate was inverted (slept AFTER terminal, polled hot
    # on 202 InProgress); sleep now covers only the still-InProgress step.
    if conn.status == 202, do: Process.sleep(@lro_poll_ms)
    if conn.status == 202, do: poll_loop(loc, n - 1), else: conn.status
  end

  # ===========================================================================
  # 3. plan — the zero-drift dry pass
  # ===========================================================================

  @doc """
  Compares HCL-derived terms vs stored records. Returns the sorted diff list:

    * `{:missing, label}`
    * `{:type, label, expected, actual}`
    * `{:drift, label, key, declared, stored}`

  `[]` means zero drift. Declared attributes compare per-key: any key in the
  term's `attributes` whose stored value differs (including absent) is drift.
  """
  @spec plan(map()) :: [tuple()]
  def plan(outcome) when is_map(outcome) do
    outcome
    |> Enum.sort_by(fn {label, _} -> to_string(label) end)
    |> Enum.flat_map(fn {label, term} ->
      label = to_string(label)
      id = fetch_id(term)
      type = fetch_type(term)

      case lookup(id, type) do
        :error ->
          [{:missing, label}]

        {:ok, record} ->
          type_diffs =
            if record["type"] != type, do: [{:type, label, type, record["type"]}], else: []

          type_diffs ++ attribute_diffs(label, term, record)
      end
    end)
    |> Enum.sort()
  end

  defp attribute_diffs(label, term, record) do
    for {k, declared} <- Enum.sort(term_attributes(term)),
        stored = Map.get(record, k),
        stored != declared do
      {:drift, label, k, declared, stored}
    end
  end

  # ===========================================================================
  # internals
  # ===========================================================================

  defp fetch_id(term),
    do:
      Map.get(term, :id) || Map.get(term, "id") ||
        raise("engine term missing :id: #{inspect(term)}")

  defp fetch_type(term),
    do:
      Map.get(term, :type) || Map.get(term, "type") ||
        raise("engine term missing :type: #{inspect(term)}")

  defp term_attributes(term), do: Map.get(term, :attributes) || Map.get(term, "attributes") || %{}

  # Resource groups live in their own table; everything else in :smalt_resources.
  defp lookup(id, @rg_type) do
    Store.get(:smalt_resource_groups, String.downcase(id))
  end

  defp lookup(id, _type) do
    key = String.downcase(id)

    case Store.get(:smalt_resources, key) do
      {:ok, rec} ->
        {:ok, rec}

      :error ->
        # child-route store-key convention: nested children (blob containers,
        # queues, subnets...) are stored WITHOUT the "/providers/<ns>/" segment
        Store.get(:smalt_resources, child_route_key(id))
    end
  end

  defp child_route_key(id) do
    id
    |> to_string()
    |> String.replace(~r{/providers/[^/]+/}, "/")
    |> String.downcase()
  end

  # -- in-process router dispatch (RuntimeContracts.Support precedent) --------

  defp dispatch(method, id, api_version) do
    plain_request(method, id <> "?api-version=" <> api_version)
  end

  defp get_status(id, type), do: dispatch(:get, id, api_version(type)).status

  defp plain_request(method, path) do
    Router.call(Plug.Test.conn(method, path), @router_opts)
  end

  defp resp_headers(conn, name) do
    for {k, v} <- conn.resp_headers, k == name do
      v
    end
  end

  defp depth(id), do: id |> to_string |> String.to_charlist() |> Enum.count(&(&1 == ?/))

  defp api_version(type) do
    case Smalt.Registry.latest_version(type) do
      nil -> "2024-01-01"
      v -> v
    end
  end

  defp purge_resource_write_bridge do
    bridge = "resourcewritesuccess"

    # message rows are keyed {queue, seq}; the seq counter is {queue, :seq}
    :ets.match_delete(:smalt_sb_messages, {{bridge, :_}, :_})
    Store.delete(:smalt_sb_queues, bridge)
    Store.delete(:smalt_sb_queues, {bridge, :seq})
    :ok
  end

  defp residue() do
    for t <- Store.table_names() -- @metadata_tables,
        :ets.info(t) != :undefined,
        into: %{} do
      {t, Store.keys(t)}
    end
  end
end
