defmodule Smalt.Telemetry.EnclaveOcelTest do
  @moduledoc """
  The `enclave.lifecycle.stage` OCEL emission law, end to end on real
  collaborators: a real `Smalt.Enclave.Lifecycle.run/2` appends one
  event per completed stage (enclave + fixture + applied resource
  objects, registry-gated) into a scratch NDJSON sink; the assembled
  document closes references and the ex4pm bridge discovers the golden
  path and conforms it at fitness 1.0.
  """

  use ExUnit.Case, async: false

  alias Smalt.Enclave.Lifecycle
  alias Smalt.Ocel.Revops.PowlBridge
  alias Smalt.Store
  alias Smalt.Telemetry.OcelNdjson

  @fixture Path.expand("../test/terraform_fixture/main.tf", __DIR__)

  setup do
    case Process.whereis(Smalt.Store) do
      nil -> {:ok, _} = Application.ensure_all_started(:smalt)
      _ -> :ok
    end

    Store.clear()

    dir = Path.join("tmp", "ocel-test-#{System.system_time(:millisecond)}")
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

    {:ok, log: log, dir: dir}
  end

  @tag :skip_ci
  test "a real lifecycle run emits one stage event per stage with enclave/fixture/resource objects" do
    state_path =
      Path.join("tmp", "enclave-native-ocel-#{System.system_time(:millisecond)}.tfstate")

    assert {:ok, report} = Lifecycle.run(@fixture, state_path: state_path)
    assert map_size(report.timings_ms) == 6

    log = Path.join(Application.fetch_env!(:smalt, :ocel_dir), "events.ndjson")
    assert {:ok, doc} = OcelNdjson.read_document(log)

    stages =
      for e <- doc["ocel:events"],
          e["type"] == "enclave.lifecycle.stage",
          do: e["attributes"]["stage"]

    assert Enum.sort(stages) == ~w(apply destroy parse plan residue synthesize)

    # Objects: enclave + fixture + the 3 applied resources; relationships
    # close over every object (assembly closure law held — read_document
    # returned :ok, no dangling refs).
    types = doc["ocel:objects"] |> Enum.map(& &1["type"]) |> Enum.frequencies()
    assert types["enclave"] == 1
    assert types["fixture"] == 1
    assert types["resource"] == 3

    # Blanket shape assertion scoped to stage events: the lifecycle ladder
    # also legitimately emits other registry-gated event types (e.g.
    # `affidavit.seal` sideband events from the ARM router, whose attrs are
    # subject_sha/engine_hash/verdict, not stage-shaped).
    for e <- doc["ocel:events"], e["type"] == "enclave.lifecycle.stage" do
      assert %{"stage" => _, "duration_ms" => ms, "verdict" => "ok"} = e["attributes"]
      assert is_integer(ms)
    end
  end

  test "bridge: discover + conform same data at fitness 1.0; mutated trace is penalized" do
    log = Path.join(Application.fetch_env!(:smalt, :ocel_dir), "events.ndjson")

    # Seed a small real log from two stage emissions (no full ladder needed
    # for the bridge law: assemble -> ingest -> DFG -> conform round trip).
    for stage <- [:parse, :apply] do
      assert {:ok, _} =
               Smalt.Telemetry.EnclaveOcel.stage(stage, 1, "ok", %{
                 enclave_id: "enclave/fence",
                 fixture_id: "main.tf",
                 resource_ids: ["rg-test"]
               })
    end

    # The scratch dir sink is where EnclaveOcel appended; discover + conform.
    log = Path.join(Application.fetch_env!(:smalt, :ocel_dir), "events.ndjson")
    assert {:ok, disc} = PowlBridge.discover(log, object_type: "enclave")
    assert disc.standing == :alive
    assert %{type: :dfg} = disc.model

    assert {:ok, conf} = PowlBridge.conform(log, model: disc.model, object_type: "enclave")
    assert conf.fitness == 1.0

    # Flip: the same model must REFUSE a mutated trace (anti-vacuity).
    assert {:ok, bad} =
             PowlBridge.conform(mutation_of(log), model: disc.model, object_type: "enclave")

    assert bad.fitness < 1.0
  end

  defp mutation_of(log) do
    bad = Path.join(Path.dirname(log), "mutated.ndjson")

    lines =
      log
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        doc = Jason.decode!(line)
        put_in(doc, ["ocel:events", Access.all(), "attributes", "stage"], "mutated")
      end)

    File.write!(bad, Enum.map_join(lines, "\n", &Jason.encode!/1) <> "\n")
    bad
  end
end
