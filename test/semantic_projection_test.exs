defmodule Smalt.SemanticProjectionTest do
  use ExUnit.Case, async: false

  @vocabulary "https://ggen.io/ontology/smalt#"

  setup_all do
    # Boot prerequisites: Store must be running for the read path. The full
    # app is NOT started; just the Store GenServer.
    SmaltTest.Lifecycle.ensure_store_up()

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

  describe "R2RML render determinism under concurrent Store mutation" do
    test "render stays byte-identical while Store is concurrently mutated" do
      seed_arm_resource()

      {:ok, bundle} =
        AshR2RML.Compiler.compile([Smalt.Semantic.Resource, Smalt.Semantic.LedgerEntry])

      baseline =
        case AshR2RML.R2RML.render(bundle) do
          {:ok, ttl} -> ttl
          {:error, other} -> flunk("render failed: #{inspect(other)}")
        end

      # 32 renderers race 8 mutators against the real Store ETS: the compile-
      # time mapping bundle must not observe Store churn (byte-identical TTL),
      # and every concurrent materialize must still see the seeded row.
      parent = self()

      renderers =
        for i <- 1..32 do
          Task.async(fn ->
            ttl = AshR2RML.R2RML.render(bundle)
            send(parent, {:render, i, ttl})
          end)
        end

      mutators =
        for i <- 1..8 do
          Task.async(fn ->
            id =
              "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-fuzz/providers/Microsoft.KeyVault/vaults/fuzz-#{i}-#{System.unique_integer([:positive])}"

            record = %{
              "id" => id,
              "name" => "kv-fuzz-#{i}",
              "type" => "Microsoft.KeyVault/vaults",
              "location" => "eastus",
              "properties" => %{"provisioningState" => "Creating"}
            }

            Smalt.Store.put(:smalt_resources, String.downcase(id), record)
            send(parent, {:mutated, i})
          end)
        end

      Task.await_many(renderers ++ mutators, 30_000)

      ttls =
        for _ <- 1..32 do
          assert_receive {:render, _, ttl_result}, 10_000
          {:ok, ttl} = ttl_result
          ttl
        end

      assert Enum.uniq(ttls) == [baseline],
             "render output drifted under concurrent Store mutation"

      # Materialize over the live Store mid-churn: seeded row still present,
      # read path never fabricates or drops it.
      [mapping] =
        (AshR2RML.Compiler.compile([Smalt.Semantic.Resource]) |> elem(1)).resources

      for _ <- 1..4 do
        assert {:ok, %RDF.Graph{} = graph} =
                 AshR2RML.OBDA.InMemory.materialize(Smalt.Semantic.Resource, mapping,
                   domain: Smalt.Semantic.Domain
                 )

        assert RDF.Graph.triple_count(graph) > 0
      end

      # Mutators completed their real writes.
      for _ <- 1..8, do: assert_receive({:mutated, _}, 5_000)
    end
  end

  describe "R2RML determinism with registry regeneration interleaved" do
    @tag :regen_interleave
    @tag :stress
    @tag timeout: 600_000
    test "renders stay byte-identical while `mix smalt.gen` runs concurrently" do
      seed_arm_resource()

      {:ok, bundle} = AshR2RML.Compiler.compile([Smalt.Semantic.Resource])
      baseline = AshR2RML.R2RML.render(bundle) |> elem(1)

      registry_before = File.read!("lib/smalt/registry.ex")

      # Real regen subprocess (separate build root: no lock contention with
      # the test's build root). The gen may succeed or fail --warnings-as-
      # errors; EITHER WAY the in-memory bundle's renders must not move.
      gen_task =
        Task.async(fn ->
          {out, exit_code} =
            System.cmd("mix", ["smalt.gen"],
              env: %{"MIX_BUILD_ROOT" => "_build-f16", "MIX_ENV" => "dev"},
              cd: File.cwd!(),
              stderr_to_stdout: true
            )

          {exit_code, String.slice(out, -400, 400)}
        end)

      parent = self()

      renderers =
        for i <- 1..16 do
          Task.async(fn ->
            {:ok, ttl} = AshR2RML.R2RML.render(bundle)
            send(parent, {:render, i, ttl})
          end)
        end

      Task.await_many(renderers, 60_000)
      {gen_exit, gen_tail} = Task.await(gen_task, 300_000)

      ttls =
        for _ <- 1..16 do
          assert_receive {:render, _, ttl}, 1_000
          ttl
        end

      assert Enum.uniq(ttls) == [baseline],
             "render output drifted while mix smalt.gen ran (exit #{gen_exit})"

      # Determinism of the regen itself: the committed projection is either
      # byte-identical to what was on disk (idempotent regen) or the gen
      # refused/failed — record which.
      registry_after = File.read!("lib/smalt/registry.ex")

      if registry_after != registry_before do
        flunk("mix smalt.gen mutated lib/smalt/registry.ex (exit #{gen_exit}); tail: #{gen_tail}")
      end
    end
  end

  describe "cross-surface read-path validation" do
    test "semantic Store-backed rows only project Registry-admitted types" do
      record = seed_arm_resource()

      rows = Ash.read!(Smalt.Semantic.Resource)

      projected = Enum.find(rows, &(&1.id == record["id"]))
      assert projected, "seeded row missing from semantic projection"

      admitted = MapSet.new(Smalt.Registry.admitted_resource_types())

      for row <- rows do
        assert MapSet.member?(admitted, row.type),
               "semantic projection emitted non-admitted type #{inspect(row.type)}"
      end
    end

    # Lens-2 cycle 4: Store is untyped; a non-map value under
    # :smalt_resources crashed the whole read (FunctionClauseError in
    # project_resource/1) — boundary crash class. Refuses typed now.
    test "non-map Store row refuses the semantic read typed, never crashes" do
      uid = "sem-nonmap-#{System.unique_integer([:positive])}"
      Smalt.Store.put(:smalt_resources, uid, 42)
      record = seed_arm_resource()

      assert {:error, err} = Ash.read(Smalt.Semantic.Resource)
      assert Exception.message(err) <> inspect(err.errors) =~ "non-map Store row"

      Smalt.Store.delete(:smalt_resources, uid)
      assert Ash.read!(Smalt.Semantic.Resource)
    end

    # Lens-3 cycle 2: struct/2 does not enforce allow_nil? on the manual
    # read path — nil and blank primary keys projected as real records
    # (probe receipt: RESOURCE ids=["", nil]). Vacuous identity is refused
    # typed on the same axis as the non-map fence.
    test "vacuous primary keys (nil and blank) refuse the semantic read typed" do
      uid_nil = "sem-nil-pk-#{System.unique_integer([:positive])}"
      uid_blank = "sem-blank-pk-#{System.unique_integer([:positive])}"

      Smalt.Store.put(:smalt_resources, uid_nil, %{"id" => nil, "name" => "x", "type" => "t"})
      Smalt.Store.put(:smalt_resources, uid_blank, %{"id" => "", "name" => "y", "type" => "t"})

      assert {:error, err} = Ash.read(Smalt.Semantic.Resource)
      assert Exception.message(err) <> inspect(err.errors) =~ "vacuous identity"

      Smalt.Store.delete(:smalt_resources, uid_nil)
      Smalt.Store.delete(:smalt_resources, uid_blank)

      assert Ash.read!(Smalt.Semantic.Resource)
    end

    # Lens-3 cycle 2 (branch parity): the LedgerEntry read path carries the
    # same vacuous-identity fence over "transactionId".
    test "vacuous ledger transactionId refuses the LedgerEntry read typed" do
      uid = "sem-nil-tx-#{System.unique_integer([:positive])}"
      Smalt.Store.put(:smalt_ledger_transactions, uid, %{"transactionId" => nil})

      assert {:error, err} = Ash.read(Smalt.Semantic.LedgerEntry)
      assert Exception.message(err) <> inspect(err.errors) =~ "vacuous identity"

      Smalt.Store.delete(:smalt_ledger_transactions, uid)

      assert Ash.read!(Smalt.Semantic.LedgerEntry)
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

