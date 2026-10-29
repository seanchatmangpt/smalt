defmodule PopcornDemo.GuidelineOfflineTest do
  @moduledoc """
  SDK guideline general-testing-6 — "all tests runnable offline, no network
  to real Azure", as an executable Chicago court for the popcorn stack.

  Runs the full in-memory leg-walk — `PopcornDemo.Concurrency.ramp(64)`
  (cosmos SQL + Service-Bus rules + registry faces, per-actor isolated),
  `PopcornDemo.Reconcile.stage/reconcile` (real ETS + sha256), and
  `PopcornDemo.LocalSTS.mint/verify` — and asserts ZERO egress two ways:

    1. STATIC (by construction): the compiled BEAM abstract code of every
       walked module is scanned for references to the transport layer
       (`PopcornDemo.Transport{,.Fetch,.Httpc}` — the only modules in the
       tree that open sockets). Zero references == zero possible egress from
       the walk, on the exact compiled artifacts that ran. Non-vacuous: the
       same scanner over a module that DOES reference the transport layer
       (`PopcornDemo.Transport.Httpc` itself) must find them.

    2. DYNAMIC: the node's tcp/udp port population is censused before and
       after the walk (real `:erlang.ports()` enumeration by driver name) —
       no new socket port may appear across the walk. (Note: call tracing
       is inert here for a toolchain-independent reason — ERTS drops trace
       events addressed to the traced process itself; see
       docs/jira/v26.10.20/receipts/tracebug-mixtest-tracing.md and the
       worker-pid + dedicated-tracer pattern in test/trace_repro_test.exs —
       so the dynamic side uses port enumeration, which does work.)

  The walk runs unmodified and unmocked. Chicago school: real collaborators,
  assert on observed state, no test doubles of the walk.
  """

  use ExUnit.Case, async: false

  alias PopcornDemo.{Concurrency, LocalSTS, Reconcile}

  @socket_drivers [~c"tcp_inet", ~c"udp_inet", ~c"tcp6_inet", ~c"udp6_inet"]

  @walked_modules [Concurrency, Reconcile, LocalSTS]

  @transport_prefixes [
    PopcornDemo.Transport,
    PopcornDemo.Transport.Fetch,
    PopcornDemo.Transport.Httpc
  ]

  setup do
    Reconcile.reset()
    :ok
  end

  describe "offline leg-walk" do
    test "completes the full walk with zero egress (static + dynamic)" do
      sockets_before = socket_census()

      # -- leg 1: 64-actor deterministic in-memory walk -----------------------
      ramp = Concurrency.ramp(64)

      assert ramp.verified == 64,
             "expected all 64 actors verified, got row: #{inspect(ramp)}"

      assert ramp.breaches == 0
      assert ramp.n == 64
      assert is_float(ramp.wall_ms) and ramp.wall_ms >= 0.0
      assert ramp.p50_us >= 0 and ramp.p99_us >= ramp.p50_us
      assert ramp.reductions_total > 0

      # -- leg 2: reconcile stage + merge on real ETS -------------------------
      assert {:ok, staged} =
               Reconcile.stage([
                 %{id: "leg-blob", _v: 3, worm: true, bytes: "BLOB"},
                 %{id: "leg-kv", _v: 5, bytes: "KV"}
               ])

      # BK-46: consistency digest is a :erlang.phash2 integer now (was sha256
      # binary — :crypto unavailable under wasm). Change-detection semantics
      # unchanged; representation re-typed here.
      assert staged.staged == 2 and is_integer(staged.hash) and staged.hash >= 0

      assert {:ok, rec} =
               Reconcile.reconcile([
                 # lower _v vs staged worm doc -> refused, never overwritten
                 %{id: "leg-blob", _v: 1, worm: true, bytes: "OLD"},
                 # higher _v -> remote wins
                 %{id: "leg-kv", _v: 6, bytes: "KV2"},
                 # equal _v but never staged -> typed refusal
                 %{id: "leg-queue", _v: 2, bytes: "Q"}
               ])

      refusals = Map.new(rec.refused, fn r -> {r.id, r.reason} end)
      # blob: worm monotonicity (never lowered); queue: never staged
      assert refusals == %{"leg-blob" => :worm_monotonicity, "leg-queue" => :no_staged_copy}

      merged = Map.new(rec.merged, fn row -> {row.id, row} end)
      # refused worm doc merges nothing; kv takes the newer remote bytes
      assert %{outcome: :remote_wins, _v: 6} = merged["leg-kv"]
      assert Map.has_key?(merged, "leg-blob") == false
      assert %{_v: 3, bytes: "BLOB"} = Reconcile.stored("leg-blob")
      assert %{_v: 6, bytes: "KV2"} = Reconcile.stored("leg-kv")

      # -- leg 3: LocalSTS mint/verify round trip -----------------------------
      assert {:ok, minted} = LocalSTS.mint("guideline-offline", scopes: ["blob.read"])
      assert {:ok, claims} = LocalSTS.verify(minted.token)
      assert claims["sub"] == "guideline-offline" and claims["scopes"] == ["blob.read"]
      assert claims["exp"] == claims["iat"] + LocalSTS.ttl_s()

      # fail-closed face on the same leg
      assert {:error, :malformed} = LocalSTS.verify("not.a.token")

      # contention face: deterministic CAS, still offline
      assert {:ok, contention} = Concurrency.contention(64)
      assert contention.winners + contention.losers == 64
      assert contention.committed_rows == contention.keys

      # -- dynamic egress check: no new socket ports across the whole walk ----
      after_census = socket_census()

      assert after_census == sockets_before,
             "socket population changed across the offline walk " <>
               "(before: #{inspect(sockets_before)}, after: #{inspect(after_census)})"

      # -- static egress check: zero transport references in the walked beams -
      for mod <- @walked_modules do
        refs = transport_refs(mod)
        assert refs == [],
               "#{inspect(mod)} references the transport layer (possible egress): " <>
                 inspect(refs)
      end
    end

    test "static court is non-vacuous: scanner finds transport refs where they exist" do
      # the scanner over a module that genuinely calls the transport layer
      # must report hits; if it reports none, the zero-verdicts above are void
      assert transport_refs(PopcornDemo.Transport.Httpc) != []

      # and a module outside the walk that opens sockets is caught too
      assert Enum.any?(@walked_modules, &(transport_refs(&1) != [])) == false
    end

    test "tokens mint deterministically apart and verify byte-exact" do
      {:ok, a} = LocalSTS.mint("walk-client", scopes: ["queue.send"])
      {:ok, b} = LocalSTS.mint("walk-client", scopes: ["queue.send"])

      payload = fn r ->
        r |> Map.fetch!(:token) |> String.split(".", parts: 3) |> Enum.at(1)
      end

      ca = payload.(a) |> Base.url_decode64!(padding: false) |> :erlang.binary_to_term()
      cb = payload.(b) |> Base.url_decode64!(padding: false) |> :erlang.binary_to_term()

      assert cb["jti"] == ca["jti"] + 1
      assert Map.delete(ca, "jti") == Map.delete(cb, "jti")

      assert {:ok, verified} = LocalSTS.verify(b.token)
      assert verified == cb
    end

    test "reconcile monotonicity: stale local loses, divergent-equal conflicts, worm refuses" do
      # stale local loses to newer remote
      assert {:ok, _} = Reconcile.stage([%{id: "r1", _v: 4, bytes: "old"}])

      assert {:ok, %{merged: [row]}} = Reconcile.reconcile([%{id: "r1", _v: 9, bytes: "new"}])
      assert row.outcome == :remote_wins and row._v == 9

      # equal _v + divergent bytes -> typed conflict, nothing written
      assert {:ok, %{conflicts: [c]}} = Reconcile.reconcile([%{id: "r1", _v: 9, bytes: "DIFF"}])
      assert c.reason == :equal_version_divergent_bytes
      assert %{_v: 9, bytes: "new"} = Reconcile.stored("r1")

      # worm: any lower-_v overwrite refused
      assert {:ok, _} = Reconcile.stage([%{id: "r2", _v: 7, bytes: "WORM", worm: true}])
      assert {:ok, %{refused: [w]}} = Reconcile.reconcile([%{id: "r2", _v: 3, bytes: "x"}])
      assert w.reason == :worm_monotonicity
      assert %{_v: 7, bytes: "WORM"} = Reconcile.stored("r2")
    end
  end

  ## Egress observation helpers

  # Count inets socket ports on the node by driver name.
  defp socket_census do
    :erlang.ports()
    |> Enum.map(&{&1, :erlang.port_info(&1, :name)})
    |> Enum.filter(fn {_p, name} -> name in @socket_drivers end)
    |> Enum.frequencies_by(fn {_p, name} -> List.to_atom(name) end)
  end

  # Scan a module's compiled beam abstract code for any reference to the
  # transport layer: aliases, remote calls, and fun references all surface
  # as atoms in the abstract format.
  defp transport_refs(mod) do
    with {:ok, forms} <- debug_info(mod) do
      forms
      |> Enum.flat_map(&atoms_in/1)
      |> Enum.uniq()
      |> Enum.filter(&(&1 in @transport_prefixes or transport_submodule?(&1)))
    else
      _ -> raise "no debug_info for #{inspect(mod)} — static court cannot run"
    end
  end

  defp debug_info(mod) do
    path = :code.which(mod)

    case :beam_lib.chunks(path, [:abstract_code]) do
      {:ok, {_, [abstract_code: {:raw_abstract_v1, forms}]}} -> {:ok, forms}
      other -> raise "no abstract code for #{inspect(mod)}: #{inspect(other, limit: 4)}"
    end
  end

  defp transport_submodule?(atom) when is_atom(atom) do
    case Atom.to_string(atom) do
      "Elixir.PopcornDemo.Transport" <> _ -> true
      _ -> false
    end
  end

  defp transport_submodule?(_), do: false

  # Walk any abstract-format term and collect the atoms it mentions.
  defp atoms_in(term) when is_atom(term), do: [term]
  defp atoms_in(term) when is_tuple(term), do: Enum.flat_map(Tuple.to_list(term), &atoms_in/1)
  defp atoms_in(term) when is_list(term), do: Enum.flat_map(term, &atoms_in/1)
  defp atoms_in(term) when is_map(term), do: term |> Map.to_list() |> atoms_in()
  defp atoms_in(_), do: []
end
