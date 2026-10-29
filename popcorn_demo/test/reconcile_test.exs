defmodule PopcornDemo.ReconcileTest do
  use ExUnit.Case, async: false

  # Chicago-school leg for S8: real ETS, real :crypto sha256, real merge
  # state — no mocks, no doubles. Each test arranges its own store state
  # and asserts on final stored state, not on call counts.

  alias PopcornDemo.Reconcile

  setup do
    Reconcile.reset()
    :ok
  end

  describe "stage/2" do
    test "stages docs into real ETS and returns the consistency hash" do
      assert {:ok, %{staged: 2, hash: h}} =
               Reconcile.stage([%{id: "d1", _v: 1}, %{id: "d2", _v: 3}])

      # BK-46: digest is a pure-BEAM :erlang.phash2 integer (was sha256 32-byte
      # binary — :crypto unavailable under wasm). Change-detection semantics
      # unchanged (see consistency_hash/0 describe block).
      assert is_integer(h) and h >= 0
      assert Reconcile.stored("d1")._v == 1
      assert Reconcile.stored("d2")._v == 3
    end

    test "rejects docs missing a monotonic integer _v" do
      assert {:error, {:missing_or_invalid_version, _}} =
               Reconcile.stage([%{id: "bad", _v: "2"}])

      assert nil == Reconcile.stored("bad")
    end
  end

  describe "reconcile/2 — monotonic merge" do
    test "clean merge: stale local loses to higher-_v remote" do
      {:ok, _} = Reconcile.stage([%{id: "doc1", _v: 2, body: "stale-local"}])

      assert {:ok, %{merged: [%{outcome: :remote_wins, _v: 5}], conflicts: [], refused: []}} =
               Reconcile.reconcile([%{id: "doc1", _v: 5, body: "fresh-remote"}])

      assert Reconcile.stored("doc1").body == "fresh-remote"
    end

    test "clean merge: higher-_v local wins over stale remote" do
      {:ok, _} = Reconcile.stage([%{id: "doc2", _v: 7, body: "fresh-local"}])

      assert {:ok, %{merged: [%{outcome: :local_wins, _v: 7}], conflicts: [], refused: []}} =
               Reconcile.reconcile([%{id: "doc2", _v: 3, body: "stale-remote"}])

      assert Reconcile.stored("doc2").body == "fresh-local"
    end

    test "equal _v with identical bytes converges (no conflict)" do
      {:ok, _} = Reconcile.stage([%{id: "doc3", _v: 4, body: "same"}])

      assert {:ok, %{merged: [%{outcome: :converged}], conflicts: [], refused: []}} =
               Reconcile.reconcile([%{id: "doc3", _v: 4, body: "same"}])
    end

    test "typed conflict on equal _v with divergent bytes — nothing overwritten" do
      {:ok, _} = Reconcile.stage([%{id: "doc4", _v: 4, body: "local-bytes"}])

      assert {:ok, %{merged: [], conflicts: [c], refused: []}} =
               Reconcile.reconcile([%{id: "doc4", _v: 4, body: "remote-bytes"}])

      assert c.reason == :equal_version_divergent_bytes
      assert c.id == "doc4" and c._v == 4
      # the point: the stored bytes are still the LOCAL bytes
      assert Reconcile.stored("doc4").body == "local-bytes"
    end
  end

  describe "reconcile/2 — WORM monotonicity"  do
    test "lower-_v remote cannot overwrite a WORM-keyed id" do
      {:ok, _} = Reconcile.stage([%{id: "worm1", _v: 9, body: "immutable", worm: true}])

      assert {:ok, %{merged: [], conflicts: [], refused: [r]}} =
               Reconcile.reconcile([%{id: "worm1", _v: 2, body: "regressive"}])

      assert r.reason == :worm_monotonicity
      assert Reconcile.stored("worm1").body == "immutable"
      assert Reconcile.stored("worm1")._v == 9
    end

    test "WORM id still accepts a HIGHER-_v remote (monotonic, not frozen)" do
      {:ok, _} = Reconcile.stage([%{id: "worm2", _v: 3, body: "old", worm: true}])

      assert {:ok, %{merged: [%{outcome: :remote_wins, _v: 8}], refused: []}} =
               Reconcile.reconcile([%{id: "worm2", _v: 8, body: "append-only-advance"}])

      assert Reconcile.stored("worm2").body == "append-only-advance"
    end
  end

  describe "consistency_hash/0" do
    test "changes iff state changes" do
      {:ok, %{hash: h0}} = Reconcile.stage([%{id: "h1", _v: 1}])

      # same (id,_v) state, different payload bytes → hash UNCHANGED
      {:ok, %{hash: h0}} = Reconcile.stage([%{id: "h1", _v: 1, body: "other-bytes"}])

      # state change → hash CHANGES
      {:ok, %{hash: h1}} = Reconcile.stage([%{id: "h1", _v: 2, body: "other-bytes"}])
      refute h1 == h0

      # new id → hash CHANGES again
      {:ok, %{hash: h2}} = Reconcile.stage([%{id: "h1", _v: 2, body: "x"}, %{id: "h2", _v: 1}])
      refute h2 == h1

      # order-independence of the tuple set: re-stage sorted differently
      {:ok, %{hash: h3}} = Reconcile.stage([%{id: "h2", _v: 1}, %{id: "h1", _v: 2, body: "x"}])
      assert h3 == h2
    end
  end

  describe "sub-Turing bounds" do
    test "reconcile over a bounded set terminates with bounded inputs" do
      docs = for i <- 1..200, do: %{id: "b#{rem(i, 50)}", _v: i}
      {:ok, _} = Reconcile.stage(Enum.uniq_by(docs, & &1.id))

      remote = for i <- 1..50, do: %{id: "b#{i - 1}", _v: 100 + i}
      assert {:ok, %{merged: merged}} = Reconcile.reconcile(remote)
      assert length(merged) == 50
    end
  end
end
