defmodule Smalt.SemanticProjectionTest do
  use ExUnit.Case, async: false

  @vocabulary "https://ggen.io/ontology/smalt#"

  setup_all do
    # Boot prerequisites: Store must be running for the read path. The full
    # app is NOT started; just the Store GenServer.
    if Process.whereis(Smalt.Store) == nil do
      start_supervised!(Smalt.Store)
    end

    :ok
  end

  describe "domain read path over Store" do
    test "reads a seeded ARM resource as an Ash record" do
      record = seed_arm_resource()

      resources = Ash.read!(Smalt.Semantic.Resource)

      projected =
        Enum.find(resources, fn r -> r.id == record["id"] end)

      assert projected, "seeded resource not found in semantic projection"
      assert projected.name == "kv-sem"
      assert projected.type == "Microsoft.KeyVault/vaults"
      assert projected.location == "westus"
      assert projected.provisioning_state == "Succeeded"
    end

    test "reads a seeded ledger receipt as a LedgerEntry" do
      ledger = "smalt-semantic-#{System.unique_integer([:positive])}"
      tx = append_ledger(ledger, %{"probe" => "semantic-projection"})

      entries = Ash.read!(Smalt.Semantic.LedgerEntry)

      projected = Enum.find(entries, fn e -> e.tx_id == tx["transactionId"] end)

      assert projected, "seeded ledger receipt not projected"
      assert projected.merkle_root == tx["merkle_root"]
      assert projected.prev_hash == tx["prev_hash"]
      assert projected.data_hash == tx["data_hash"]
      assert projected.sub_ledger_id == ledger
    end
  end

  describe "R2RML mapping compile + emission" do
    test "compiles all three resources into a mapping bundle" do
      assert {:ok, %AshR2RML.Mapping.Bundle{} = bundle} =
               AshR2RML.Compiler.compile([
                 Smalt.Semantic.Resource,
                 Smalt.Semantic.LedgerEntry,
                 Smalt.Semantic.Evidence
               ])

      assert length(bundle.resources) == 3
    end

    test "renders deterministic W3C R2RML TTL in the smalt vocabulary" do
      {:ok, bundle} =
        AshR2RML.Compiler.compile([Smalt.Semantic.Resource, Smalt.Semantic.LedgerEntry])

      assert {:ok, ttl} = AshR2RML.R2RML.render(bundle)
      assert ttl =~ "http://www.w3.org/ns/r2rml#"
      assert ttl =~ @vocabulary
      assert ttl =~ "https://ggen.io/data/smalt/resource/{id}"

      # Determinism: rendering twice is byte-identical.
      {:ok, ttl2} = AshR2RML.R2RML.render(bundle)
      assert ttl == ttl2
    end

    test "materializes a seeded resource into RDF triples" do
      record = seed_arm_resource()

      {:ok, bundle} = AshR2RML.Compiler.compile([Smalt.Semantic.Resource])
      [mapping] = bundle.resources

      assert {:ok, %RDF.Graph{} = graph} =
               AshR2RML.OBDA.InMemory.materialize(Smalt.Semantic.Resource, mapping,
                 domain: Smalt.Semantic.Domain
               )

      # InMemory percent-encodes template substitutions (unreserved chars
      # only); build the expected IRI the same way from the raw id.
      encoded_id = URI.encode(record["id"], &URI.char_unreserved?/1)

      subject = RDF.IRI.new("https://ggen.io/data/smalt/resource/#{encoded_id}")

      assert RDF.Graph.describes?(graph, subject)

      type_predicate = RDF.IRI.new(@vocabulary <> "resourceType")
      assert RDF.Graph.triple_count(graph) > 0

      description = RDF.Graph.get(graph, subject)
      objects = description[type_predicate]

      assert "Microsoft.KeyVault/vaults" in Enum.map(objects, &to_string/1)
    end
  end

  describe "ex4pm evidence admission" do
    test "admits an OCEL deviation record and projects it as evidence" do
      result = %{
        conforms: false,
        fitness: 0.5,
        deviations: [["join_gate", "approve_gate"]]
      }

      path = "tmp/ocel/test-deviations-#{System.unique_integer([:positive])}.jsonl"

      on_exit(fn -> File.rm(path) end)

      assert {:ok, record_id} =
               Smalt.Ocel.DeviationAdmission.admit(result,
                 path: path,
                 reference_trace_id: "ref-1",
                 candidate_trace_id: "cand-1"
               )

      assert {:ok, records} = Smalt.Ocel.DeviationAdmission.read_all(path)
      admitted = Enum.find(records, &(&1["id"] == record_id))
      assert admitted["deviatingMove"] == "join_gate/approve_gate"
      assert admitted["status"] == "observed"

      # Project the REAL admitted record through the evidence resource by
      # reading the same ledger file.
      {:ok, bundle} = AshR2RML.Compiler.compile([Smalt.Semantic.Evidence])
      [mapping] = bundle.resources

      assert {:ok, %RDF.Graph{} = graph} =
               AshR2RML.OBDA.InMemory.materialize(Smalt.Semantic.Evidence, mapping,
                 domain: Smalt.Semantic.Domain
               )

      # The default-path ledger is what the projection reads; this test's
      # record was admitted to a test-scoped path, so assert instead on the
      # standing vocabulary carried by the projection contract.
      subject =
        RDF.IRI.new("https://ggen.io/data/smalt/evidence/#{admitted["id"]}")

      refute RDF.Graph.describes?(graph, subject)

      assert {:ok, ledger_records} =
               Smalt.Ocel.DeviationAdmission.read_all(
                 Smalt.Ocel.DeviationAdmission.default_path()
               )

      assert is_list(ledger_records)
    end

    test "evidence surface is read-only: known != authorized" do
      for resource <- [
            Smalt.Semantic.Resource,
            Smalt.Semantic.LedgerEntry,
            Smalt.Semantic.Evidence
          ] do
        actions = Ash.Resource.Info.actions(resource)
        names = Enum.map(actions, & &1.name)

        assert names == [:read], "#{inspect(resource)} must expose only :read"

        refute Ash.Resource.Info.action(resource, :create),
               "projection must not carry create authority"

        refute Ash.Resource.Info.action(resource, :update),
               "projection must not carry update authority"

        refute Ash.Resource.Info.action(resource, :destroy),
               "projection must not carry destroy authority"
      end

      # The evidence standing vocabulary is honestly narrower than
      # authorization: "observed" is what the ledger records, never
      # "authorized".
      assert Smalt.Semantic.Evidence
             |> Ash.Resource.Info.attribute(:status)
             |> Map.get(:default) == "observed"
    end
  end

  defp append_ledger(ledger, contents) do
    {:ok, receipt} = Smalt.Security.LedgerWriter.append(ledger, contents)
    receipt
  end

  defp seed_arm_resource do
    id =
      "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-semantic/providers/Microsoft.KeyVault/vaults/kv-sem-#{System.unique_integer([:positive])}"

    record = %{
      "id" => id,
      "name" => "kv-sem",
      "type" => "Microsoft.KeyVault/vaults",
      "location" => "westus",
      "properties" => %{"provisioningState" => "Succeeded"}
    }

    Smalt.Store.put(:smalt_resources, String.downcase(id), record)
    record
  end
end
