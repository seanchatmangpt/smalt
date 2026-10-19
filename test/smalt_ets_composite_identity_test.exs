defmodule Smalt.EtsCompositeIdentityTest do
  @moduledoc """
  NFR-4 composite ETS baseline-identity fence (v26.10.16 validation lane,
  lane 503, 2026-10-16).

  Extends `Smalt.EtsBaselineIdentityTest` (single resource) to the FULL
  per-resource composite topology: RG + storage account + blobServices +
  container + Key Vault + secret + Cosmos account + sqlDatabase + sqlContainer
  + Service Bus namespace + queue + Event Hub namespace + hub — all provisioned
  via in-process `Smalt.ArmGateway.Router` dispatch (Plug.Test), torn down in
  reverse-topological order, with the RG delete driven through the real LRO
  poll + retention-eviction pass. All 28 non-excluded tables must return to
  strict `:ets.tab2list` identity with the seed-row baseline; any residue is
  dumped per table with key patterns for the orphan hunt.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Smalt.ArmGateway.Router
  alias Smalt.Registry
  alias Smalt.Store

  @sub "00000000-0000-0000-0000-000000000000"
  @rg "ets-composite-rg"
  @rg_path "/subscriptions/#{@sub}/resourceGroups/#{@rg}"

  @moduletag timeout: 300_000
  @moduletag :stress

  @opts Router.init([])

  # Same sweeper-owned exclusion as the baseline identity test.
  @excluded [:smalt_sb_locks]

  test "full composite provision + reverse-topological teardown restores strict ETS identity" do
    ensure_store()
    baseline = snapshot()

    # ---------- provision (forward topological) ----------
    rg_api = api("Microsoft.Resources/resourceGroups")

    assert {status, _} = put_res(@rg_path, rg_api, %{"location" => "eastus"})
    assert status in [200, 201], "RG PUT -> #{status}"

    # storage account -> blobServices/default -> container
    acct_api = api("Microsoft.Storage/storageAccounts")
    acct_path = @rg_path <> "/providers/Microsoft.Storage/storageAccounts/etscompacct"

    assert {status, body} =
             put_res(acct_path, acct_api, %{
               "location" => "eastus",
               "sku" => %{"name" => "Standard_LRS"},
               "kind" => "StorageV2"
             })

    assert status in [200, 201], "storage account PUT -> #{status}: #{body}"

    bsvc_path = acct_path <> "/blobServices/default"

    assert {status, body} =
             put_res(bsvc_path, api("Microsoft.Storage/storageAccounts/blobServices"), %{
               "location" => "eastus"
             })

    assert status in [200, 201], "blobServices PUT -> #{status}: #{body}"

    cont_path = bsvc_path <> "/containers/etscompcont"

    assert {status, body} =
             put_res(
               cont_path,
               api("Microsoft.Storage/storageAccounts/blobServices/containers"),
               %{
                 "location" => "eastus",
                 "properties" => %{"publicAccess" => "None"}
               }
             )

    assert status in [200, 201], "container PUT -> #{status}: #{body}"

    # key vault -> secret
    kv_path = @rg_path <> "/providers/Microsoft.KeyVault/vaults/ets-comp-kv"

    assert {status, body} =
             put_res(kv_path, api("Microsoft.KeyVault/vaults"), %{
               "location" => "eastus",
               "properties" => %{
                 "sku" => %{"family" => "A", "name" => "standard"},
                 "tenantId" => @sub,
                 "enableSoftDelete" => true
               }
             })

    assert status in [200, 201], "vault PUT -> #{status}: #{body}"

    sec_path = kv_path <> "/secrets/ets-comp-secret"

    assert {status, body} =
             put_res(sec_path, api("Microsoft.KeyVault/vaults/secrets"), %{
               "location" => "eastus",
               "properties" => %{"value" => "s3cret"}
             })

    assert status in [200, 201], "secret PUT -> #{status}: #{body}"

    # cosmos account -> sqlDatabase -> sqlContainer
    cosmos_path = @rg_path <> "/providers/Microsoft.DocumentDB/databaseAccounts/ets-comp-cosmos"

    assert {status, body} =
             put_res(cosmos_path, api("Microsoft.DocumentDB/databaseAccounts"), %{
               "location" => "eastus",
               "kind" => "GlobalDocumentDB",
               "properties" => %{"databaseAccountOfferType" => "Standard"}
             })

    assert status in [200, 201], "cosmos account PUT -> #{status}: #{body}"

    db_path = cosmos_path <> "/sqlDatabases/etscompdb"

    assert {status, body} =
             put_res(db_path, api("Microsoft.DocumentDB/databaseAccounts/sqlDatabases"), %{
               "location" => "eastus",
               "properties" => %{}
             })

    assert status in [200, 201], "sqlDatabase PUT -> #{status}: #{body}"

    col_path = db_path <> "/sqlContainers/etscompcol"

    assert {status, body} =
             put_res(col_path, api("Microsoft.DocumentDB/databaseAccounts/sqlContainers"), %{
               "location" => "eastus",
               "properties" => %{
                 "resource" => %{"id" => "etscompcol", "partitionKey" => %{"paths" => ["/pk"]}}
               }
             })

    assert status in [200, 201], "sqlContainer PUT -> #{status}: #{body}"

    # service bus namespace -> queue
    sb_path = @rg_path <> "/providers/Microsoft.ServiceBus/namespaces/ets-comp-sb-ns"

    assert {status, body} =
             put_res(sb_path, api("Microsoft.ServiceBus/namespaces"), %{
               "location" => "eastus",
               "sku" => %{"name" => "Standard", "tier" => "Standard"}
             })

    assert status in [200, 201], "SB namespace PUT -> #{status}: #{body}"

    q_path = sb_path <> "/queues/ets-comp-q"

    assert {status, body} =
             put_res(q_path, api("Microsoft.ServiceBus/namespaces/queues"), %{
               "location" => "eastus",
               "properties" => %{"lockDuration" => "PT1M"}
             })

    assert status in [200, 201], "SB queue PUT -> #{status}: #{body}"

    # event hub namespace -> hub
    eh_path = @rg_path <> "/providers/Microsoft.EventHub/namespaces/ets-comp-eh-ns"

    assert {status, body} =
             put_res(eh_path, api("Microsoft.EventHub/namespaces"), %{
               "location" => "eastus",
               "sku" => %{"name" => "Standard", "tier" => "Standard"}
             })

    assert status in [200, 201], "EH namespace PUT -> #{status}: #{body}"

    hub_path = eh_path <> "/eventhubs/ets-comp-hub"

    assert {status, body} =
             put_res(hub_path, api("Microsoft.EventHub/namespaces/eventhubs"), %{
               "location" => "eastus",
               "properties" => %{"partitionCount" => 2}
             })

    assert status in [200, 201], "eventhub PUT -> #{status}: #{body}"

    # ---------- GET spot-checks (real 200s on the wire path) ----------
    for path <- [
          acct_path,
          cont_path,
          kv_path,
          sec_path,
          cosmos_path,
          db_path,
          col_path,
          q_path,
          hub_path
        ] do
      conn =
        :get
        |> conn(path <> "?api-version=2020-06-01")
        |> Router.call(@opts)

      assert conn.status == 200, "GET #{path} -> #{conn.status}"
    end

    # ---------- reverse-topological teardown ----------
    teardown_step(hub_path)
    teardown_step(eh_path)
    teardown_step(q_path)
    teardown_step(sb_path)
    teardown_step(col_path)
    teardown_step(db_path)
    teardown_step(cosmos_path)
    teardown_step(sec_path)
    teardown_step(kv_path)
    teardown_step(cont_path)
    teardown_step(bsvc_path)
    teardown_step(acct_path)

    # ---------- RG delete (LRO) ----------
    conn =
      :delete
      |> conn(@rg_path <> "?api-version=#{rg_api}")
      |> Router.call(@opts)

    assert conn.status in [200, 202, 204], "RG DELETE -> #{conn.status}"

    conn =
      :get
      |> conn(@rg_path <> "?api-version=#{rg_api}")
      |> Router.call(@opts)

    assert conn.status == 404, "post-delete RG GET -> #{conn.status}, expected 404"

    # Real LRO poll + retention-eviction pass, same as the baseline identity
    # test — terminal op rows (RG delete + the LRO resource PUTs) are reaped
    # through the genuine route.
    for op_id <- all_op_keys(), do: poll_to_terminal(op_id)

    prev_lro = Application.get_env(:smalt, :lro_retention_ms, :__unset__)
    Application.put_env(:smalt, :lro_retention_ms, 0)

    on_exit(fn ->
      if prev_lro == :__unset__,
        do: Application.delete_env(:smalt, :lro_retention_ms),
        else: Application.put_env(:smalt, :lro_retention_ms, prev_lro)
    end)

    # Poll-replaceable sync-wait (sleeps.md §A2): drive eviction passes until
    # the snapshot converges to baseline instead of a fixed settle sleep.
    SmaltTest.AssertEventually.eventually(
      fn ->
        :ok = Smalt.ArmGateway.LRO.Sweeper.eviction_pass()

        if snapshot() == baseline do
          {:ok, :converged}
        else
          {:retry, :diverged}
        end
      end,
      deadline_ms: 5_000,
      observable: "post-eviction store snapshot converged to baseline"
    )

    :ok = Smalt.ArmGateway.LRO.Sweeper.eviction_pass()

    # ---------- strict identity fence ----------
    after_state = snapshot()

    assert after_state == baseline, """
    NFR-4 composite ETS baseline-identity FAILURE: the composite lifecycle left residue.

    Orphan dump (after vs baseline, differing tables only):
    #{Enum.map_join(diffs(baseline, after_state), "\n", fn {t, b, a} -> "  #{t}\n    baseline: #{inspect(b)}\n    after:    #{inspect(a)}\n    orphan keys: #{inspect(Enum.map(a -- b, &elem(&1, 0)))}" end)}
    """

    # Prefix-based orphan hunt report on a clean pass: none of the composite
    # key families may appear anywhere in the post-destroy store.
    for {table, rows} <- after_state,
        {key, _} <- rows,
        orphanish?(key) do
      flunk("orphan in #{table}: #{inspect(key)}")
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp api(type), do: Registry.latest_version(type) || "2020-06-01"

  defp put_res(path, api_version, payload) do
    conn =
      :put
      |> conn(path <> "?api-version=#{api_version}", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    case conn.status do
      202 ->
        # LRO PUT (storage accounts, cosmos accounts): drive the real poll
        # path to terminality, then confirm the resource materialized.
        op = Jason.decode!(conn.resp_body)
        poll_to_terminal(op["name"])
        get_conn = :get |> conn(path <> "?api-version=#{api_version}") |> Router.call(@opts)
        {get_conn.status, get_conn.resp_body}

      status ->
        {status, conn.resp_body}
    end
  end

  defp teardown_step(path) do
    conn =
      :delete
      |> conn(path <> "?api-version=2020-06-01")
      |> Router.call(@opts)

    assert conn.status in [200, 202, 204], "DELETE #{path} -> #{conn.status}: #{conn.resp_body}"
  end

  # Orphan-hunt classifier: any key that still references a composite-family
  # name after teardown is residue regardless of which table carries it.
  @composite_families [
    "etscompacct",
    "ets-comp-sb-ns",
    "ets-comp-eh-ns",
    "ets-comp-cosmos",
    "ets-comp-kv",
    "etscompdb",
    "ets-comp-q",
    "ets-comp-hub",
    "ets-composite-rg"
  ]

  defp orphanish?(key) when is_binary(key),
    do: Enum.any?(@composite_families, &String.contains?(key, &1))

  defp orphanish?(key) when is_tuple(key), do: Enum.any?(Tuple.to_list(key), &orphanish?/1)
  defp orphanish?(_), do: false

  defp snapshot do
    Store.table_names()
    |> Kernel.--(@excluded)
    |> Map.new(fn table -> {table, Enum.sort(:ets.tab2list(table))} end)
  end

  defp diffs(baseline, after_state) do
    for {t, b} <- baseline, a = Map.get(after_state, t), a != b do
      {t, b, a}
    end
  end

  defp all_op_keys do
    keys = for {key, _} <- :ets.tab2list(:smalt_operations), do: key
    assert keys != [], "expected LRO op rows after RG delete, got none"
    keys
  end

  defp poll_to_terminal(op_id) do
    path = "/subscriptions/#{@sub}/operations/#{op_id}"
    deadline = System.monotonic_time(:millisecond) + 5_000
    do_poll(path, deadline)
  end

  defp do_poll(path, deadline) do
    conn =
      :get
      |> conn(path <> "?api-version=2020-06-01")
      |> Router.call(@opts)

    body = Jason.decode!(conn.resp_body)

    case body["status"] do
      "InProgress" ->
        if System.monotonic_time(:millisecond) > deadline,
          do: flunk("LRO op #{path} never reached terminality: #{inspect(body)}")

        Process.sleep(20)
        do_poll(path, deadline)

      status when is_binary(status) ->
        :ok

      nil ->
        flunk("operation poll returned no status member: #{inspect(body)}")
    end
  end

  defp ensure_store do
    case Store.start_link([]) do
      {:ok, _} ->
        Store.clear()
        :ok

      {:error, {:already_started, _}} ->
        if :ets.info(:smalt_subscriptions) == :undefined do
          pid = Process.whereis(Store)
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> ensure_store()
          after
            500 -> ensure_store()
          end
        end

        Store.clear()
        :ok
    end
  end
end
