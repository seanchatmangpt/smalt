defmodule ArmCascadeTeardownTest do
  use ExUnit.Case
  use Plug.Test

  alias Smalt.ArmGateway.Router
  alias Smalt.Store

  @opts Router.init([])
  @sub "00000000-0000-0000-0000-000000000000"

  @tables [
    :smalt_resources,
    :smalt_resource_groups,
    :smalt_blob_containers,
    :smalt_blobs,
    :smalt_blob_blocks,
    :smalt_blob_policy,
    :smalt_blob_snapshots
  ]

  setup do
    case Store.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    Store.clear()

    Store.put(:smalt_subscriptions, @sub, %{
      "id" => "/subscriptions/#{@sub}",
      "subscriptionId" => @sub,
      "displayName" => "FR6 validation",
      "state" => "Enabled"
    })

    prev_lro_delay_ms = Application.get_env(:smalt, :lro_delay_ms)
    Application.put_env(:smalt, :lro_delay_ms, 0)

    on_exit(fn ->
      if is_nil(prev_lro_delay_ms) do
        Application.delete_env(:smalt, :lro_delay_ms)
      else
        Application.put_env(:smalt, :lro_delay_ms, prev_lro_delay_ms)
      end
    end)

    :ok
  end

  defp call(conn), do: Router.call(conn, @opts)

  defp api_v(type) do
    case Smalt.Registry.latest_version(type) do
      nil -> "2024-01-01"
      v -> v
    end
  end

  defp req(method, path, body \\ nil, type \\ nil) do
    path =
      if type, do: "#{path}?api-version=#{api_v(type)}", else: "#{path}?api-version=2023-07-01"

    conn = if body, do: Plug.Test.conn(method, path, body), else: Plug.Test.conn(method, path)
    call(conn)
  end

  defp poll_lro(conn) do
    case Plug.Conn.get_resp_header(conn, "location") do
      [loc] -> poll_until_terminal(loc)
      [] -> {:no_location, conn.status}
    end
  end

  defp poll_until_terminal(loc, n \\ 50)

  defp poll_until_terminal(_loc, 0), do: :lro_timeout

  defp poll_until_terminal(loc, n) do
    conn = req(:get, loc)

    if conn.status == 202 do
      poll_until_terminal(loc, n - 1)
    else
      {conn.status, Jason.decode!(conn.resp_body)}
    end
  end

  defp arm_path(parts), do: Enum.join(parts, "/")

  defp account_path(rg, acct),
    do:
      arm_path([
        "/subscriptions/#{@sub}/resourceGroups/#{rg}",
        "providers/Microsoft.Storage/storageAccounts/#{acct}"
      ])

  defp blob_services_path(rg, acct), do: account_path(rg, acct) <> "/blobServices/default"

  defp container_path(rg, acct, c),
    do: blob_services_path(rg, acct) <> "/containers/#{c}"

  defp policy_path(rg, acct, c),
    do: container_path(rg, acct, c) <> "/immutabilityPolicies/default"

  defp put_ok!(path, body, type, label) do
    conn = req(:put, path, body, type)

    assert conn.status in [200, 201, 202],
           "#{label} PUT status=#{conn.status} body=#{conn.resp_body}"

    conn
  end

  defp get_status(path, type \\ nil), do: req(:get, path, nil, type).status

  @tag :fr6
  test "FR-6 part 1: storageAccount DELETE -> 202 LRO -> terminal -> account+descendants 404, vault survives" do
    rg = "fr6-rg1"
    acct = "fr6acct1"

    rg_put = req(:put, "/subscriptions/#{@sub}/resourcegroups/#{rg}", %{"location" => "westus"})
    assert rg_put.status in [200, 201], "RG PUT #{rg_put.status} #{rg_put.resp_body}"

    acct_put =
      put_ok!(
        account_path(rg, acct),
        %{"location" => "westus", "sku" => %{"name" => "Standard_LRS"}, "kind" => "StorageV2"},
        "Microsoft.Storage/storageAccounts",
        "storageAccount"
      )

    assert acct_put.status == 202, "expected LRO 202, got #{acct_put.status}"
    assert {st, op} = poll_lro(acct_put)
    assert st == 200, "LRO poll status #{st}"
    assert op["status"] == "Succeeded", "LRO op: #{inspect(op)}"

    put_ok!(
      blob_services_path(rg, acct),
      %{"location" => "westus"},
      "Microsoft.Storage/storageAccounts/blobServices",
      "blobServices"
    )

    put_ok!(
      container_path(rg, acct, "c1"),
      %{"location" => "westus"},
      "Microsoft.Storage/storageAccounts/blobServices/containers",
      "container"
    )

    put_ok!(
      policy_path(rg, acct, "c1"),
      %{"location" => "westus"},
      "Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies",
      "immutabilityPolicy"
    )

    put_ok!(
      "/subscriptions/#{@sub}/resourceGroups/#{rg}/providers/Microsoft.KeyVault/vaults/fr6vault",
      %{
        "location" => "westus",
        "properties" => %{
          "sku" => %{"family" => "A", "name" => "standard"},
          "skuFamily" => "A",
          "tenantId" => @sub
        }
      },
      "Microsoft.KeyVault/vaults",
      "vault"
    )

    put_ok!(
      "/subscriptions/#{@sub}/resourceGroups/#{rg}/providers/Microsoft.KeyVault/vaults/fr6vault/keys/k1",
      %{"location" => "westus", "properties" => %{"kty" => "RSA"}},
      "Microsoft.KeyVault/vaults/keys",
      "key"
    )

    # pre-delete sanity: all GETable
    for {path, type} <- [
          {"/subscriptions/#{@sub}/resourcegroups/#{rg}", "Microsoft.Resources/resourceGroups"},
          {account_path(rg, acct), "Microsoft.Storage/storageAccounts"},
          {blob_services_path(rg, acct), "Microsoft.Storage/storageAccounts/blobServices"},
          {container_path(rg, acct, "c1"),
           "Microsoft.Storage/storageAccounts/blobServices/containers"},
          {policy_path(rg, acct, "c1"),
           "Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies"}
        ] do
      assert get_status(path, type) == 200, "pre-delete GET #{path} not 200"
    end

    # DELETE the storageAccount
    del = req(:delete, account_path(rg, acct), nil, "Microsoft.Storage/storageAccounts")
    assert del.status == 202, "account DELETE status=#{del.status} body=#{del.resp_body}"

    assert {st2, op2} = poll_lro(del)
    assert st2 == 200
    assert op2["status"] == "Succeeded", "delete LRO: #{inspect(op2)}"

    # account + descendants must 404
    for {path, label, type} <- [
          {account_path(rg, acct), "storageAccount", "Microsoft.Storage/storageAccounts"},
          {blob_services_path(rg, acct), "blobServices/default",
           "Microsoft.Storage/storageAccounts/blobServices"},
          {container_path(rg, acct, "c1"), "container",
           "Microsoft.Storage/storageAccounts/blobServices/containers"},
          {policy_path(rg, acct, "c1"), "immutabilityPolicy",
           "Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies"}
        ] do
      status = get_status(path, type)
      assert status == 404, "post-delete #{label} GET -> #{status} (expected 404)"
    end

    # vault + key in the same RG must survive
    vault_status =
      get_status(
        "/subscriptions/#{@sub}/resourceGroups/#{rg}/providers/Microsoft.KeyVault/vaults/fr6vault",
        "Microsoft.KeyVault/vaults"
      )

    key_status =
      get_status(
        "/subscriptions/#{@sub}/resourceGroups/#{rg}/providers/Microsoft.KeyVault/vaults/fr6vault/keys/k1",
        "Microsoft.KeyVault/vaults/keys"
      )

    assert vault_status == 200, "vault should survive account delete, got #{vault_status}"
    assert key_status == 200, "key should survive account delete, got #{key_status}"
  end

  @tag :fr6
  test "FR-6 part 2: RG DELETE cascade empties :smalt_resources AND sweeps data-plane tables" do
    rg = "fr6-rg2"
    acct = "fr6acct2"

    rg_put = req(:put, "/subscriptions/#{@sub}/resourcegroups/#{rg}", %{"location" => "westus"})
    assert rg_put.status in [200, 201], "RG PUT #{rg_put.status} #{rg_put.resp_body}"

    acct_put =
      put_ok!(
        account_path(rg, acct),
        %{"location" => "westus", "sku" => %{"name" => "Standard_LRS"}, "kind" => "StorageV2"},
        "Microsoft.Storage/storageAccounts",
        "storageAccount"
      )

    assert acct_put.status == 202
    assert {st, op} = poll_lro(acct_put)
    assert st == 200 and op["status"] == "Succeeded", "LRO: #{inspect(op)}"

    # data-plane rows seeded exactly as blob_storage.ex writes them
    Store.put(:smalt_blob_containers, "#{acct}/c1", %{"name" => "c1", "account" => acct})
    Store.put(:smalt_blobs, "#{acct}/c1/b1", %{"name" => "b1", "account" => acct})

    # DELETE RG
    del = req(:delete, "/subscriptions/#{@sub}/resourcegroups/#{rg}")

    assert del.status == 202, "RG DELETE status=#{del.status} body=#{del.resp_body}"

    assert {st2, op2} = poll_lro(del)
    assert st2 == 200 and op2["status"] == "Succeeded", "RG delete LRO: #{inspect(op2)}"

    # RG GET -> 404
    assert get_status("/subscriptions/#{@sub}/resourcegroups/#{rg}") == 404

    # ARM-plane: :smalt_resources under the RG must be empty
    rg_base = String.downcase("/subscriptions/#{@sub}/resourceGroups/#{rg}/")
    remaining = Store.prefix_keys(:smalt_resources, rg_base)
    assert remaining == [], "ARM-plane residue under RG: #{inspect(remaining)}"

    # FR-6 completion (D127): data-plane tables must be swept for the account
    post_c = Store.prefix_keys(:smalt_blob_containers, "")
    post_b = Store.prefix_keys(:smalt_blobs, "")

    # residue audit: every Store table's remaining keys

    for t <- @tables do
      if :ets.info(t) == :undefined do
      else
      end
    end

    assert post_c == [],
           "DATA-PLANE RESIDUE :smalt_blob_containers=#{inspect(post_c)} (D127 cascade sweep not applied to data-plane tables)"

    assert post_b == [],
           "DATA-PLANE RESIDUE :smalt_blobs=#{inspect(post_b)} (D127 cascade sweep not applied to data-plane tables)"
  end

  @tag :fr6
  test "FR-6 part 3: vault secret rows do not orphan across RG delete, account delete, or vault delete" do
    rg = "fr6-rg3"
    acct = "fr6acct3"
    vault_base = "/subscriptions/#{@sub}/resourceGroups/#{rg}/providers/Microsoft.KeyVault/vaults"

    rg_put = req(:put, "/subscriptions/#{@sub}/resourcegroups/#{rg}", %{"location" => "westus"})
    assert rg_put.status in [200, 201], "RG PUT #{rg_put.status} #{rg_put.resp_body}"

    put_ok!(
      account_path(rg, acct),
      %{"location" => "westus", "sku" => %{"name" => "Standard_LRS"}, "kind" => "StorageV2"},
      "Microsoft.Storage/storageAccounts",
      "storageAccount"
    )
    |> poll_lro()
    |> elem(0)
    |> then(&assert &1 == 200)

    put_ok!(
      "#{vault_base}/fr6vault",
      %{
        "location" => "westus",
        "properties" => %{
          "sku" => %{"family" => "A", "name" => "standard"},
          "skuFamily" => "A",
          "tenantId" => @sub
        }
      },
      "Microsoft.KeyVault/vaults",
      "vault"
    )

    # ARM secret child record FIRST so the capture-then-sweep has a name to
    # capture on teardown; the PUT also cross-plane-seeds the data-plane row
    # (seed_data_plane_secret/5), which is the residue under test.
    put_ok!(
      "#{vault_base}/fr6vault/secrets/kv-shape",
      %{"location" => "westus", "properties" => %{"value" => "s3cret"}},
      "Microsoft.KeyVault/vaults/secrets",
      "secret"
    )

    # Seed the data-plane secret rows exactly as seed_data_plane_secret/5 does:
    # bare secret-name keys, no vault scoping (kv-shape witnessed in the FR-6
    # composite fixture destroy residue: ["kv-shape"]).
    Store.put(:smalt_vault_secrets, "kv-shape", %{
      "value" => "s3cret",
      "id" => "https://localhost:8443/secrets/kv-shape/1",
      "attributes" => %{"enabled" => true, "created" => 0, "updated" => 0},
      "version" => "1"
    })

    assert Store.get(:smalt_vault_secrets, "kv-shape") != :error, "pre-delete sanity"

    # (a) RG DELETE sweeps the vault-secrets table for swept secret names
    del = req(:delete, "/subscriptions/#{@sub}/resourcegroups/#{rg}")
    assert del.status == 202, "RG DELETE status=#{del.status}"
    assert {st, op} = poll_lro(del)
    assert st == 200 and op["status"] == "Succeeded", "RG delete LRO: #{inspect(op)}"

    assert Store.get(:smalt_vault_secrets, "kv-shape") == :error,
           "FR-6 RESIDUE :smalt_vault_secrets=[\"kv-shape\"] after RG delete (vault branch of the cascade not wired)"

    # Re-seed for the storageAccount branch: an RG-less sweep of the vault must
    # still capture the secret name from the ARM child key.
    Store.put(:smalt_vault_secrets, "kv-shape", %{"value" => "s3cret", "version" => "2"})

    # (b) storageAccount DELETE must NOT sweep vault secrets (vault survives)
    rg_put = req(:put, "/subscriptions/#{@sub}/resourcegroups/#{rg}", %{"location" => "westus"})
    assert rg_put.status in [200, 201]

    # re-provision the account (the RG delete in (a) swept it) so the delete
    # leg below hits a real 202 LRO, not 404.
    put_ok!(
      account_path(rg, acct),
      %{"location" => "westus", "sku" => %{"name" => "Standard_LRS"}, "kind" => "StorageV2"},
      "Microsoft.Storage/storageAccounts",
      "storageAccount"
    )
    |> poll_lro()
    |> elem(0)
    |> then(&assert &1 == 200)

    put_ok!(
      "#{vault_base}/fr6vault",
      %{"location" => "westus", "properties" => %{"tenantId" => @sub}},
      "Microsoft.KeyVault/vaults",
      "vault"
    )

    # ARM secret child record so the capture-then-sweep has a name to capture
    # when the vault (not the account) is torn down.
    put_ok!(
      "#{vault_base}/fr6vault/secrets/kv-shape",
      %{"location" => "westus", "properties" => %{"value" => "s3cret"}},
      "Microsoft.KeyVault/vaults/secrets",
      "secret"
    )

    assert Store.get(:smalt_vault_secrets, "kv-shape") != :error, "re-seeded"

    del_acct = req(:delete, account_path(rg, acct), nil, "Microsoft.Storage/storageAccounts")
    assert del_acct.status == 202, "account DELETE status=#{del_acct.status}"
    assert {st2, op2} = poll_lro(del_acct)
    assert st2 == 200 and op2["status"] == "Succeeded"

    assert Store.get(:smalt_vault_secrets, "kv-shape") != :error,
           "account delete must not sweep vault secrets (vault survives account teardown)"

    # (c) vault DELETE sweeps its data-plane secret rows
    del_vault = req(:delete, "#{vault_base}/fr6vault", nil, "Microsoft.KeyVault/vaults")

    assert del_vault.status == 200,
           "vault DELETE status=#{del_vault.status} #{del_vault.resp_body}"

    assert Store.get(:smalt_vault_secrets, "kv-shape") == :error,
           "FR-6 RESIDUE :smalt_vault_secrets=[\"kv-shape\"] after vault delete"

    assert get_status("#{vault_base}/fr6vault", "Microsoft.KeyVault/vaults") == 404
  end
end
