defmodule Smalt.SemanticEpochTest do
  use ExUnit.Case, async: false

  # Chicago-style: the timeline reads REAL receipt ledgers, the REAL pack
  # lock, and a REAL deviation ledger admitted through the production
  # DeviationAdmission.admit/2 — fixture copies are byte-copies of the
  # real files on disk, not stubs.

  @receipts_dir Path.join([".ggen_igniter", "receipts"])
  @pack_lock "ggen_igniter.pack.lock"

  setup do
    tmp = Path.join(System.tmp_dir!(), "smalt-epoch-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "receipts"))

    # Seed fixture copies: byte-identical copies of the real receipt ledgers.
    for file <- File.ls!(@receipts_dir), String.ends_with?(file, ".jsonl") do
      File.cp!(Path.join(@receipts_dir, file), Path.join([tmp, "receipts", file]))
    end

    {:ok, tmp: tmp}
  end

  describe "timeline/0 over real receipt files" do
    test "projects one epoch row per receipt, ascending and stable", %{tmp: tmp} do
      {:ok, tl} =
        Smalt.Projection.SemanticEpoch.timeline(
          receipts_dir: Path.join(tmp, "receipts"),
          pack_lock: @pack_lock,
          deviations_path: Path.join(tmp, "deviations.jsonl")
        )

      expected_count =
        Path.join(tmp, "receipts")
        |> File.ls!()
        |> Enum.map(&File.read!(Path.join([tmp, "receipts", &1])))
        |> Enum.flat_map(&String.split(&1, "\n", trim: true))
        |> length()

      assert length(tl.epochs) == expected_count

      keys = Enum.map(tl.epochs, &{&1.started_at, &1.id})

      assert Enum.chunk_every(keys, 2, 1, :discard)
             |> Enum.all?(fn [{t1, _}, {t2, _}] -> DateTime.compare(t1, t2) != :gt end),
             "timeline not in ascending started_at order"

      assert Enum.uniq(Enum.map(tl.epochs, & &1.id)) == Enum.map(tl.epochs, & &1.id)

      # Stable across repeated calls over an unchanged tree.
      {:ok, tl2} =
        Smalt.Projection.SemanticEpoch.timeline(
          receipts_dir: Path.join(tmp, "receipts"),
          pack_lock: @pack_lock,
          deviations_path: Path.join(tmp, "deviations.jsonl")
        )

      assert tl.epochs == tl2.epochs
    end

    test "marks digest drift against the locked pack digest", %{tmp: tmp} do
      {:ok, tl} =
        Smalt.Projection.SemanticEpoch.timeline(
          receipts_dir: Path.join(tmp, "receipts"),
          pack_lock: @pack_lock,
          deviations_path: Path.join(tmp, "deviations.jsonl")
        )

      alive = Enum.filter(tl.epochs, &(&1.standing == "alive"))
      assert alive != []

      # Contract re-cut (F16): the projection is read-only over the REAL
      # ledger. Since 2026-10-15 the shared ledger also carries alive
      # receipts from other packs' syncs over this checkout (e.g.
      # ash-extension-pack) whose writer path does not stamp `pack_name` —
      # those project faithfully as :no_pack. Only pack-stamped alive rows
      # are held to the digest-drift contract against the smalt lock.
      stamped = Enum.filter(alive, &is_binary(&1.pack_name))
      assert stamped != []

      for row <- stamped do
        assert row.pack_name == "smalt-substrate-pack"
        assert is_binary(row.pack_digest)
        assert row.lock_digest == "70a135be75786a82fc722a5bd6c4304e56ad93708a282b3411daac32ac1e0d98"
        assert row.drift_status == :digest_drift
        assert row.drift
      end

      # Alive-but-unstamped rows must NOT silently read as drift-free: the
      # projection marks them :no_pack (a real drift signal, not a pass).
      for row <- Enum.reject(alive, &is_binary(&1.pack_name)) do
        assert row.pack_name == nil
        assert row.lock_digest == nil
        assert row.drift_status == :no_pack
        assert row.drift
      end
    end

    test "marks standing drift on build_broken receipts", %{tmp: tmp} do
      {:ok, tl} =
        Smalt.Projection.SemanticEpoch.timeline(
          receipts_dir: Path.join(tmp, "receipts"),
          pack_lock: @pack_lock,
          deviations_path: Path.join(tmp, "deviations.jsonl")
        )

      broken = Enum.filter(tl.epochs, &(&1.standing == "build_broken"))
      assert broken != []

      for row <- broken do
        assert row.drift
        assert row.drift_status == :standing_drift
        assert row.pack_name == nil
      end
    end

    test "carries the real pack lock digest map", %{tmp: tmp} do
      {:ok, tl} =
        Smalt.Projection.SemanticEpoch.timeline(
          receipts_dir: Path.join(tmp, "receipts"),
          pack_lock: @pack_lock,
          deviations_path: Path.join(tmp, "deviations.jsonl")
        )

      assert tl.pack_lock == %{
               "smalt-substrate-pack" =>
                 "70a135be75786a82fc722a5bd6c4304e56ad93708a282b3411daac32ac1e0d98"
             }
    end

    test "includes deviations admitted through the real admission path", %{tmp: tmp} do
      dev_path = Path.join(tmp, "deviations.jsonl")

      {:ok, id} =
        Smalt.Ocel.DeviationAdmission.admit(
          %{
            conforms: false,
            deviations: [["delete", "insert"]],
            fitness: 0.5
          },
          path: dev_path,
          reference_trace_id: "ref-epoch-test",
          candidate_trace_id: "cand-epoch-test"
        )

      {:ok, tl} =
        Smalt.Projection.SemanticEpoch.timeline(
          receipts_dir: Path.join(tmp, "receipts"),
          pack_lock: @pack_lock,
          deviations_path: dev_path
        )

      assert tl.deviation_count == 1
      assert [%{"id" => ^id, "deviatingMove" => "delete/insert"}] = tl.deviations
    end
  end
end
