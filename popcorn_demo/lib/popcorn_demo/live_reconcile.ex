defmodule PopcornDemo.LiveReconcile do
  @moduledoc """
  LANE S10 — local↔cloud sync boundary over REAL state (Chicago testbed:
  real docs, real etags, real wire refusals — no mocks).

  One `run/0` walks the PRD's local↔cloud reconcile seam on
  `http://127.0.0.1:8443` (wire shapes proven in LiveMatrix / LiveCas):

    1. mint STS bearer on 9443
    2. ensure db `popcorn` / container `smoke` (201 create, 409 exists)
    3. stage 3 local docs via `PopcornDemo.Reconcile.stage/2`:
       * `live-reconcile-fresh` — local `_v` will EXCEED remote (fresh)
       * `live-reconcile-stale` — remote copy will be bumped past local
         (stale local must LOSE)
       * `live-reconcile-conf`  — equal `_v`, divergent bytes (typed conflict)
    4. seed the remote copies on the real wire: POST inserts; the stale
       doc is bumped once more remotely so `remote._v > local._v`
    5. fetch the REAL feed (GET /dbs/:db/colls/:coll/docs), convert wire
       docs to Reconcile docs (`v` → `:_v`)
    6. `PopcornDemo.Reconcile.reconcile/2` staged-vs-remote and assert:
       * monotonic winners — fresh id: local_wins; stale id: remote_wins
       * typed conflict — equal `_v` divergent bytes lands in `conflicts`
         with `reason: :equal_version_divergent_bytes`, and the remote
         bytes are NOT overwritten (re-GET still shows remote payload)
    7. push ONLY the winners via real CAS PUT (`If-Match` VERBATIM from
       the feed `_etag` — re-quoting yields a real 412; `x-ms-documentdb-
       partitionkey` is a JSON ARRAY per the PK pinion), and verify the
       pushed bytes round-trip on a fresh GET.

  Receipts (run/0 return), house style:
    {:ok,    "reconcile=OK(<stages>)"}
    {:skip,  "reconcile=SKIP(substrate-down)"}  -- transport refused
    {:error, "reconcile=FAIL(<step>:<reason>)"} -- any other failure

  Not wired into the supervision tree — coordinator integrates.
  Export `run/0` only.
  """

  alias PopcornDemo.Redact
  alias PopcornDemo.Reconcile

  @base "http://127.0.0.1:8443"
  @sts "http://127.0.0.1:9443"
  @tenant "00000000-0000-0000-0000-000000000000"
  @db "popcorn"
  @coll "smoke"
  @fresh "live-reconcile-fresh"
  @stale "live-reconcile-stale"
  @conf "live-reconcile-conf"
  @kind "reconcile"

  @doc "Full local↔cloud reconcile walk over the live substrate."
  @spec run() :: {:ok, binary()} | {:skip, binary()} | {:error, binary()}
  def run do
    with :ok <- mint(),
         :ok <- ensure_db(),
         :ok <- ensure_coll(),
         :ok <- own_state(),
         {:ok, staged} <- stage_local(),
         :ok <- seed_remote(),
         {:ok, feed} <- fetch_docs(),
         {:ok, verdict} <- reconcile_local_vs_remote(feed),
         :ok <- push_winners_cas(verdict),
         :ok <- assert_conflict_not_overwritten() do
      {:ok, "reconcile=OK(#{staged}-staged,seeded,feed-#{length(feed)},monotonic,typed-conflict,cas-winners)"}
    end
  end

  # -- Steps ---------------------------------------------------------------

  # The walk OWNS its state: on a long-lived recycled beam the previous
  # run's pushed winners are still on the wire (fresh = v5 "local-new") and
  # reconcile's winner-insert has left an etag-carrying remote map in the
  # ETS store, so the next run's equal-_v merge classifies the fed :etag as
  # divergent bytes (typed-conflict / converged drift) instead of the
  # intended monotonic outcome. Purge the three walk-owned ids off the wire
  # and reset the ETS store BEFORE staging so every run/0 is idempotent
  # from any prior state.
  defp own_state do
    purge_result =
      Enum.reduce_while([@fresh, @stale, @conf], :ok, fn id, acc ->
        if acc == :ok do
          case get_etag(id) do
            {:ok, etag} -> {:cont, purge_doc(id, etag)}
            _ -> {:cont, :ok}
          end
        else
          {:halt, acc}
        end
      end)

    with :ok <- purge_result do
      Reconcile.reset()
      :ok
    end
  end

  defp purge_doc(id, etag) do
    case req(:delete, doc_url(id),
            headers: [
              {"if-match", etag},
              {"x-ms-documentdb-partitionkey", Jason.encode!([id])}
            ]) do
      {:ok, %{status: s}} when s in [200, 204, 404] -> :ok
      {:ok, %{status: s, body: b}} ->
        {:error, "reconcile=FAIL(purge:HTTP-#{s}-id-#{id}-#{Redact.fragment(inspect(b))})"}

      {:error, reason} ->
        {:skip, "reconcile=SKIP(transport:#{slice(inspect(reason))})"}
    end
  end

  defp slice(r) when is_binary(r), do: String.slice(r, 0, 120)
  defp slice(r), do: r |> inspect() |> String.slice(0, 120)

  defp mint do
    body =
      "grant_type=client_credentials&client_id=x&client_secret=y" <>
        "&scope=https://cosmos.azure.com/.default"

    case req(:post, "#{@sts}/#{@tenant}/oauth2/v2.0/token",
            body: body,
            headers: [{"content-type", "application/x-www-form-urlencoded"}]) do
      {:ok, %{status: 200, body: %{"access_token" => tok}}} when is_binary(tok) ->
        Process.put({__MODULE__, :token}, tok)
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "reconcile=FAIL(mint:STS-status-#{s}-body=#{Redact.fragment(inspect(b))})"}

      {:error, reason} ->
        {:skip, "reconcile=SKIP(transport:#{slice(reason)})"}
    end
  end

  defp ensure_db do
    case req(:post, "#{@base}/dbs", body: Jason.encode!(%{"id" => @db})) do
      {:ok, %{status: s}} when s in [201, 409] -> :ok
      {:ok, %{status: s, body: b}} -> {:error, "reconcile=FAIL(ensure_db:HTTP-#{s}-#{Redact.fragment(inspect(b))})"}
      {:error, reason} -> {:skip, "reconcile=SKIP(transport:#{slice(reason)})"}
    end
  end

  defp ensure_coll do
    body =
      Jason.encode!(%{
        "id" => @coll,
        "partitionKey" => %{"paths" => ["/id"], "kind" => "Hash"}
      })

    case req(:post, "#{@base}/dbs/#{@db}/colls", body: body) do
      {:ok, %{status: s}} when s in [201, 409] -> :ok
      {:ok, %{status: s, body: b}} ->
        {:error, "reconcile=FAIL(ensure_coll:HTTP-#{s}-#{Redact.fragment(inspect(b))})"}
      {:error, reason} -> {:skip, "reconcile=SKIP(transport:#{slice(inspect(reason))})"}
    end
  end

  # Stage the three local docs in the real ETS reconcile store.
  defp stage_local do
    docs = [
      %{id: @fresh, _v: 5, kind: @kind, payload: "local-new"},
      %{id: @stale, _v: 1, kind: @kind, payload: "stale-local"},
      %{id: @conf, _v: 3, kind: @kind, payload: "local-A"}
    ]

    case Reconcile.stage(docs) do
      {:ok, %{staged: n}} when n == 3 -> {:ok, n}
      {:ok, %{staged: n}} -> {:error, "reconcile=FAIL(stage:staged-#{n}-wanted-3)"}
      {:error, reason} -> {:error, "reconcile=FAIL(stage:#{inspect(reason) |> slice()})"}
    end
  end

  # Seed the remote side on the real wire. POST creates; the stale doc gets
  # one extra remote bump (unconditional PUT) so remote._v (9) > local._v (1).
  defp seed_remote do
    with :ok <- insert(@fresh, 2, "remote-old"),
         :ok <- insert(@stale, 1, "remote-v1"),
         {:ok, _bump_etag} <- bump(@stale, 9, "remote-v9"),
         :ok <- insert(@conf, 3, "remote-B") do
      :ok
    end
  end

  defp insert(id, v, payload) do
    case req(:post, docs_url(),
            body: Jason.encode!(%{"id" => id, "kind" => @kind, "v" => v, "payload" => payload}),
            headers: [{"x-ms-documentdb-partitionkey", Jason.encode!([id])}]) do
      {:ok, %{status: s}} when s in [201, 409] -> :ok
      {:ok, %{status: s, body: b}} ->
        {:error, "reconcile=FAIL(seed:HTTP-#{s}-id-#{id}-#{Redact.fragment(inspect(b))})"}
      {:error, reason} ->
        {:skip, "reconcile=SKIP(transport:#{slice(inspect(reason))})"}
    end
  end

  # Unconditional remote bump (capture etag first; stale-If-Match would 412).
  defp bump(id, v, payload) do
    with {:ok, etag} <- get_etag(id) do
      case req(:put, doc_url(id),
              body: Jason.encode!(%{"id" => id, "kind" => @kind, "v" => v, "payload" => payload}),
              headers: [
                {"if-match", etag},
                {"x-ms-documentdb-partitionkey", Jason.encode!([id])}
              ]) do
        {:ok, %{status: 200, body: %{"_etag" => fresh}}} -> {:ok, fresh}
        {:ok, %{status: s, body: b}} ->
          {:error, "reconcile=FAIL(bump:HTTP-#{s}-#{Redact.fragment(inspect(b))})"}
        {:error, reason} ->
          {:skip, "reconcile=SKIP(transport:#{slice(inspect(reason))})"}
      end
    end
  end

  defp get_etag(id) do
    case req(:get, doc_url(id)) do
      {:ok, %{status: 200, body: %{"_etag" => etag}}} when is_binary(etag) -> {:ok, etag}
      {:ok, %{status: s, body: b}} ->
        {:error, "reconcile=FAIL(get_etag:HTTP-#{s}-#{Redact.fragment(inspect(b))})"}
      {:error, reason} ->
        {:skip, "reconcile=SKIP(transport:#{slice(inspect(reason))})"}
    end
  end

  defp fetch_docs do
    case req(:get, docs_url()) do
      {:ok, %{status: 200, body: %{"Documents" => docs}}} when is_list(docs) ->
        {:ok, docs}

      {:ok, %{status: s, body: b}} ->
        {:error, "reconcile=FAIL(fetch_docs:HTTP-#{s}-#{Redact.fragment(inspect(b))})"}

      {:error, reason} ->
        {:skip, "reconcile=SKIP(transport:#{slice(inspect(reason))})"}
    end
  end

  # Convert the REAL wire docs (string keys) to Reconcile docs (atom keys,
  # `v` → `:_v`, `_etag` carried for the CAS push) and run the merge.
  defp reconcile_local_vs_remote(feed) do
    ours = MapSet.new([@fresh, @stale, @conf])

    remote =
      feed
      |> Enum.filter(&(MapSet.member?(ours, &1["id"])))
      |> Enum.map(fn d ->
        %{
          id: d["id"],
          _v: d["v"],
          kind: d["kind"],
          payload: d["payload"],
          etag: d["_etag"]
        }
      end)

    with {:ok, %{merged: merged, conflicts: conflicts}} <- Reconcile.reconcile(remote) do
      fresh = Enum.find(merged, &(&1.id == @fresh))
      stale = Enum.find(merged, &(&1.id == @stale))
      conflict = Enum.find(conflicts, &(&1.id == @conf))

      cond do
        is_nil(fresh) or is_nil(stale) ->
          {:error, "reconcile=FAIL(monotonic:merged=#{inspect(merged) |> slice()})"}

        fresh.outcome != :local_wins ->
          {:error, "reconcile=FAIL(monotonic:fresh-outcome-#{fresh.outcome}-wanted-local_wins)"}

        stale.outcome != :remote_wins ->
          {:error, "reconcile=FAIL(monotonic:stale-outcome-#{stale.outcome}-wanted-remote_wins)"}

        is_nil(conflict) ->
          {:error, "reconcile=FAIL(conflict:equal-v-divergent-bytes-not-typed)"}

        conflict.reason != :equal_version_divergent_bytes ->
          {:error, "reconcile=FAIL(conflict:reason-#{conflict.reason})"}

        true ->
          {:ok, %{fresh: fresh, stale: stale, conflict: conflict}}
      end
    else
      {:error, reason} -> {:error, "reconcile=FAIL(reconcile:#{inspect(reason) |> slice()})"}
    end
  end

  # Push ONLY the winners: fresh (local won) via real CAS PUT with the
  # winner's live `_etag` VERBATIM in If-Match (captured fresh per push —
  # the feed etag is stale the moment anything touches the doc). Stale
  # (remote won) needs no push; its remote copy is already the winner.
  defp push_winners_cas(%{fresh: fresh, stale: stale}) do
    with {:ok, etag_f} <- get_etag(@fresh),
         {:ok, etag_s} <- get_etag(@stale),
         :ok <- cas_put(@fresh, fresh.doc._v, fresh.doc.payload, etag_f),
         :ok <- cas_put(@stale, stale.doc._v, stale.doc.payload, etag_s),
         :ok <- assert_round_trip(@fresh, fresh.doc._v, "local-new"),
         :ok <- assert_round_trip(@stale, stale.doc._v, "remote-v9") do
      :ok
    end
  end

  # Real PUT replace with If-Match (etag verbatim — live_cas pinion) and
  # the PK JSON-array pinion; then verify the winner's payload on the wire.
  defp cas_put(id, v, payload, etag) do
    case req(:put, doc_url(id),
            body: Jason.encode!(%{"id" => id, "kind" => @kind, "v" => v, "payload" => payload}),
            headers: [
              {"if-match", etag},
              {"x-ms-documentdb-partitionkey", Jason.encode!([id])}
            ]) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "reconcile=FAIL(cas_put:HTTP-#{s}-id-#{id}-#{Redact.fragment(inspect(b))})"}

      {:error, reason} ->
        {:skip, "reconcile=SKIP(transport:#{slice(inspect(reason))})"}
    end
  end

  defp assert_round_trip(id, v, payload) do
    case req(:get, doc_url(id)) do
      {:ok, %{status: 200, body: %{"v" => ^v, "payload" => ^payload}}} ->
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error,
         "reconcile=FAIL(round_trip:id-#{id}-HTTP-#{s}-wanted-v-#{v}-payload-#{payload}-" <>
           Redact.fragment(inspect(b)) <> ")"}

      {:error, reason} ->
        {:skip, "reconcile=SKIP(transport:#{slice(inspect(reason))})"}
    end
  end

  # The typed conflict must have overwritten NOTHING: the remote copy keeps
  # its own bytes (remote-B) after the reconcile walk.
  defp assert_conflict_not_overwritten do
    case req(:get, doc_url(@conf)) do
      {:ok, %{status: 200, body: %{"payload" => "remote-B", "v" => 3}}} ->
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "reconcile=FAIL(conflict-not-overwritten:HTTP-#{s}-#{Redact.fragment(inspect(b))})"}

      {:error, reason} ->
        {:skip, "reconcile=SKIP(transport:#{slice(inspect(reason))})"}
    end
  end

  # -- URLs / transport -----------------------------------------------------
  # Same single-transport calculus as LiveMatrix / LiveCas (ERRC-E2): browser
  # Fetch when the Popcorn JS bridge is up, else host Transport.Httpc. This
  # file is lane-owned (S10); live_matrix.ex / live_cas.ex are NOT touched.

  defp docs_url, do: "#{@base}/dbs/#{@db}/colls/#{@coll}/docs"
  defp doc_url(id), do: "#{docs_url()}/#{id}"

  defp browser? do
    Code.ensure_loaded?(Popcorn.JS) and function_exported?(Popcorn.JS, :available?, 0) and
      Popcorn.JS.available?()
  end

  defp req(method, url, opts \\ []) do
    # Browsers reject GET/HEAD with a body (witnessed in LiveMatrix).
    body =
      if method == :get and not Keyword.has_key?(opts, :body),
        do: nil,
        else: Keyword.get(opts, :body, "")

    request = %{
      method: String.upcase(to_string(method)),
      url: url,
      headers: headers_for(Keyword.get(opts, :headers, [])),
      body: body
    }

    if browser?() do
      request |> PopcornDemo.Transport.Fetch.request() |> decode_body()
    else
      request |> PopcornDemo.Transport.Httpc.request() |> decode_body()
    end
  end

  defp decode_body({:ok, %{body: body} = resp}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, %{resp | body: decoded}}
      _ -> {:ok, resp}
    end
  end

  defp decode_body(other), do: other

  defp headers_for(extra) do
    bearer =
      case Process.get({__MODULE__, :token}) do
        nil -> []
        tok -> [{"authorization", "Bearer " <> tok}]
      end

    extra = List.wrap(extra)
    has_ct = Enum.any?(extra, fn {k, _} -> String.downcase(k) == "content-type" end)
    default = if has_ct, do: [], else: [{"content-type", "application/json"}]
    default ++ extra ++ bearer
  end
end
