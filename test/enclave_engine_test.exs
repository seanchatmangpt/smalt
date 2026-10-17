defmodule EnclaveEngineTest do
  use ExUnit.Case
  use Plug.Test

  alias Smalt.Enclave.Engine
  alias Smalt.Store

  @opts Smalt.ArmGateway.Router.init([])
  @sub "00000000-0000-0000-0000-000000000000"

  setup do
    ensure_store()
    Store.clear()

    Store.put(:smalt_subscriptions, @sub, %{
      "id" => "/subscriptions/#{@sub}",
      "subscriptionId" => @sub,
      "displayName" => "Sovereign Smalt Subscription",
      "state" => "Enabled"
    })

    Application.put_env(:smalt, :lro_delay_ms, 0)
    :ok
  end

  # Same idempotent Store boot idiom as SmaltArmGatewayTest.
  defp ensure_store do
    case Store.start_link([]) do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        if :ets.info(:smalt_subscriptions) == :undefined do
          pid = Process.whereis(Store)
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} ->
              ensure_store()
          after
            500 ->
              :ok
          end
        else
          :ok
        end
    end
  end

  defp stored?(%{arm_type: "Microsoft.Resources/resourceGroups", id: id}) do
    match?({:ok, _}, Store.get(:smalt_resource_groups, String.downcase(id)))
  end

  defp stored?(%{id: id}) do
    match?({:ok, _}, Store.get(:smalt_resources, String.downcase(id)))
  end

  defp stored?(id) when is_binary(id) do
    match?({:ok, _}, Store.get(:smalt_resources, String.downcase(id)))
  end

  # ---------------------------------------------------------------------------
  # Baseline fixture: rg + key vault + storage account with {:ref,...} terms
  # ---------------------------------------------------------------------------

  test "baseline fixture applies in dependency order, all 201/202, store records" do
    resources = [
      {:resource, "azurerm_resource_group", :rg, %{name: "rg-smalt-fixture", location: "smalt-local"}},
      {:resource, "azurerm_key_vault", :kv,
       %{
         name: "kv-smalt-fixture",
         resource_group_name: {:ref, :rg, :name},
         location: {:ref, :rg, :location},
         sku_name: "standard",
         tenant_id: @sub
       }},
      {:resource, "azurerm_storage_account", :sa,
       %{
         name: "t5smaltfixturestore",
         resource_group_name: {:ref, :rg, :name},
         location: {:ref, :rg, :location},
         account_tier: "Standard",
         account_replication_type: "LRS"
       }}
    ]

    assert {:ok, outcomes} = Engine.apply(resources)

    assert %{
             label: "rg",
             type: "azurerm_resource_group",
             status: 201,
             id: "/subscriptions/#{@sub}/resourceGroups/rg-smalt-fixture"
           } = Engine.outcome_for(outcomes, :rg)

    kv = Engine.outcome_for(outcomes, :kv)
    sa = Engine.outcome_for(outcomes, :sa)
    assert kv.status == 201
    assert kv.arm_type == "Microsoft.KeyVault/vaults"
    assert kv.id == "/subscriptions/#{@sub}/resourceGroups/rg-smalt-fixture/providers/Microsoft.KeyVault/vaults/kv-smalt-fixture"

    # storage accounts are an LRO type: create is 202
    assert sa.status == 202
    assert sa.arm_type == "Microsoft.Storage/storageAccounts"

    # order: rg first, kv before sa is not required, but rg MUST precede both
    labels = Enum.map(outcomes, & &1.label)
    assert Enum.find_index(labels, &(&1 == "rg")) == 0

    # store records assertable
    assert stored?(kv.id)
    assert stored?(sa.id)
  end

  test "per-resource families: cosmos, eventhub, servicebus apply 201" do
    resources = [
      {:resource, "azurerm_resource_group", :rg, %{name: "rg-enclave-fam", location: "smalt-local"}},
      {:resource, "azurerm_cosmosdb_account", :cosmos,
       %{
         name: "cos-enclave-fam",
         resource_group_name: {:ref, :rg, :name},
         location: {:ref, :rg, :location}
       }},
      {:resource, "azurerm_cosmosdb_sql_database", :cosmosdb,
       %{
         name: "db1",
         account_name: {:ref, :cosmos, :name},
         resource_group_name: {:ref, :rg, :name}
       }},
      {:resource, "azurerm_cosmosdb_sql_container", :cosmosc,
       %{
         name: "coll1",
         account_name: {:ref, :cosmos, :name},
         database_name: {:ref, :cosmosdb, :name},
         resource_group_name: {:ref, :rg, :name}
       }},
      {:resource, "azurerm_eventhub_namespace", :ehns,
       %{
         name: "ehns-enclave-fam",
         resource_group_name: {:ref, :rg, :name},
         location: {:ref, :rg, :location},
         sku: "Standard"
       }},
      {:resource, "azurerm_eventhub", :eh,
       %{
         name: "hub1",
         namespace_name: {:ref, :ehns, :name},
         resource_group_name: {:ref, :rg, :name}
       }},
      {:resource, "azurerm_servicebus_namespace", :sbns,
       %{
         name: "sbns-enclave-fam",
         resource_group_name: {:ref, :rg, :name},
         location: {:ref, :rg, :location}
       }},
      {:resource, "azurerm_servicebus_queue", :sbq,
       %{
         name: "q1",
         namespace_name: {:ref, :sbns, :name},
         resource_group_name: {:ref, :rg, :name},
         max_delivery_count: 5
       }}
    ]

    assert {:ok, outcomes} = Engine.apply(resources)

    for o <- outcomes do
      assert o.status in [201, 202], "#{o.label} -> #{o.status}"
    end

    # order must be topologically valid: every ref target precedes its user
    labels = Enum.map(outcomes, & &1.label)

    for {user, target} <- [
          {"cosmosdb", "cosmos"},
          {"cosmosc", "cosmos"},
          {"cosmosc", "cosmosdb"},
          {"eh", "ehns"},
          {"sbq", "sbns"}
        ] do
      assert Enum.find_index(labels, &(&1 == target)) <
               Enum.find_index(labels, &(&1 == user)),
             "#{target} must precede #{user} (got #{inspect(labels)})"
    end

    assert Enum.all?(outcomes, &stored?/1),
           "not every outcome has a stored record: #{inspect(outcomes)}"
  end

  # ---------------------------------------------------------------------------
  # Failure faces
  # ---------------------------------------------------------------------------

  test "cycle -> typed error naming the cycle members" do
    resources = [
      {:resource, "azurerm_resource_group", :a,
       %{name: "rg-a", location: {:ref, :b, :location}}},
      {:resource, "azurerm_resource_group", :b,
       %{name: {:ref, :a, :name}, location: "smalt-local"}}
    ]

    assert {:error, {:cycle, labels}} = Engine.apply(resources)
    assert Enum.sort(labels) == ["a", "b"]
  end

  test "unknown resource type -> typed refusal" do
    resources = [
      {:resource, "azurerm_unicorn", :u, %{name: "u1", location: "smalt-local"}}
    ]

    assert {:error, {:unknown_resource_type, "azurerm_unicorn", "u"}} = Engine.apply(resources)
  end

  test "missing ref target -> typed error" do
    resources = [
      {:resource, "azurerm_key_vault", :kv,
       %{
         name: "kv-orphan",
         resource_group_name: {:ref, :nope, :name},
         tenant_id: @sub
       }}
    ]

    assert {:error, {:missing_ref_target, "kv", "nope"}} = Engine.apply(resources)
  end

  test "gateway GraphLaw refusal passes through typed (code + status)" do
    # A type already in ARM form rides the generic provider route verbatim;
    # a type with no SHACL shape is refused by the gateway's GraphLaw gate
    # and the engine surfaces the envelope typed (code + status + message).
    resources = [
      {:resource, "azurerm_resource_group", :rg, %{name: "rg-refusal", location: "smalt-local"}},
      {:resource, "Microsoft.Fake/unicorns", :u,
       %{"name" => "u1", "resource_group_name" => "rg-refusal"}}
    ]

    assert {:error, {:apply_failed, failure}} = Engine.apply(resources)
    assert failure.label == "u"
    assert failure.type == "Microsoft.Fake/unicorns"
    assert failure.status == 400
    assert failure.code == "InvalidResourceShape"
  end

  test "cyclic ref chain -> typed {:error, {:cycle, _}}, not a hang (REF-CYCLE-HANG)" do
    # Mutual ref: rg.location <-> kv.resource_group_name form a ref-value
    # cycle. Also a resource-level cycle, so topo must catch it first.
    resources = [
      {:resource, "azurerm_resource_group", :rg,
       %{name: "rg-cyc", location: {:ref, :kv, :tenant_id}}},
      {:resource, "azurerm_key_vault", :kv,
       %{name: "kv-cyc", resource_group_name: {:ref, :rg, :name}, tenant_id: @sub}}
    ]

    assert {:error, {:cycle, _}} = Engine.apply(resources)
  end

  test "resource missing required attrs -> typed {:error, {:missing_attr, label, attr}}" do
    # Pre-existing regression (minor 7): a resource with no "name" used to
    # raise KeyError from arm_target/4; the attr-completeness preflight now
    # refuses it typed before any dispatch.
    resources = [{:resource, "azurerm_resource_group", :rg, %{location: "smalt-local"}}]
    assert {:error, {:missing_attr, "rg", "name"}} = Engine.apply(resources)

    resources = [
      {:resource, "azurerm_resource_group", :rg, %{name: "rg-ok", location: "smalt-local"}},
      {:resource, "azurerm_key_vault", :kv, %{name: "kv-no-rg"}}
    ]

    assert {:error, {:missing_attr, "kv", attr}} = Engine.apply(resources)
    assert attr in ["resource_group_name", "tenant_id"]
  end

  test "self-referential attr -> typed {:error, {:cycle, _}} (topo self-edge is dropped)" do
    # A self-ref does not create a resource-level cycle (topo deletes self
    # edges), so only walk_refs' visited-set can catch it.
    resources = [
      {:resource, "azurerm_resource_group", :rg,
       %{name: "rg-self", location: {:ref, :rg, :location}}}
    ]

    assert {:error, {:cycle, _}} = Engine.apply(resources)
  end
end
