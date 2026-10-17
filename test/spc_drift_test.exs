defmodule Smalt.Spc.DriftTest do
  # The emitter writes through the shared :smalt_event_messages table and the
  # gate appends to its rolling history file — both are process-global.
  use ExUnit.Case, async: false

  alias Smalt.Spc.Drift
  alias Smalt.Store

  @metric "native_stage_ms.parse"
  # 300 rolling rows alternating 95/105 swamp the canonical bands.yaml seeded
  # history (4 receipt points), so the prior series is effectively ours and
  # the probe-calibrated z lands where we aim.
  @rolling_count 300

  setup do
    dir = Path.join("tmp", "spc-drift-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    history = Path.join(dir, "history.jsonl")
    write_history(history)
    {:ok, dir: dir, history: history}
  end

  test "1-sigma drift emits a CloudEvents spc.drift row into :smalt_event_messages", %{
    dir: dir,
    history: history
  } do
    {center, sigma} = probe(history, Path.join(dir, "source.jsonl"))

    source = Path.join(dir, "source.jsonl")
    File.write!(source, ~s({"machine": {"parse_ms": #{center + 1.5 * sigma}}}) <> "\n" <> ~s({"residue_tables": 0}) <> "\n")
    write_history(history)

    {out, 0} = run_gate(history, source)
    assert {:ok, [id]} = Drift.emit(out)
    assert {:ok, event} = Store.get(:smalt_event_messages, "spc.drift/" <> id)

    assert event["type"] == "spc.drift"
    assert event["specversion"] == "1.0"
    assert event["source"] == "smalt://scripts/spc_gate.py"
    assert event["topic"] == "spc.drift"
    assert event["data"]["metric"] == @metric
    assert event["data"]["tier"] == 1

    # The probe-calibrated aim is z ~= 1.5: inside the EVENT band, outside PASS.
    assert event["data"]["z"] >= 1.0 and event["data"]["z"] < 2.0
  end

  test "3-sigma is fail-closed: gate exits 1 and the emitter refuses to launder", %{
    dir: dir,
    history: history
  } do
    {center, sigma} = probe(history, Path.join(dir, "source.jsonl"))

    source = Path.join(dir, "source.jsonl")
    File.write!(source, ~s({"machine": {"parse_ms": #{center + 4.0 * sigma}}}) <> "\n" <> ~s({"residue_tables": 0}) <> "\n")
    write_history(history)

    {out, 1} = run_gate(history, source)
    receipt = decode(out)

    assert receipt["verdict"] == "FAIL"
    assert receipt["tier"] == 3

    # The spc-check recipe aborts on the gate's nonzero exit before emission;
    # the emitter itself ALSO refuses a FAIL verdict (defense in depth).
    assert {:ok, :skipped} = Drift.emit(out)
  end

  test "PASS verdict emits nothing; unknown gate and malformed input are typed skips/errors" do
    pass = Jason.encode!(%{"gate" => "spc-bands", "verdict" => "PASS", "tier" => 0, "metrics" => []})
    assert {:ok, :skipped} = Drift.emit(pass)

    unknown_gate = Jason.encode!(%{"gate" => "something-else", "verdict" => "EVENT", "tier" => 1})
    assert {:ok, :skipped} = Drift.emit(unknown_gate)

    assert {:error, {:malformed, _}} = Drift.emit("not json at all")
  end

  test "registry gate: spc.drift is a registered OCEL type (emitter reachable)" do
    assert Smalt.Ocel.EventRegistry.event_type?("spc.drift")
  end

  # -- helpers ---------------------------------------------------------------

  # Probe run: grade a near-center value once to read the real center/sigma
  # the gate computes over the FIXED rolling history (+ the canonical seeded
  # history). The probe appends to the rolling file, so callers must restore
  # it (write_history) before the graded run — the graded series is then
  # byte-identical to the probed one, making z deterministic.
  defp probe(history, source) do
    File.write!(source, ~s({"machine": {"parse_ms": 100}}) <> "\n" <> ~s({"residue_tables": 0}) <> "\n")
    {out, _status} = run_gate(history, source)

    m =
      receipt(out)["metrics"]
      |> Enum.find(&(&1["metric"] == @metric))

    assert is_number(m["center"]) and is_number(m["sigma"]) and m["sigma"] > 0
    {m["center"], m["sigma"]}
  end

  defp run_gate(history, source) do
    System.cmd("python3", ["scripts/spc_gate.py"],
      env: [{"SMALT_SPC_HISTORY", history}, {"SMALT_SPC_SOURCES", source}]
    )
  end

  defp write_history(history) do
    File.write!(
      history,
      Stream.cycle([95, 105])
      |> Enum.take(@rolling_count)
      |> Enum.map(&~s({"native_stage_ms": {"parse": #{&1}}}))
      |> Enum.join("\n")
    )
  end

  defp decode(out), do: out |> String.split("\n") |> Enum.reject(&String.starts_with?(&1, "[spc]")) |> Enum.join("\n") |> Jason.decode!()
  defp receipt(out), do: decode(out)
end
