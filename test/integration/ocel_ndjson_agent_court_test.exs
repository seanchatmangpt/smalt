defmodule Smalt.Integration.OcelNdjsonAgentCourtTest do
  use ExUnit.Case, async: true

  # GAP-6a Agent-chain court for the real `Smalt.Telemetry.OcelNdjson` sink.
  # Chicago: a real append to a real on-disk NDJSON file (unique per-test tmp
  # dir), a real `read_document/1` assembly round-trip, and real tamper legs
  # rewriting the file bytes. No mocks; assertions on final on-disk state.
  #
  # Chain contract: an event appended with the `:agent` opt carries the
  # association as a `prov:wasAssociatedWith` relationship to a first-class
  # `eo:Agent` object (PROV-O `prov:Agent` mapped onto OCEL 2.0 object
  # types). Tampering the Agent term out of a leaf fails downstream
  # adjudication with typed violations — never a silent admit.

  alias Smalt.Telemetry.OcelNdjson

  @event_type "cosmos.doc.crud"

  defp court_dir do
    dir = Path.join(System.tmp_dir!(), "ocel-agent-court-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir); :ok end)
    dir
  end

  defp event(id) do
    %{
      "id" => id,
      "type" => @event_type,
      "time" => "2026-10-21T00:00:00Z",
      "attributes" => %{"method" => "PUT"},
      "relationships" => []
    }
  end

  test "append/3 with :agent injects the eo:Agent object + wasAssociatedWith relationship on the line" do
    dir = court_dir()
    agent = "urn:smalt:agent:court-1"

    assert {:ok, path} =
             OcelNdjson.append(event("e1"), [%{"id" => "pk1", "type" => "partition"}],
               dir: dir, agent: agent)

    assert {:ok, doc} = OcelNdjson.read_document(path)

    assert %{"id" => ^agent, "type" => "eo:Agent"} =
             doc["ocel:objects"] |> Enum.find(&(&1["id"] == agent))

    ev = doc["ocel:events"] |> Enum.find(&(&1["id"] == "e1"))
    assert Enum.any?(ev["relationships"], &(&1 == %{"objectId" => agent, "qualifier" => "prov:wasAssociatedWith"}))

    # the injected object type is declared, not used-but-undeclared
    assert %{"name" => "eo:Agent"} in doc["ocel:objectTypes"]
    # closure + agent adjudication both clean on the honest leaf
    assert OcelNdjson.agent_chain_violations(doc) == []
  end

  test "append/3 without :agent stays byte-compatible (no agent terms)" do
    dir = court_dir()

    assert {:ok, path} = OcelNdjson.append(event("e2"), [], dir: dir)
    assert {:ok, doc} = OcelNdjson.read_document(path)

    refute Enum.any?(doc["ocel:objects"], &(&1["type"] == "eo:Agent"))
    assert OcelNdjson.agent_chain_violations(doc) == []
  end

  test "agent injection is idempotent: pre-supplied agent object/relationship is not duplicated" do
    dir = court_dir()
    agent = "urn:smalt:agent:court-3"

    ev = Map.put(event("e3"), "relationships", [OcelNdjson.agent_relationship(agent)])

    assert {:ok, path} =
             OcelNdjson.append(ev, [OcelNdjson.agent_object(agent)], dir: dir, agent: agent)

    assert {:ok, doc} = OcelNdjson.read_document(path)
    assert Enum.count(doc["ocel:objects"], &(&1["id"] == agent)) == 1

    ev3 = doc["ocel:events"] |> Enum.find(&(&1["id"] == "e3"))
    assert Enum.count(ev3["relationships"], &(&1["qualifier"] == "prov:wasAssociatedWith")) == 1
    assert OcelNdjson.agent_chain_violations(doc) == []
  end

  test "tamper leg: dropping the Agent term fails downstream adjudication with typed violations" do
    dir = court_dir()
    agent = "urn:smalt:agent:court-4"

    assert {:ok, path} = OcelNdjson.append(event("e4"), [], dir: dir, agent: agent)
    honest = File.read!(path)

    # Tamper the on-disk bytes: strip the eo:Agent OBJECT from the line,
    # keeping the association relationship (and the objectTypes declaration).
    tampered_line =
      honest
      |> String.trim_trailing("\n")
      |> Jason.decode!()
      |> Map.update!("ocel:objects", &Enum.reject(&1, fn o -> o["type"] == "eo:Agent" end))
      |> Jason.encode!()

    File.write!(path, tampered_line <> "\n")

    # the assembly closure law refuses the dangling association outright...
    assert {:error, violations} = OcelNdjson.read_document(path)
    assert violations != []

    # ...and the typed agent-chain adjudicator names the breach on the
    # assembled shape (dangling AND wrong-type targets).
    honest_doc = honest |> String.trim_trailing("\n") |> Jason.decode!()

    wrong_type_doc =
      honest_doc
      |> Map.update!("ocel:objects", fn objs ->
        Enum.map(objs, fn o ->
          if o["type"] == "eo:Agent", do: Map.put(o, "type", "session"), else: o
        end)
      end)

    assert [%{reason: reason}] = OcelNdjson.agent_chain_violations(wrong_type_doc)
    assert reason =~ "missing or non-eo:Agent"
  end
end
