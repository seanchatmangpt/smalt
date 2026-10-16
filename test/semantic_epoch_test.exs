defmodule Smalt.SemanticEpochTest do
  use ExUnit.Case, async: false

  # Chicago-style: the timeline reads REAL receipt ledgers, the REAL pack
  # lock, and a REAL deviation ledger admitted through the production
  # DeviationAdmission.admit/2 — fixture copies are byte-copies of the
  # real files on disk, not stubs.

  @receipts_dir Path.join([".ggen_igniter", "receipts"])
  @pack_lock "ggen_igniter.pack.lock"

  setup do
    # Cross-lane collision fence: System.unique_integer/1 is per-VM only.
    # Two concurrent lane VMs on this checkout can mint the same integer and
    # share one fixture dir (witnessed: deviation_count 2-vs-1 flake), so the
    # name also carries a wall-clock/monotonic component that differs across
    # processes.
    tmp =
      Path.join(
        System.tmp_dir!(),
        "smalt-epoch-test-#{System.system_time(:native)}-#{System.unique_integer([:positive])}"
      )
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
        assert row.lock_digest == lock_digest()

        # The projection derives drift from the digest comparison itself.
        # Since the pack re-sync the real ledger carries BOTH classes of
        # alive stamped rows (in-sync -> :ok, drifted -> :digest_drift), so
        # the pinned contract is derivation correctness, not a fixed class:
        # drift_status is :digest_drift iff pack_digest != lock_digest, and
        # the boolean `drift` mirrors drift_status exactly.
        expected = if row.pack_digest == lock_digest(), do: :ok, else: :digest_drift
        assert row.drift_status == expected
        assert row.drift == (expected == :digest_drift)
      end

      # Both classes must be derivable over the real ledger as it stands:
      # the drifted rows prove detection fires, the in-sync rows prove the
      # detector is not pinned to always-drift (a vacuous :digest_drift).
      # This pair depends on the ledger continuing to carry receipts from
      # BOTH lock eras; a deliberate ledger cleanup (e.g. pre-re-lock
      # receipt retirement) drops the :digest_drift half and must update
      # this pin (or narrow it to the surviving classes) in the same change.
      assert Enum.any?(stamped, &(&1.drift_status == :digest_drift))
      assert Enum.any?(stamped, &(&1.drift_status == :ok))

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

      assert tl.pack_lock == %{"smalt-substrate-pack" => lock_digest()}
    end

    test "mutation fences: a degraded ledger (stamped/unstamped/tampered) is caught", %{tmp: tmp} do
      # Mutation court for the cycle-1 re-cut contract: perturb the pack
      # identity of a REAL pack-stamped receipt and prove the projection's
      # drift fences catch every class.
      stamped_path = Path.join([tmp, "receipts", "2026-10-14.jsonl"])
      assert File.exists?(stamped_path), "pack-stamped ledger fixture missing"

      original = File.read!(stamped_path)
      [stamped_receipt] = original |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      assert stamped_receipt["pack_name"] == "smalt-substrate-pack"

      timeline_for = fn receipts ->
        dir = Path.join(tmp, "mutation-#{System.unique_integer([:positive])}")
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "mutation.jsonl"), receipts)

        {:ok, tl} =
          Smalt.Projection.SemanticEpoch.timeline(
            receipts_dir: dir,
            pack_lock: @pack_lock,
            deviations_path: Path.join(tmp, "deviations.jsonl")
          )

        tl.epochs
      end

      encode = &Jason.encode_to_iodata!(&1)

      ## Mutation 1: stamp wiped (pack_name deleted) -> :no_pack drift.
      wiped = Map.delete(stamped_receipt, "pack_name")

      assert [row] = timeline_for.([encode.(wiped)])
      assert row.pack_name == nil
      assert row.lock_digest == nil
      assert row.drift_status == :no_pack
      assert row.drift

      ## Mutation 2: stamp forged to a pack the lock does not admit
      ## -> :no_pack drift (never a silent pass).
      forged = Map.put(stamped_receipt, "pack_name", "not-a-locked-pack")

      assert [row] = timeline_for.([encode.(forged)])
      assert row.pack_name == "not-a-locked-pack"
      assert row.lock_digest == nil
      assert row.drift_status == :no_pack
      assert row.drift

      ## Mutation 3: digest tampered under a valid stamp -> :digest_drift.
      tampered = Map.put(stamped_receipt, "pack_digest", String.duplicate("0", 64))

      assert [row] = timeline_for.([encode.(tampered)])
      assert row.pack_name == "smalt-substrate-pack"
      assert row.lock_digest == lock_digest()
      assert row.drift_status == :digest_drift
      assert row.drift

      ## Control: the unperturbed receipt stays :digest_drift (real 10-14
      ## digest differs from lock) — the mutation court only flips the
      ## mutated classes, never the honest row.
      assert [row] = timeline_for.([encode.(stamped_receipt)])
      assert row.drift_status == :digest_drift
      assert row.drift
    end

    test "parser fuzz: malformed/truncated/duplicate ledgers refuse, never crash", %{tmp: tmp} do
      timeline_for = fn body ->
        dir = Path.join(tmp, "fuzz-#{System.unique_integer([:positive])}")
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "fuzz.jsonl"), body)

        Smalt.Projection.SemanticEpoch.timeline(
          receipts_dir: dir,
          pack_lock: @pack_lock,
          deviations_path: Path.join(tmp, "deviations.jsonl")
        )
      end

      good = ~s({"id": "rcpt_good", "standing": "alive", "started_at": "2026-10-15T00:00:00Z"})

      ## Malformed middle line -> typed refusal with file + line location.
      assert {:error, {:malformed_receipt, path, 2, %Jason.DecodeError{}}} =
               timeline_for.(good <> "\n{broken json\n" <> good)

      assert path =~ "fuzz.jsonl"

      ## Truncated last line (no trailing newline, partial JSON) -> refusal.
      assert {:error, {:malformed_receipt, _, _, %Jason.DecodeError{}}} =
               timeline_for.(good <> "\n{\"id\": \"rcpt_trunc")

      ## Duplicate receipt ids -> typed refusal (double-admission).
      assert {:error, {:duplicate_receipt_id, "rcpt_dup"}} =
               timeline_for.(good <> "\n" <> String.replace(good, "rcpt_good", "rcpt_dup") <>
                               "\n" <> String.replace(good, "rcpt_good", "rcpt_dup"))

      ## Lens-2 cycle 2: receipt with a null/missing id -> typed refusal
      ## (R_missing_identity). Previously two id-less receipts BOTH projected
      ## because the dup check filtered to binaries first.
      assert {:error, {:receipt_missing_id, nil}} =
               timeline_for.(~s({"id": null, "standing": "alive", "started_at": "2026-10-15T00:00:00Z"}))

      assert {:error, {:receipt_missing_id, 7}} =
               timeline_for.(~s({"id": 7, "standing": "alive", "started_at": "2026-10-15T00:00:00Z"}))

      ## Out-of-order timestamps normalize: output ascending, no crash.
      later = String.replace(good, "rcpt_good", "rcpt_late") |> String.replace("00:00:00", "01:00:00")

      assert {:ok, tl} = timeline_for.(later <> "\n" <> good)

      started = Enum.map(tl.epochs, & &1.started_at)

      assert Enum.chunk_every(started, 2, 1, :discard)
             |> Enum.all?(fn [t1, t2] -> DateTime.compare(t1, t2) != :gt end)

      ## Missing receipts dir -> typed refusal, not an empty timeline.
      ## Lens-6 cycle 4: located — the refusal now NAMES the dir.
      assert {:error, {:receipt_unreadable, dir, :enoent}} =
               Smalt.Projection.SemanticEpoch.timeline(
                 receipts_dir: Path.join(tmp, "nope"),
                 pack_lock: @pack_lock,
                 deviations_path: Path.join(tmp, "deviations.jsonl")
               )

      assert dir == Path.join(tmp, "nope")
               Smalt.Projection.SemanticEpoch.timeline(
                 receipts_dir: Path.join(tmp, "nope"),
                 pack_lock: @pack_lock,
                 deviations_path: Path.join(tmp, "deviations.jsonl")
               )

      ## Malformed DEVIATIONS ledger -> typed refusal (boundary adapter over
      ## DeviationAdmission.read_all/1's Jason.decode! raise).
      dev_dir = Path.join(tmp, "dev-fuzz")
      File.mkdir_p!(Path.join(dev_dir, "receipts"))
      File.write!(Path.join(dev_dir, "bad-dev.jsonl"), "{not json\n")
      File.write!(Path.join([dev_dir, "receipts", "r.jsonl"]), good)

      assert {:error, {:malformed_deviation, _, %Jason.DecodeError{}}} =
               Smalt.Projection.SemanticEpoch.timeline(
                 receipts_dir: Path.join(dev_dir, "receipts"),
                 pack_lock: @pack_lock,
                 deviations_path: Path.join(dev_dir, "bad-dev.jsonl")
               )
    end

    @tag :scale
    test "scale fuzz: 10k-line ledger — determinism, dup pin at scale, perf budget", %{tmp: tmp} do
      line = fn i ->
        mm = i |> div(60) |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")
        ss = i |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")

        "{\"id\": \"R#{i}\", \"standing\": \"alive\", " <>
          "\"started_at\": \"2026-10-15T00:#{mm}:#{ss}Z\"}"
      end

      # 10k UNIQUE receipts: parses, projects 10k epochs, sorted, deterministic.
      uniq_dir = Path.join(tmp, "scale-uniq")
      File.mkdir_p!(uniq_dir)
      File.write!(Path.join(uniq_dir, "scale.jsonl"), Enum.map_join(1..10_000, "\n", line))

      {t_uniq, {:ok, tl}} =
        :timer.tc(fn ->
          Smalt.Projection.SemanticEpoch.timeline(
            receipts_dir: uniq_dir,
            pack_lock: @pack_lock,
            deviations_path: Path.join(tmp, "deviations.jsonl")
          )
        end)

      assert length(tl.epochs) == 10_000
      assert Enum.uniq(Enum.map(tl.epochs, & &1.id)) == Enum.map(tl.epochs, & &1.id)

      assert Enum.chunk_every(tl.epochs, 2, 1, :discard)
             |> Enum.all?(fn [a, b] ->
               case DateTime.compare(a.started_at, b.started_at) do
                 :eq -> a.id <= b.id
                 :lt -> true
                 :gt -> false
               end
             end)

      {t_re, {:ok, tl2}} =
        :timer.tc(fn ->
          Smalt.Projection.SemanticEpoch.timeline(
            receipts_dir: uniq_dir,
            pack_lock: @pack_lock,
            deviations_path: Path.join(tmp, "deviations.jsonl")
          )
        end)

      assert tl.epochs == tl2.epochs, "10k-line repeat projection not deterministic"

      # 10k line ledger with ONE duplicate (R8999 repeated at line 9,000)
      # -> typed refusal, and the reported id is the ACTUAL dup, not a neighbor.
      dup_dir = Path.join(tmp, "scale-dup")
      File.mkdir_p!(dup_dir)

      File.write!(
        Path.join(dup_dir, "scale.jsonl"),
        Enum.map_join(1..10_000, "\n", fn i -> line.(if(i == 9_000, do: 8_999, else: i)) end)
      )

      {t_dup, {:error, {:duplicate_receipt_id, dup_id}}} =
        :timer.tc(fn ->
          Smalt.Projection.SemanticEpoch.timeline(
            receipts_dir: dup_dir,
            pack_lock: @pack_lock,
            deviations_path: Path.join(tmp, "deviations.jsonl")
          )
        end)

      assert dup_id == "R8999"

      # 10k line ledger, malformed LAST line -> typed refusal with exact line no.
      bad_dir = Path.join(tmp, "scale-bad")
      File.mkdir_p!(bad_dir)
      File.write!(Path.join(bad_dir, "scale.jsonl"), Enum.map_join(1..10_000, "\n", line) <> "\n{broken\n")

      assert {:error, {:malformed_receipt, _, 10_001, %Jason.DecodeError{}}} =
               Smalt.Projection.SemanticEpoch.timeline(
                 receipts_dir: bad_dir,
                 pack_lock: @pack_lock,
            deviations_path: Path.join(tmp, "deviations.jsonl")
               )

      # Perf budget: each pass well under 5s.
      assert t_uniq < 5_000_000, "10k unique parse took #{t_uniq}us"
      assert t_re < 5_000_000, "10k re-parse took #{t_re}us"
      assert t_dup < 5_000_000, "10k dup scan took #{t_dup}us"

      File.rm_rf!(uniq_dir)
      File.rm_rf!(dup_dir)
      File.rm_rf!(bad_dir)
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

  # Lens-3 cycle 1: the empty string IS a binary — before the fence it
  # passed the identity check and a single blank-id receipt projected with
  # id "" (zero identity bits). Refused on the R_missing_identity axis,
  # same as a null id. Mutation kill: drop the `id != ""` guard, this test
  # fails ({:ok, timeline} with a blank id row).
  test "blank-string receipt id is refused as missing identity" do
    tmp =
      Path.join(System.tmp_dir!(), "smalt-epoch-blank-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    File.write!(Path.join(tmp, "r.jsonl"), ~s({"id": "", "standing": "alive"}\n))

    assert {:error, {:receipt_missing_id, ""}} =
             Smalt.Projection.SemanticEpoch.timeline(
               receipts_dir: tmp,
               pack_lock: "/nonexistent",
               deviations_path: Path.join(tmp, "dev.jsonl")
             )

    # Fuzz: mixed null / blank / real ids — the blank is refused wherever
    # it sits, and a real-id-only ledger still projects.
    File.write!(
      Path.join(tmp, "r.jsonl"),
      ~s({"id": "real"}\n{"id": null}\n{"id": ""}\n)
    )

    assert {:error, {:receipt_missing_id, bad}} =
             Smalt.Projection.SemanticEpoch.timeline(
               receipts_dir: tmp,
               pack_lock: "/nonexistent",
               deviations_path: Path.join(tmp, "dev.jsonl")
             )

    assert bad in [nil, ""]

    File.write!(Path.join(tmp, "r.jsonl"), ~s({"id": "real"}\n))

    assert {:ok, %{epochs: [%{id: "real"}]}} =
             Smalt.Projection.SemanticEpoch.timeline(
               receipts_dir: tmp,
               pack_lock: "/nonexistent",
               deviations_path: Path.join(tmp, "dev.jsonl")
             )

    File.rm_rf!(tmp)
  end

  # Lens-3 cycle 6: a non-binary timestamp (integer epoch from a tampered
  # receipt) crashed the whole timeline with FunctionClauseError out of
  # DateTime.from_iso8601/1 (kill receipt /tmp/m8.out). The lenient policy
  # (unparseable -> nil -> epoch-0 sort bucket) now covers non-binaries.
  test "non-binary timestamps do not crash the timeline" do
    tmp =
      Path.join(System.tmp_dir!(), "smalt-epoch-ts-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    File.write!(
      Path.join(tmp, "r.jsonl"),
      ~s({"id": "int-ts", "started_at": 123, "finished_at": [1, 2], "standing": "alive"}\n) <>
        ~s({"id": "ok", "started_at": "2026-01-01T00:00:00Z", "standing": "alive"}\n)
    )

    assert {:ok, %{epochs: epochs}} =
             Smalt.Projection.SemanticEpoch.timeline(
               receipts_dir: tmp,
               pack_lock: "/nonexistent",
               deviations_path: Path.join(tmp, "dev.jsonl")
             )

    assert Enum.map(epochs, & &1.id) == ["int-ts", "ok"]
    assert %DateTime{} = hd(epochs).started_at

    File.rm_rf!(tmp)
  end

  # Lens-8 cycle 1 (mutation court, coordinator-routed warnings-gate
  # blocker): parse_ts/1's lenient non-binary clause once sat ABOVE the
  # guarded binary clause, making the binary clause UNREACHABLE — every
  # timestamp folded to nil and the documented started_at sort contract was
  # silently dead. The lens-3 test above survives that mutant (its hd(epochs)
  # row is the int-ts receipt whose started_at is the 1970 default — a
  # DateTime whether or not parse works — and its 2-row id tiebreak gives
  # the same order). This test is the kill: time order CROSSES id order, so
  # only a working parse_ts yields it.
  test "binary timestamps actually parse and drive the started_at sort (mutation-court kill)" do
    tmp = Path.join(System.tmp_dir!(), "smalt-l8-ts-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    File.write!(
      Path.join(tmp, "r.jsonl"),
      ~s({"id": "aaa-late", "started_at": "2026-06-01T00:00:00Z", "standing": "alive"}\n) <>
        ~s({"id": "zzz-early", "started_at": "2020-01-01T00:00:00Z", "standing": "alive"}\n)
    )

    assert {:ok, %{epochs: epochs}} =
             Smalt.Projection.SemanticEpoch.timeline(
               receipts_dir: tmp,
               pack_lock: "/nonexistent",
               deviations_path: Path.join(tmp, "dev.jsonl")
             )

    # Parsed: zzz-early (2020) sorts before aaa-late (2026). Unparsed mutant
    # (both fold to nil -> epoch-0 bucket): id tiebreak gives [aaa, zzz].
    assert Enum.map(epochs, & &1.id) == ["zzz-early", "aaa-late"]
    assert hd(epochs).started_at == ~U[2020-01-01T00:00:00Z]

    File.rm_rf!(tmp)
  end

  # The lock is legitimately re-rolled by pack transitions on the shared
  # checkout (lens-3 cycle 2: 70a135be... -> 83a3bb18... mid-session broke
  # three hardcoded-digest assertions). The expected digest is derived from
  # the lock file itself at test time via an independent Jason decode.
  defp lock_digest do
    %{"packs" => %{"smalt-substrate-pack" => %{"sha256" => digest}}} =
      @pack_lock |> File.read!() |> Jason.decode!()

    digest
  end
end

# Lens-4 cycle 1: the identity fence generalizes to whitespace-only and
# invisible-format-only ids (zero visible identity bits). One shared fence:
# Smalt.Projection.Identity.
defmodule Smalt.Projection.IdentityTest do
  use ExUnit.Case, async: false

  @shared_receipts %{"started_at" => "2026-01-01T00:00:00Z", "standing" => "alive"}

  describe "Smalt.Projection.Identity.valid?/1 (the one fence)" do
    test "refuses non-binaries (2-tuple, list, integer, nil)" do
      Enum.each([{:a, :b}, ["x"], 7, nil], fn bad ->
        refute Smalt.Projection.Identity.valid?(bad), "expected refusal: #{inspect(bad)}"
      end)
    end

    test "refuses blank and whitespace-only binaries" do
      Enum.each(["", " ", "  \t\n", " "], fn bad ->
        refute Smalt.Projection.Identity.valid?(bad), "expected refusal: #{inspect(bad)}"
      end)
    end

    test "refuses invisible-format-only binaries (zero-width, BOM, soft hyphen)" do
      Enum.each(["​", "⁠", "­", "﻿"], fn bad ->
        refute Smalt.Projection.Identity.valid?(bad), "expected refusal: #{inspect(bad)}"
      end)
    end

    test "accepts ids with at least one visible codepoint" do
      assert Smalt.Projection.Identity.valid?("abc")
      assert Smalt.Projection.Identity.valid?("  padded  ")
      assert Smalt.Projection.Identity.valid?("abc​")
    end

    test "semantic_epoch refuses a whitespace-only receipt id (typed)" do
      tmp = Path.join("tmp", "f16L4-ep-ws-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "r.jsonl"), Jason.encode!(Map.put(@shared_receipts, "id", "  \t")) <> "\n")

      assert {:error, {:receipt_missing_id, "  \t"}} =
               Smalt.Projection.SemanticEpoch.timeline(
                 receipts_dir: tmp,
                 pack_lock: "/nonexistent",
                 deviations_path: Path.join(tmp, "dev.jsonl")
               )

      File.rm_rf!(tmp)
    end

    test "semantic_epoch refuses an invisible-format-only receipt id (typed)" do
      tmp = Path.join("tmp", "f16L4-ep-zw-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "r.jsonl"), Jason.encode!(Map.put(@shared_receipts, "id", "​")) <> "\n")

      assert {:error, {:receipt_missing_id, "​"}} =
               Smalt.Projection.SemanticEpoch.timeline(
                 receipts_dir: tmp,
                 pack_lock: "/nonexistent",
                 deviations_path: Path.join(tmp, "dev.jsonl")
               )

      File.rm_rf!(tmp)
    end

    test "semantic_epoch still accepts twin ids that each carry visible bits (identity is byte identity, not rendering)" do
      tmp = Path.join("tmp", "f16L4-ep-twin-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      File.write!(Path.join(tmp, "r.jsonl"),
        Jason.encode!(Map.put(@shared_receipts, "id", "abc")) <> "\n" <>
          Jason.encode!(Map.put(@shared_receipts, "id", "abc​")) <> "\n"
      )

      assert {:ok, %{epochs: epochs}} =
               Smalt.Projection.SemanticEpoch.timeline(
                 receipts_dir: tmp,
                 pack_lock: "/nonexistent",
                 deviations_path: Path.join(tmp, "dev.jsonl")
               )

      assert length(epochs) == 2
      File.rm_rf!(tmp)
    end
  end

  describe "non-map JSONL lines (lens-5 cycle 4)" do
    test "a valid-JSON non-map receipt line refuses typed, never crashes" do
      tmp =
        Path.join(System.tmp_dir!(), "smalt-l5-nonmap-#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(tmp, "receipts"))
      File.write!(
        Path.join([tmp, "receipts", "r.jsonl"]),
        Jason.encode!(%{"id" => "good"}) <> "\n[1,2]\n"
      )

      assert {:error, {:malformed_receipt, path, 2, {:non_map_line, [1, 2]}}} =
               Smalt.Projection.SemanticEpoch.timeline(
                 receipts_dir: Path.join(tmp, "receipts"),
                 pack_lock: "/nonexistent",
                 deviations_path: Path.join(tmp, "dev.jsonl")
               )

      assert String.ends_with?(path, "r.jsonl")
      File.rm_rf!(tmp)
    end
  end
end

# Lens-6 cycle 1: a structurally valid lock with a malformed PACK ENTRY
# (non-map value, list packs, missing/non-binary sha256) previously crashed
# the WHOLE timeline out of the Map.new payload pattern. Lenient fold to
# %{} (the existing missing-lock policy), drift VISIBLE as :no_pack.
defmodule Smalt.Projection.SemanticEpoch.Lens6LockTest do
  use ExUnit.Case, async: false

  @lock_namelist Path.join(System.tmp_dir!(), "smalt-l6-lock-#{System.unique_integer([:positive])}")

  test "malformed pack entries fold the lock to %{} and show :no_pack drift, never crash" do
    dir = @lock_namelist
    File.mkdir_p!(dir)
    receipts = Path.join(dir, "r.jsonl")

    File.write!(
      receipts,
      Jason.encode!(%{
        "id" => "l6-lock",
        "pack_name" => "p",
        "pack_digest" => "deadbeef",
        "standing" => "alive",
        "started_at" => "2026-01-01T00:00:00Z"
      }) <> "\n"
    )

    lock = Path.join(dir, "lock.json")

    Enum.each(
      [
        ~s({"packs": {"p": "just-a-string"}}),
        ~s({"packs": [1, 2]}),
        ~s({"packs": {"p": {"sha256": 5}}}),
        # Lens-7 cycle 2: one malformed + one WELL-FORMED entry. Skipping the
        # bad entry (mutant) would leave "good" locked and this assertion
        # fails — the whole-lock fold is what this case pins.
        ~s({"packs": {"good": {"sha256": "cafe"}, "p": "junk"}})
      ],
      fn body ->
        File.write!(lock, body)

        assert {:ok, %{pack_lock: lock_map, epochs: [epoch]}} =
                 Smalt.Projection.SemanticEpoch.timeline(
                   receipts_dir: dir,
                   pack_lock: lock,
                   deviations_path: Path.join(dir, "dev.jsonl")
                 )

        assert lock_map == %{}
        assert epoch.drift_status == :no_pack
        assert epoch.drift == true
      end
    )

    File.rm_rf!(dir)
  end

  test "a well-formed lock still pins digests (fence does not over-refuse)" do
    dir = @lock_namelist <> "-good"
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "r.jsonl"), Jason.encode!(%{"id" => "g", "standing" => "alive"}) <> "\n")
    lock = Path.join(dir, "lock.json")
    File.write!(lock, ~s({"packs": {"p": {"sha256": "cafe"}}}))

    assert {:ok, %{pack_lock: %{"p" => "cafe"}, epochs: [epoch]}} =
             Smalt.Projection.SemanticEpoch.timeline(
               receipts_dir: dir,
               pack_lock: lock,
               deviations_path: Path.join(dir, "dev.jsonl")
             )

    assert epoch.drift_status == :no_pack
    File.rm_rf!(dir)
  end
end
