defmodule Smalt.Telemetry.AffidavitOcelEmitTest do
  @moduledoc """
  The `affidavit.seal` emission laws, end to end on real collaborators:
  a real `affidavit.seal` event appends into a scratch NDJSON sink and
  the assembled document closes references; plus the registry anti-vacuity
  flip: a mutated event type is dropped, never admitted.
  """

  use ExUnit.Case, async: false

  alias Smalt.Telemetry.AffidavitOcel
  alias Smalt.Telemetry.OcelNdjson

  setup do
    dir = Path.join("tmp", "ocel-affidavit-test-#{System.system_time(:millisecond)}")
    File.mkdir_p!(dir)
    prev = Application.get_env(:smalt, :ocel_dir)
    Application.put_env(:smalt, :ocel_dir, dir)
    log = Path.join(dir, "events.ndjson")

    on_exit(fn ->
      if prev,
        do: Application.put_env(:smalt, :ocel_dir, prev),
        else: Application.delete_env(:smalt, :ocel_dir)

      File.rm_rf!(dir)
    end)

    {:ok, log: log}
  end

  test "seal emits one affidavit.seal event passing the registry gate" do
    assert Smalt.Ocel.EventRegistry.event_type?("affidavit.seal")

    assert {:ok, _} =
             AffidavitOcel.seal(
               subject_sha: "a3f1e2d4c5b6a7f8e9d0c1b2a3f4e5d6c7b8a9f0e1d2c3b4a5f6e7d8c9b0a1f2",
               verdict: "admitted",
               engine_hash: "blake3:deadbeef"
             )

    assert {:ok, doc} = OcelNdjson.read_document(log_path())
    assert [%{"type" => "affidavit.seal"} = event] = doc["ocel:events"]

    assert event["attributes"]["subject_sha"] ==
             "a3f1e2d4c5b6a7f8e9d0c1b2a3f4e5d6c7b8a9f0e1d2c3b4a5f6e7d8c9b0a1f2"

    assert event["attributes"]["verdict"] == "admitted"
    assert event["attributes"]["engine_hash"] == "blake3:deadbeef"

    assert [
             %{
               "id" =>
                 "document/affidavit/a3f1e2d4c5b6a7f8e9d0c1b2a3f4e5d6c7b8a9f0e1d2c3b4a5f6e7d8c9b0a1f2",
               "type" => "document"
             }
           ] =
             doc["ocel:objects"]

    for rel <- event["relationships"] do
      assert rel["objectId"] in Enum.map(doc["ocel:objects"], & &1["id"])
    end
  end

  test "registry gate is non-vacuous: a mutated event type is dropped, not admitted" do
    # Flip: forge an affidavit.seal event with an off-vocabulary type
    # straight at the sink; the gate must refuse it.
    forged = %{
      "id" => "ev-affidavit-forged",
      "type" => "affidavit.seal.MUTATED",
      "time" => "2026-10-16T00:00:00Z",
      "attributes" => %{"subject_sha" => "ff", "verdict" => "admitted", "engine_hash" => "x"},
      "relationships" => []
    }

    assert {:ok, :dropped} = OcelNdjson.append(forged, [])
    refute Smalt.Ocel.EventRegistry.event_type?("affidavit.seal.MUTATED")
    refute File.exists?(log_path())
  end

  test "emitter is fail-safe: an unwritable sink path drops, never raises" do
    Application.put_env(:smalt, :ocel_dir, "/proc/definitely-not-writable-lane606")

    assert {:error, _} =
             AffidavitOcel.seal(subject_sha: "ab", verdict: "refused", engine_hash: "h")

    assert {:error, _} =
             AffidavitOcel.seal(subject_sha: "ab", verdict: "admitted", engine_hash: "h")
  end

  defp log_path, do: Path.join(Application.fetch_env!(:smalt, :ocel_dir), "events.ndjson")
end
