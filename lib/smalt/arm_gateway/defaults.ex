defmodule Smalt.ArmGateway.Defaults do
  @moduledoc """
  ARM PUT-body defaults for the three storefront resource families.

  `@table` maps resource type to a defaults map deep-merged UNDER the
  user's PUT body (`apply/2`): user values win per key, and nested
  `properties` deep-merge so partial user properties still receive
  defaults. Every default is validator-acceptable per
  `Smalt.GraphLaw.Validator.validate_resource/2` (tests assert this).

  Pure functions only — no router coupling, no I/O.

  Second surface, `enrich/4`: name-interpolated values (vaultUri,
  primaryEndpoints, serviceBusEndpoint, RootManageSharedAccessKey
  authorizationRules) deep-merged UNDER the user properties at PUT-persist
  time (`build_resource_record`) so GET stays verbatim. Closed the azurerm
  4.54 FR-5 divergences (vault vaultUri, storage primaryEndpoints nil
  deref, SB/EH namespace property derefs + listKeys).
  """

  # Lane-403 unblock fix (compile-freeze SLA disclosure): @enrich_table was
  # a module attribute whose fn bodies call the module's own defp
  # iso8601_now/0 — local calls are not resolvable during attribute
  # expansion (compile error: "there is no such import"). Demoted to a
  # function so the closures compile in module scope and timestamps are
  # computed at call time (also fixes the would-be frozen compile-time
  # timestamps).
  defp enrich_defaults do
    %{
      # KD-CANDIDATE (KD-T5-F1): deliberate divergence from real Azure URI
      # form. Real ARM returns vaultUri = "https://<name>.vault.azure.net/"
      # (public DNS); azurerm 4.54 POLLS that URI directly to wait for key
      # vault availability (wire: T5 cleanroom tf-apply.log — "dial tcp:
      # lookup kv-smalt-fixture.vault.azure.net: no such host"), so the
      # emulator echoes the gateway request authority (the same loopback
      # https twin the client already trusts) instead. Data-plane endpoint
      # is loopback by design in this emulator; when an authority is
      # unavailable (pure enrich/4 calls) the real-Azure form is kept for
      # shape parity.
      "Microsoft.KeyVault/vaults" => fn name, _id, authority ->
        vault_uri =
          if is_binary(authority) and authority != "" do
            # localhost dials [::1] from Go clients; the listeners bind
            # 127.0.0.1 (witnessed: azurerm keyvault poll looped forever —
            # cleanroom comment "azurerm resolves localhost to [::1]").
            authority
            |> String.trim_trailing("/")
            |> String.replace("://localhost:", "://127.0.0.1:")
          else
            "https://#{name}.vault.azure.net"
          end

        %{"properties" => %{"vaultUri" => "#{vault_uri}/"}}
      end,
      "Microsoft.Storage/storageAccounts" => fn name, _id, _authority ->
        # Suffixes consistent with the providers metadata dnsSuffixes
        # ("storage" => "smalt.local") advertised on this emulator.
        %{
          "properties" => %{
            "primaryEndpoints" => %{
              "blob" => "https://#{name}.blob.smalt.local/",
              "queue" => "https://#{name}.queue.smalt.local/",
              "table" => "https://#{name}.table.smalt.local/",
              "file" => "https://#{name}.file.smalt.local/",
              "web" => "https://#{name}.web.smalt.local/"
            }
          }
        }
      end,
      "Microsoft.ServiceBus/namespaces" => fn name, id, _authority ->
        # Real-ARM default namespace property set azurerm 4.54
        # servicebus_namespace read dereferences, plus the RootManageSharedAccessKey
        # authorizationRule (keys served by POST .../authorizationRules/:rule/listKeys).
        %{
          "properties" => %{
            "status" => "Active",
            # Module-attribute lambdas are evaluated at compile time before
            # defp iso8601_now/0 exists — call DateTime directly here.
            "createdAt" => DateTime.to_iso8601(DateTime.utc_now()),
            "updatedAt" => DateTime.to_iso8601(DateTime.utc_now()),
            "serviceBusEndpoint" => "https://#{name}.servicebus.smalt.local:443/",
            "zoneRedundant" => false,
            "disableLocalAuth" => false,
            "publicNetworkAccess" => "Enabled",
            "minimumTlsVersion" => "1.2",
            "provisioningState" => "Succeeded",
            "authorizationRules" => [
              %{
                "id" => "#{id}/authorizationRules/RootManageSharedAccessKey",
                "name" => "RootManageSharedAccessKey",
                "type" => "Microsoft.ServiceBus/namespaces/authorizationRules",
                "rights" => ["Listen", "Manage", "Send"]
              }
            ]
          }
        }
      end,
      "Microsoft.EventHub/namespaces" => fn name, _id, _authority ->
        # One clock read shared by BOTH spellings — the dual-key contract is
        # equal ISO8601 values, not two independent timestamps.
        created_at = DateTime.to_iso8601(DateTime.utc_now())

        # Full real-ARM namespace property set: azurerm 4.54
        # resourceEventHubNamespaceRead nil-panicked on the sparse record
        # (eventhub_namespace_resource.go:541; exact field not identifiable
        # from TF_LOG — full set returned instead).
        %{
          "properties" => %{
            "isAutoInflateEnabled" => false,
            "maximumThroughputUnits" => 0,
            "kafkaEnabled" => true,
            "zoneRedundant" => false,
            "clusterArmId" => nil,
            # azurerm eventhub_namespace_resource.go:541 dereferences the
            # namespace created-timestamp. Real ARM EH namespaces emit
            # camelCase "createdAt" in ARM JSON; carry BOTH spellings with
            # the same value until a TF_LOG capture proves which key
            # azurerm 4.54 actually dereferences (KD-candidate: unresolved
            # snake_case-vs-camelCase ARM property spelling).
            "createdAt" => created_at,
            "created_at" => created_at,
            "updatedAt" => DateTime.to_iso8601(DateTime.utc_now()),
            "serviceBusEndpoint" => "https://#{name}.servicebus.smalt.local:443/",
            "status" => "Active",
            "disableLocalAuth" => false,
            "publicNetworkAccess" => "Enabled",
            "minimumTlsVersion" => "1.2",
            "provisioningState" => "Succeeded"
          }
        }
      end
    }
  end

  @table %{
    "Microsoft.Storage/storageAccounts" => %{
      "location" => "[resourceGroup().location]",
      "sku" => %{"name" => "Standard_LRS"},
      "kind" => "StorageV2",
      "properties" => %{
        "supportsHttpsTrafficOnly" => true,
        "allowBlobPublicAccess" => true,
        "minimumTlsVersion" => "TLS1_2",
        "networkAcls" => %{
          "bypass" => "AzureServices",
          "defaultAction" => "Allow"
        }
      }
    },
    "Microsoft.KeyVault/vaults" => %{
      "location" => "[resourceGroup().location]",
      "properties" => %{
        "sku" => %{"family" => "A", "name" => "standard"},
        "tenantId" => "[subscription().tenantId]",
        "enableSoftDelete" => true,
        "softDeleteRetentionInDays" => 90,
        "enableRbacAuthorization" => true
      }
    },
    "Microsoft.DocumentDB/databaseAccounts" => %{
      "location" => "[resourceGroup().location]",
      "kind" => "GlobalDocumentDB",
      "properties" => %{
        "databaseAccountOfferType" => "Standard",
        "consistencyPolicy" => %{"defaultConsistencyLevel" => "Session"},
        "enableMultipleWriteLocations" => false
      }
    }
  }

  @doc "The enrichment table (name-interpolated persist-time defaults)."
  def enrich_table, do: enrich_defaults()

  @doc """
  Deep-merge the type's enrichment defaults (keyed by resource name) UNDER
  the record-shaped merged `body` (i.e. the `%{"properties" => ...}` map,
  not the properties map itself). Unknown type → body unchanged. Pure.
  """
  # Optional 5th arg: the gateway request authority (scheme://host:port) the
  # PUT arrived on. Loopback-facing enrichments (vaultUri, KD-T5-F1) echo it;
  # nil keeps the real-Azure name-interpolated form.
  def enrich(type, name, id, body, authority \\ nil)

  def enrich(type, name, id, body, authority) when is_map(body) do
    case Map.fetch(enrich_defaults(), type) do
      {:ok, fun} -> deep_merge(fun.(name, id, authority), body)
      :error -> body
    end
  end

  # Catch-all clause: non-map `props` passes through unchanged (spec-wise the
  # return type is still map(); the fallback preserves the input term).
  def enrich(_type, _name, _id, props, _authority), do: props

  @doc "The defaults table."
  def table, do: @table

  @doc """
  Deep-merge `defaults` under `body`: user map wins per key at every
  level; maps on both sides merge recursively; defaults-only keys appear.
  Non-map values (lists, scalars) are replaced, never merged.
  """
  def apply(type, body) when is_map(body) do
    case Map.fetch(@table, type) do
      {:ok, defaults} -> deep_merge(defaults, body)
      :error -> body
    end
  end

  def apply(_type, body), do: body

  defp deep_merge(defaults, user) when is_map(defaults) and is_map(user) do
    Map.merge(defaults, user, fn _k, d, u ->
      deep_merge(d, u)
    end)
  end

  defp deep_merge(_defaults, user), do: user
end