# Lens-4 cycle 1: whitespace-only / invisible-format-only primary keys carry
# zero visible identity bits — same vacuous-identity class, now via the one
# shared fence Smalt.Projection.Identity.
defmodule Smalt.Semantic.StoreRead.Lens4IdentityTest do
  use ExUnit.Case, async: false

  setup_all do
    # Lens-4: this appended module needs the Store GenServer up for the
    # Store-backed read path (same boot prerequisite as the parent suite).
    SmaltTest.Lifecycle.ensure_store_up()

    :ok
  end

  test "whitespace-only primary key refuses the semantic read typed" do
    uid = "sem-ws-pk-#{System.unique_integer([:positive])}"
    Smalt.Store.put(:smalt_resources, uid, %{"id" => "  \t", "name" => "x", "type" => "t"})

    assert {:error, err} = Ash.read(Smalt.Semantic.Resource)
    assert Exception.message(err) <> inspect(err.errors) =~ "vacuous identity"

    Smalt.Store.delete(:smalt_resources, uid)
  end

  test "invisible-format-only (zero-width) primary key refuses the semantic read typed" do
    uid = "sem-zw-pk-#{System.unique_integer([:positive])}"
    Smalt.Store.put(:smalt_resources, uid, %{"id" => "​", "name" => "x", "type" => "t"})

    assert {:error, err} = Ash.read(Smalt.Semantic.Resource)
    assert Exception.message(err) <> inspect(err.errors) =~ "vacuous identity"

    Smalt.Store.delete(:smalt_resources, uid)
  end

  test "ledger transactionId whitespace-only refuses the LedgerEntry read typed" do
    uid = "sem-ws-tx-#{System.unique_integer([:positive])}"
    Smalt.Store.put(:smalt_ledger_transactions, uid, %{"transactionId" => "   "})

    assert {:error, err} = Ash.read(Smalt.Semantic.LedgerEntry)
    assert Exception.message(err) <> inspect(err.errors) =~ "vacuous identity"

    Smalt.Store.delete(:smalt_ledger_transactions, uid)
  end
