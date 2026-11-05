# AoQ micro-batch admission court (lane 9, v26.11.6). Real collaborators:
# the REAL pinned GraphLaw wasm engine (same setup law as the G2 canonical
# shapes court) for the admit/violation/bisect/mutation legs, and the
# :shacl_module court seam for the engine-absent leg -- the seam
# ShaclAdmission documents, never a default.
defmodule Smalt.Aoq.AdmissionTest do
  use ExUnit.Case, async: false

  alias Smalt.Aoq.Admission
  alias Smalt.GraphlawEx.ShaclAdmission

  @manifest_path "/Users/sac/ash_graphlaw/priv/graphlaw/MANIFEST.json"
  @corpus Path.join(File.cwd!(), "test/fixtures/aoq_admission")

  @conforming File.read!(Path.join(@corpus, "conforming_frame.ttl"))
  @violating_crc File.read!(Path.join(@corpus, "violating_crc.ttl"))
  @violating_oov File.read!(Path.join(@corpus, "violating_oov.ttl"))

  defmodule StubShacl do
    # Engine-absent leg: the documented :shacl_module court seam (never a
    # default). Mimics AshGraphLaw.Capability.Shacl.run/2's result shape.
    def run(_args, _opts), do: {:ok, %{conforms: true, results: []}}
  end

  setup do
    Application.put_env(:smalt, :aoq_admission, enabled: true, ledger_ttl_ms: 500)

    case ShaclAdmission.pin() do
      nil -> flunk("MANIFEST.json unreadable at #{@manifest_path} - fail-closed, refusing to run")
      digest -> assert is_binary(digest) and byte_size(digest) == 64
    end

    Application.put_env(:smalt, :graphlaw_shacl, manifest_path: @manifest_path)

    name =
      Module.concat([to_string(__MODULE__), "Host", Integer.to_string(System.unique_integer([:positive]))])

    with {:ok, pid} <- AshGraphLaw.Host.start_link(name: name),
         true <- AshGraphLaw.Host.available?(name) do
      Process.put(:engine_opts, [server: pid])
      %{engine_opts: [server: pid]}
    else
      {:error, refusal} -> flunk("REAL engine unavailable: " <> inspect(refusal))
      false -> flunk("engine host started but never became available")
    end
  end

  setup :clean_ledger

  defp clean_ledger(_ctx) do
    case :ets.whereis(:smalt_aoq_admission_ledger) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(:smalt_aoq_admission_ledger)
    end

    :ok
  end

  defp engine_opts, do: Process.get(:engine_opts) || raise("no engine_opts")

  # -- fold wire form ---------------------------------------------------------

  test "encode_fold round-trips the length-prefixed wire form" do
    assert Admission.encode_fold([<<"a">>, <<"bc">>]) == <<0, 0, 0, 1, "a", 0, 0, 0, 2, "bc">>
    assert Admission.encode_fold([]) == <<>>
  end

  test "batch_max is the 32-frame micro-batch cap" do
    assert Admission.batch_max() == 32
  end

  test "admit_batch of a non-list refuses typed" do
    assert {:refused, :smalt_aoq_batch_not_list, %{frames_class: :other}} =
             Admission.admit_batch(:nope)
  end

  # -- conformance corpus (fixtures + manifest) -------------------------------

  test "conformance corpus: per-file verdict matches the manifest" do
    for {file, expected} <- corpus_manifest() do
      body = File.read!(Path.join(@corpus, file))

      verdict = Admission.admit_batch([body], engine_opts: engine_opts())

      case expected do
        :admit -> assert {:ok, %{admitted: true, frame_count: 1}} = verdict, "file: " <> file
        code -> assert {:refused, ^code, _} = verdict, "file: " <> file
      end
    end
  end

  test "mixed batch attributes only the violating frame via bisect" do
    frames = uniquify([@conforming, @conforming, @violating_crc, @conforming])

    assert {:refused, :smalt_shacl_violation, %{violating_frames: violating}} =
             Admission.admit_batch(frames, engine_opts: engine_opts())

    assert [{2, _bad_frame}] = violating
  end

  # -- mutation flip court (flip -> refuse -> flip back -> admit) -------------

  test "mutation flip: crc flip refuses, flip-back admits" do
    good = uniquify([@conforming])
    [good_frame] = good
    bad = [String.replace(good_frame, "DEADBEEF", "NOT-HEX!")]

    assert {:ok, _} = Admission.admit_batch(good, engine_opts: engine_opts())
    assert {:refused, :smalt_shacl_violation, %{violating_frames: [{0, _bad}]}} =
             Admission.admit_batch(bad, engine_opts: engine_opts())

    # flip-back with a DIFFERENT conforming frame list: the pre-flip admit
    # already holds the `good` receipt in the TTL ledger, so an identical
    # re-admit is a replay refusal (the ledger law, proved above) — the
    # flip-back leg proves the FLIP was the refusal cause, not a stale entry.
    good_again = uniquify([@conforming])
    assert {:ok, _} = Admission.admit_batch(good_again, engine_opts: engine_opts())
  end

  # -- receipt law -------------------------------------------------------------

  test "batch receipt is fresh per frame list (never the folded run's receipt)" do
    a = uniquify([@conforming])
    b = uniquify([@conforming])
    {:ok, ra} = Admission.admit_batch(a, engine_opts: engine_opts())
    {:ok, rb} = Admission.admit_batch(b, engine_opts: engine_opts())
    two = uniquify([@conforming, @conforming])
    {:ok, r2} = Admission.admit_batch(two, engine_opts: engine_opts())

    assert ra.receipt_sha256 != rb.receipt_sha256
    assert byte_size(ra.receipt_sha256) == 64
    assert ra.receipt_sha256 != r2.receipt_sha256
    assert ra.frame_count == 1
    assert r2.frame_count == 2 and length(r2.frame_hashes) == 2
  end

  test "replay of the exact batch refuses with :smalt_receipt_replay_fail" do
    frames = uniquify([@conforming])
    assert {:ok, _} = Admission.admit_batch(frames, engine_opts: engine_opts())

    assert {:refused, :smalt_receipt_replay_fail, %{receipt_blake3: r}} =
             Admission.admit_batch(frames, engine_opts: engine_opts())

    assert is_binary(r) and byte_size(r) == 64
  end

  test "ledger TTL window lets a stale entry re-admit" do
    frames = uniquify([@conforming])
    {:ok, %{receipt_sha256: receipt}} = Admission.admit_batch(frames, engine_opts: engine_opts())

    # age the single entry past the 500 ms TTL window (setup pins ledger_ttl_ms: 500)
    :ets.insert(:smalt_aoq_admission_ledger, {receipt, System.system_time(:millisecond) - 5_000})
    assert {:ok, _} = Admission.admit_batch(frames, engine_opts: engine_opts())
  end

  # -- config passthrough (independent config key :aoq_admission) --------------

  test "enabled: false is an explicit passthrough before any engine call" do
    Application.put_env(:smalt, :aoq_admission, enabled: false)

    assert {:ok, %{admitted: false, passthrough: true, frame_count: 1}} =
             Admission.admit_batch(uniquify([@violating_crc]))
  after
    Application.put_env(:smalt, :aoq_admission, enabled: true, ledger_ttl_ms: 500)
  end

  # -- engine-absent leg via the :shacl_module court seam ----------------------

  test "engine-absent leg: :shacl_module seam admits a conforming batch without the wasm engine" do
    assert {:ok, %{admitted: true, frame_count: 1}} =
             Admission.admit_batch(uniquify([@conforming]),
               shacl_module: StubShacl,
               engine_digest: String.duplicate("a", 64)
             )
  end

  test "engine-absent leg: the seam never becomes a default (absent opt + no engine = engine_absent)" do
    # No :engine_opts and no default AshGraphLaw.Host started under the
    # default name -> the REAL engine call fails; the seam path is opt-only.
    # We assert the typed refusal surface, not a crash.
    verdict = Admission.admit_batch(uniquify([@conforming]), shacl_module: nil)

    assert match?({:refused, _, _}, verdict)
  end

  # -- helpers -----------------------------------------------------------------

  defp corpus_manifest do
    {manifest, _binding} = Code.eval_file(Path.join(@corpus, "manifest.exs"))
    manifest
  end

  # uniquify: give every frame a distinct dcterms:identifier and sequence so
  # distinct frame lists never collide on the batch receipt.
  defp uniquify(frames) do
    {frames, _} =
      Enum.map_reduce(frames, 0, fn frame, i ->
        frame =
          frame
          |> String.replace("frame/1", "frame/mutation-#{i}-#{System.unique_integer([:positive])}")
          |> String.replace("\"1:0\"", "\"#{i}:#{System.unique_integer([:positive])}\"")

        {frame, i + 1}
      end)

    frames
  end
end
