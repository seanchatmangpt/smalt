defmodule Smalt.Telemetry.CourtOcelTest do
  @moduledoc """
  The `doctor.receipt` / `court.run` emission laws, end to end on real
  collaborators: real doctor receipts and real court-log judge logic
  append registry-gated events into a scratch NDJSON sink; the assembled
  document closes references. Includes the registry anti-vacuity flip:
  an unknown event type is dropped, never admitted.
  """

  use ExUnit.Case, async: false

  alias Smalt.Telemetry.CourtOcel
  alias Smalt.Telemetry.OcelNdjson

  setup do
    dir = Path.join("tmp", "ocel-court-test-#{System.system_time(:millisecond)}")
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

  test "doctor_receipt emits one doctor.receipt event with enclave + document objects" do
    receipt = %{
      "status" => "PASS",
      "checks" => [
        %{"code" => "DR-HCL", "status" => "PASS"},
        %{"code" => "DR-REG", "status" => "WARN"}
      ]
    }

    assert {:ok, _} = CourtOcel.doctor_receipt(receipt, "/tmp/smalt-doctor.json")

    assert {:ok, doc} = OcelNdjson.read_document(log_path())
    assert [%{"type" => "doctor.receipt"} = event] = doc["ocel:events"]

    assert event["attributes"]["status"] == "PASS"
    assert event["attributes"]["checks"] == %{"DR-HCL" => "PASS", "DR-REG" => "WARN"}

    types = doc["ocel:objects"] |> Enum.map(& &1["type"]) |> Enum.sort()
    assert types == ["document", "enclave"]

    for rel <- event["relationships"] do
      assert rel["objectId"] in Enum.map(doc["ocel:objects"], & &1["id"])
    end
  end

  test "court_run emits one court.run event with stages, verdicts, run" do
    assert {:ok, _} = CourtOcel.court_run([run: 2, verdict: "green", stages: "test,bench"], "/tmp/court.log")

    assert {:ok, doc} = OcelNdjson.read_document(log_path())
    assert [%{"type" => "court.run"} = event] = doc["ocel:events"]
    assert event["attributes"]["stages"] == ["test", "bench"]
    assert event["attributes"]["verdicts"] == %{"court" => "green"}
    assert event["attributes"]["run"] == 2
    assert [%{"id" => "document//tmp/court.log", "type" => "document"}] = doc["ocel:objects"]
  end

  test "registry gate is non-vacuous: an unknown event type is dropped, not admitted" do
    # Flip: forge an event with an off-vocabulary type straight at the sink.
    forged = %{
      "id" => "ev-forged",
      "type" => "doctor.receipt.MUTATED",
      "time" => "2026-10-16T00:00:00Z",
      "attributes" => %{},
      "relationships" => []
    }

    assert {:ok, :dropped} = OcelNdjson.append(forged, [])
    refute File.exists?(log_path())
  end

  test "court_emit task judges a synthetic green receipt and emits court.run" do
    receipt = Path.join("tmp", "court-emit-test-#{System.system_time(:millisecond)}.log")
    File.write!(receipt, "all good\n327 tests, 0 failures\n")

    Mix.Task.run("smalt.court_emit", ["--receipt", receipt, "--run", "1"])

    assert {:ok, doc} = OcelNdjson.read_document(log_path())
    assert [%{"type" => "court.run"} = event] = doc["ocel:events"]
    assert event["attributes"]["verdicts"] == %{"court" => "green"}
    assert event["attributes"]["run"] == 1
  end

  defp log_path, do: Path.join(Application.fetch_env!(:smalt, :ocel_dir), "events.ndjson")
end