end

# Lens-6 cycle 1: the lens-5 non-map JSON-structural crash class GENERALIZES:
# two more members on the StoreRead surface, both previously crashing the
# WHOLE Ash read. Fixed fail-closed/lenient per member; tests kill mutants.
defmodule Smalt.Semantic.StoreRead.Lens6StructuralTest do
  use ExUnit.Case, async: false

  setup_all do
    SmaltTest.Lifecycle.ensure_store_up()

    :ok
  end

  test "a Store row with a non-map properties projects provisioning_state nil, never crashes" do
    uid = "sem-flat-props-#{System.unique_integer([:positive])}"

    Smalt.Store.put(:smalt_resources, uid, %{
      "id" => uid,
      "name" => "x",
      "type" => "t",
      "properties" => "flat-string"
    })

    # The lenient policy must not swallow a well-formed neighbor.
    good = uid <> "-good"

    Smalt.Store.put(:smalt_resources, good, %{
      "id" => good,
      "name" => "g",
      "type" => "t",
      "properties" => %{"provisioningState" => "Succeeded"}
    })

    resources = Ash.read!(Smalt.Semantic.Resource)

    projected = Enum.find(resources, &(&1.id == uid))
    assert projected, "seeded flat-properties row not projected"
    assert projected.provisioning_state == nil

    assert Enum.find(resources, &(&1.id == good)).provisioning_state == "Succeeded"

    Smalt.Store.delete(:smalt_resources, uid)
    Smalt.Store.delete(:smalt_resources, good)
  end

  test "a valid-JSON non-map deviation-ledger line refuses the Evidence read typed" do
    dev = Smalt.Ocel.DeviationAdmission.default_path()
    backup = if File.exists?(dev), do: File.read(dev), else: nil
    File.mkdir_p!(Path.dirname(dev))

    File.write!(
      dev,
      Jason.encode!(%{
        "id" => "l6-good",
        "referenceTraceId" => "r",
        "candidateTraceId" => "c",
        "deviatingMove" => "m",
        "timestamp" => "t"
      }) <> "\n[1,2]\n"
    )

    on_exit(fn ->
      case backup do
        nil -> File.rm(dev)
        {:ok, body} -> File.write!(dev, body)
      end
    end)

    assert {:error, err} = Ash.read(Smalt.Semantic.Evidence)
    msg = Exception.message(err) <> inspect(err.errors)
    assert msg =~ "non-map"
    assert msg =~ ":ocel_deviations"

    # Restore BEFORE returning so a subsequent restore can't race other
    # suites on the shared default path.
    case backup do
      nil -> File.rm(dev)
      {:ok, body} -> File.write!(dev, body)
    end
  end
