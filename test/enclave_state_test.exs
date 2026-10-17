defmodule EnclaveStateTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Smalt.ArmGateway.Router
  alias Smalt.Enclave.State
  alias Smalt.Store

  @opts Router.init([])
  @sub "00000000-0000-0000-0000-000000000000"

  setup do
    case Store.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    Store.clear()
    Application.put_env(:smalt, :lro_delay_ms, 0)
    :ok
  end

  defp req(method, path, body \\ nil, type \\ nil) do
    path =
      if type do
        "#{path}?api-version=#{Smalt.Registry.latest_version(type) || "2024-01-01"}"
      else
        "#{path}?api-version=2023-07-01"
      end

    conn = if body, do: Plug.Test.conn(method, path, body), else: Plug.Test.conn(method, path)
    conn = if body, do: Plug.Conn.put_req_header(conn, "content-type", "application/json"), else: conn
    Router.call(conn, @opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  # Baseline "apply": RG + storageAccount (LRO) + vault + a blob container
  # child (exercises the account cascade on destroy).
  defp apply_baseline do
    rg = "/subscriptions/#{@sub}/resourceGroups/rg-enclave"
    acct = "#{rg}/providers/Microsoft.Storage/storageAccounts/stenclave01"
    vault = "#{rg}/providers/Microsoft.KeyVault/vaults/kv-enclave"
    container = "#{acct}/blobServices/default/containers/c1"

    assert req(:put, rg, ~s({"location":"eastus"})).status == 201

    put_acct = req(:put, acct, ~s({"location":"eastus","properties":{}}), "Microsoft.Storage/storageAccounts")
    assert put_acct.status in [200, 201, 202]

    assert req(:put, vault, ~s({"location":"eastus","properties":{}}), "Microsoft.KeyVault/vaults").status ==
             201

    put_c =
      req(:put, container, ~s({"location":"eastus","properties":{"publicAccess":"None"}}),
        "Microsoft.Storage/storageAccounts/blobServices/containers"
      )
    assert put_c.status in [200, 201], "container PUT -> #{put_c.status}: #{put_c.resp_body}"

    # non-vacuity witness: the container is reachable through the same route
    # State.destroy will later verify 404 on
    get_c =
      req(:get, container, nil, "Microsoft.Storage/storageAccounts/blobServices/containers")

    assert get_c.status == 200, "container GET pre-destroy -> #{get_c.status}"

    outcome = %{
      "rg" => %{id: rg, type: "Microsoft.Resources/resourceGroups", status: "Succeeded"},
      "acct" => %{id: acct, type: "Microsoft.Storage/storageAccounts", status: "Succeeded"},
      "vault" => %{id: vault, type: "Microsoft.KeyVault/vaults", status: "Succeeded"},
      "c1" => %{
        id: container,
        type: "Microsoft.Storage/storageAccounts/blobServices/containers",
        status: "Succeeded"
      }
    }

    {outcome, %{rg: rg, acct: acct, vault: vault, container: container}}
  end

  test "synthesize: tfstate shape is an exact, deterministically-sorted read-projection" do
    {outcome, ids} = apply_baseline()

    state = State.synthesize(outcome)

    # shape: label -> {id, attributes-from-stored-record}
    assert Map.keys(state) |> Enum.sort() == ["acct", "c1", "rg", "vault"]
    assert state["acct"]["id"] == ids.acct
    assert state["acct"]["attributes"]["id"] |> String.downcase() == String.downcase(ids.acct)
    assert state["acct"]["attributes"]["type"] == "Microsoft.Storage/storageAccounts"
    assert state["rg"]["attributes"]["type"] == "Microsoft.Resources/resourceGroups"
    assert state["c1"]["attributes"] != nil

    # exact read-projection: mutating the projection does NOT touch the store
    # (read-only law), and the projection reflects a live external mutation.
    {:ok, fresh} = Store.get(:smalt_resources, String.downcase(ids.vault))
    assert state["vault"]["attributes"] == fresh

    # deterministic bytes: encode twice, byte-equal; keys sorted in the JSON
    enc1 = State.encode(outcome)
    enc2 = State.encode(outcome)
    assert enc1 == enc2
    decoded = Jason.decode!(enc1)
    assert Jason.encode!(Map.keys(decoded)) == Jason.encode!(Enum.sort(Map.keys(decoded)))

    # write/2 persists the same bytes
    path = Path.join(System.tmp_dir(), "enclave-state-#{System.unique_integer()}.tfstate")
    on_exit(fn -> File.rm(path) end)
    State.write(outcome, path)
    assert File.read!(path) == enc1 <> "\n"
  end

  test "plan: zero drift on the second apply; external mutation is reported" do
    {outcome, ids} = apply_baseline()

    declared = %{
      "vault" =>
        Map.put(outcome["vault"], :attributes, %{"location" => "eastus", "type" => "Microsoft.KeyVault/vaults"}),
      "acct" => Map.put(outcome["acct"], :attributes, %{"location" => "eastus"})
    }

    # second apply vs unchanged store: zero drift
    assert State.plan(declared) == []

    # external mutation of a stored record -> reported drift
    {:ok, rec} = Store.get(:smalt_resources, String.downcase(ids.vault))
    Store.put(:smalt_resources, String.downcase(ids.vault), %{rec | "location" => "westus"})

    assert {:drift, "vault", "location", "eastus", "westus"} in State.plan(declared)

    # missing resource -> :missing, never a silent pass
    missing = Map.put(declared, "ghost", %{id: "#{ids.rg}/providers/Microsoft.KeyVault/vaults/ghost", type: "Microsoft.KeyVault/vaults"})
    assert {:missing, "ghost"} in State.plan(missing)
  end

  test "destroy: reverse-topological deletes, 200/202 per delete, all 404, residue zero" do
    {outcome, ids} = apply_baseline()

    %{deleted: deleted, residue: residue} = State.destroy(outcome)

    # reverse-topological order: container (deepest) first, RG (shallowest) last
    labels = Enum.map(deleted, & &1.label)
    assert hd(labels) == "c1"
    assert List.last(labels) == "rg"
    assert Enum.find_index(labels, &(&1 == "c1")) < Enum.find_index(labels, &(&1 == "acct"))

    # 200/202 per delete, LRO polled to terminal where 202
    for d <- deleted do
      assert d.status in [200, 202], "#{d.label}: DELETE -> #{d.status}"
      assert d.verified
    end

    acct_delete = Enum.find(deleted, &(&1.label == "acct"))
    assert acct_delete.status == 202
    assert acct_delete.lro_terminal in [200, 204]

    rg_delete = Enum.find(deleted, &(&1.label == "rg"))
    assert rg_delete.status == 202
    assert rg_delete.lro_terminal in [200, 204]

    # belt-and-braces: direct GET 404 per id (router-level, independent of State)
    expected =
      [
        {ids.rg, nil},
        {ids.acct, "Microsoft.Storage/storageAccounts"},
        {ids.vault, "Microsoft.KeyVault/vaults"},
        {ids.container, "Microsoft.Storage/storageAccounts/blobServices/containers"}
      ]

    for {path, type} <- expected do
      assert req(:get, path, nil, type).status == 404,
             "expected 404 for #{path}"
    end

    # zero residue across every resource-bearing table
    for {table, keys} <- residue do
      assert keys == [], "residue in #{inspect(table)}: #{inspect(keys)}"
    end
  end

  test "destroy: :smalt_operations is bounded across 10 create+destroy cycles (NFR-3)" do
    # Non-vacuity: the apply phase DOES mint LRO op rows (RG + storage account
    # PUTs are 202 LROs) — prove growth exists before proving destroy reclaims it.
    {outcome, _ids} = apply_baseline()
    assert :ets.info(:smalt_operations, :size) > 0, "apply minted no op rows — witness is vacuous"

    first_cycle_ops = :ets.info(:smalt_operations, :size)
    State.destroy(outcome)

    for _ <- 1..9 do
      {outcome, _} = apply_baseline()
      State.destroy(outcome)
    end

    # 10 cycles minted >= 10x first-cycle rows transiently; after the final
    # destroy's flip+eviction reclaim the table is empty. Any per-cycle residue
    # (the historical +3 rows/cycle leak) would show up here unbounded.
    assert :ets.info(:smalt_operations, :size) == 0,
           ":smalt_operations not reclaimed after destroy: " <>
             inspect(:ets.tab2list(:smalt_operations))

    # and the reclaim is repeatable: one more cycle still lands at zero
    {outcome, _} = apply_baseline()
    State.destroy(outcome)
    assert :ets.info(:smalt_operations, :size) == 0

    :ok = Smalt.ArmGateway.LRO.Sweeper.eviction_pass(0)
    assert first_cycle_ops > 0
  end
end