end

# Lens-7 cycle 3: field-VALUE policy (witnessed probe tmp/f16L7/probe3:
# non-conformant field values passed through RAW — provisioningState 42,
# data_hash list — into attributes declared String.t()). Pinned policy:
# row structure + identity refuse typed; field values follow the parse_ts
# lenient precedent (non-binary -> nil, never a raw type-lie).
defmodule Smalt.Semantic.StoreRead.Lens7FieldPolicyTest do
  use ExUnit.Case, async: false

  setup_all do
    SmaltTest.Lifecycle.ensure_store_up()

    :ok
  end

  test "non-binary field values project nil, well-formed neighbors untouched" do
    uid = "l7-field-#{System.unique_integer([:positive])}"

    Smalt.Store.put(:smalt_resources, uid, %{
      "id" => uid,
      "name" => 42,
      "type" => ["Microsoft.KeyVault/vaults"],
      "location" => %{"region" => "westus"},
      "properties" => %{"provisioningState" => 42}
    })

    good = uid <> "-good"

    Smalt.Store.put(:smalt_resources, good, %{
      "id" => good,
      "name" => "g",
      "type" => "Microsoft.Key/vaults",
      "location" => "westus",
      "properties" => %{"provisioningState" => "Succeeded"}
    })

    resources = Ash.read!(Smalt.Semantic.Resource)

    bad = Enum.find(resources, &(&1.name == 42 or is_list(&1.type) or is_map(&1.location)))

    refute bad, "raw non-binary field value leaked into the projection"

    bad_row = Enum.find(resources, &(&1.id == uid))
    assert bad_row, "seeded drift row not projected at all"
    assert bad_row.name == nil and bad_row.type == nil and bad_row.location == nil

    assert Enum.find(resources, &(&1.id == good)).provisioning_state == "Succeeded"
    assert Enum.find(resources, &(&1.id == good)).name == "g"

    Smalt.Store.delete(:smalt_resources, uid)
    Smalt.Store.delete(:smalt_resources, good)
  end

  test "non-binary ledger fields project nil; truthy non-binary Evidence status defaults" do
    uid = "l7-ledger-#{System.unique_integer([:positive])}"

    Smalt.Store.put(:smalt_ledger_transactions, uid, %{
      "transactionId" => uid,
      "subLedgerId" => 7,
      "merkle_root" => ["m"],
      "timestamp" => 42
    })

    ledger_rows = Ash.read!(Smalt.Semantic.LedgerEntry)

    row = Enum.find(ledger_rows, &(&1.tx_id == uid))
    assert row, "seeded ledger drift row not projected"
    assert row.sub_ledger_id == nil
    assert row.merkle_root == nil
    assert row.prev_hash == nil
    assert row.data_hash == nil
    assert row.timestamp == nil

    Smalt.Store.delete(:smalt_ledger_transactions, uid)
  end

  test "a truthy non-binary Evidence status defaults to observed, never projects raw" do
    dev = Smalt.Ocel.DeviationAdmission.default_path()
    backup = if File.exists?(dev), do: File.read(dev), else: nil
    File.mkdir_p!(Path.dirname(dev))

    File.write!(
      dev,
      Jason.encode!(%{
        "id" => "l7-status",
        "referenceTraceId" => "r",
        "candidateTraceId" => "c",
        "deviatingMove" => "m",
        "timestamp" => 42,
        "status" => 42
      }) <> "\n"
    )

    on_exit(fn ->
      case backup do
        nil -> File.rm(dev)
        {:ok, body} -> File.write!(dev, body)
      end
    end)

    assert %Smalt.Semantic.Evidence{} =
             ev =
             Enum.find(Ash.read!(Smalt.Semantic.Evidence), &(&1.id == "l7-status"))

    assert ev.status == "observed"
    assert ev.timestamp == nil

    # Restore BEFORE returning (shared default path).
    case backup do
      nil -> File.rm(dev)
      {:ok, body} -> File.write!(dev, body)
    end
  end
end
