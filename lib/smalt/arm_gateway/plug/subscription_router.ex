
defmodule Smalt.ArmGateway.Plug.SubscriptionRouter do
  @moduledoc """
  Route-family plug (T06, v26.10.29): tenant/subscription/resource-group/tagNames face.

  Pass-through dispatch: routes were extracted verbatim from the monolithic
  router; a conn no route claims returns UNCHANGED (not halted) via the
  trailing pass-through match, so the front pipeline composes unchanged.
  """
  import Smalt.ArmGateway.Plug.Common
  import Smalt.ArmGateway.Engine.Lro

  alias Smalt.ArmGateway.LRO
  alias Smalt.ArmGateway.ProviderMatrix
  alias Smalt.ArmGateway.SkuQuota
  alias Smalt.ArmGateway.ProviderState
  alias Smalt.ArmGateway.TagsLocks
  alias Smalt.Store
  alias Smalt.DataPlane.BlobStorage
  alias Smalt.Policy

  # -- module attributes (verbatim from the monolith) --
  @system_data %{
    "createdBy" => "smalt-dev-substrate",
    "createdByType" => "Application",
    "createdAt" => "2026-01-01T00:00:00.0000000+00:00"
  }
  @home_tenant_id "00000000-0000-0000-0000-000000000000"
  @rg_type "Microsoft.Resources/resourceGroups"

  use Plug.Router
  require Logger
  plug(:match)
  plug(:dispatch)

  # T06 dispatch law: a family route that ANSWERED (state :sent) must halt, or
  # the front pipeline would keep piping and the front catch-all would
  # re-dispatch on a sent conn (Plug.Conn.AlreadySentError). Answered conns
  # halt here; unclaimed conns (state :unset) pass through untouched.
  def call(conn, opts) do
    case super(conn, opts) do
      %Plug.Conn{state: :sent, halted: false} = c -> halt(c)
      c -> c
    end
  end


  defp send_tenant_list(conn) do
    minted =
      Smalt.Egress.SignIns.events()
      |> Enum.map(& &1.tenant_id)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == @home_tenant_id))

    home_row = %{
      "id" => "/tenants/#{@home_tenant_id}",
      "tenantId" => @home_tenant_id,
      "displayName" => "Sovereign",
      "tenantCategory" => "Home"
    }

    minted_rows =
      for tid <- minted do
        %{
          "id" => "/tenants/#{tid}",
          "tenantId" => tid,
          "displayName" => tid
        }
      end

    send_json(conn, 200, Jason.encode!(%{"value" => [home_row | minted_rows]}))
  end


  # SHIM-COURT tags (2026-10-16, lane 429 reconciliation, FR-5 re-witness
  # /tmp/tf-plan-probe.hPaBPZ): ONE law for create AND update — an RG PUT is
  # a FULL REPLACE, so omitted/null/empty tags REMOVE the stored tags and the
  # GET renders `"tags": null` (azurerm normalizes empty tags to null in
  # state; echoing `{}` drifts every refresh-only plan `+ tags = {}`).
  # Only an explicit non-empty tags map renders as a map.
  defp rg_tags(payload, _created?) do
    case Map.fetch(payload, "tags") do
      {:ok, %{} = tags} when map_size(tags) > 0 -> tags
      _ -> nil
    end
  end

  # SHIM-COURT tags (2026-10-16, lane 429 reconciliation): the RG GET
  # renders stored tags through the same null-when-empty law — a stale
  # `%{}` record (pre-reconciliation update) still renders null, never `{}`.

  # SHIM-COURT tags (2026-10-16, lane 429 reconciliation): the RG GET
  # renders stored tags through the same null-when-empty law — a stale
  # `%{}` record (pre-reconciliation update) still renders null, never `{}`.
  defp normalize_rg(%{} = rg) do
    Map.update(rg, "tags", nil, &normalize_tags/1)
  end


  defp handle_rg_list(conn, sub_id) do
    with :ok <- check_api_version(conn, @rg_type) do
      rgs =
        Store.list_prefix(:smalt_resource_groups, "/subscriptions/#{sub_id}/resourcegroups/")
        |> apply_lifecycle_expand(conn)

      send_list(conn, rgs)
    else
      {:respond, conn} -> conn
    end
  end


  defp handle_rg_put(conn, sub_id, rg_name) do
    with :ok <- check_api_version(conn, @rg_type) do
      do_rg_put(conn, sub_id, rg_name)
    else
      {:respond, conn} -> conn
    end
  end


  defp handle_rg_patch(conn, sub_id, rg_name) do
    with :ok <- check_api_version(conn, @rg_type) do
      do_rg_patch(conn, sub_id, rg_name)
    else
      {:respond, conn} -> conn
    end
  end


  defp do_rg_patch(conn, sub_id, rg_name) do
    rg_id = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"
    key = String.downcase(rg_id)

    case Store.get(:smalt_resource_groups, key) do
      {:ok, existing} when is_map(existing) ->
        payload = conn.body_params

        merged_tags =
          case Map.fetch(payload, "tags") do
            {:ok, %{} = new_tags} ->
              # Merge with existing tags if present, or set
              cur = Map.get(existing, "tags") || %{}
              Map.merge(cur, new_tags)

            _ ->
              Map.get(existing, "tags")
          end

        updated =
          existing
          |> Map.put("tags", normalize_tags(merged_tags))

        Store.put(:smalt_resource_groups, key, updated)
        :ok = ProviderState.touch_lifecycle(rg_id)
        send_json(conn, 200, Jason.encode!(normalize_rg(updated)))

      _ ->
        send_arm_error(
          conn,
          404,
          "ResourceGroupNotFound",
          "Resource group '#{rg_name}' could not be found.",
          rg_id
        )
    end
  end


  defp handle_rg_resources_list(conn, sub_id, rg_name) do
    with :ok <- check_api_version(conn, nil) do
      prefix = String.downcase("/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/")

      items =
        Store.list_prefix(:smalt_resources, prefix)
        |> Enum.filter(&renderable_record?/1)
        |> Enum.filter(&subscription_resource_filter(conn, &1))

      send_list(conn, items)
    else
      {:respond, conn} -> conn
    end
  end


  defp handle_locations_list(conn, sub_id) do
    with :ok <- check_api_version(conn, nil) do
      locations =
        ProviderMatrix.default_locations()
        |> Enum.map(fn loc ->
          display_name =
            case loc do
              "eastus" -> "East US"
              "westus2" -> "West US 2"
              "local" -> "Local"
              other -> other
            end

          %{
            "id" => "/subscriptions/#{sub_id}/locations/#{loc}",
            "name" => loc,
            "displayName" => display_name,
            "regionalDisplayName" => "(US) #{display_name}"
          }
        end)

      send_json(conn, 200, Jason.encode!(%{"value" => locations}))
    else
      {:respond, conn} -> conn
    end
  end


  defp do_rg_put(conn, sub_id, rg_name) do
    rg_id = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"
    payload = conn.body_params
    requested = Map.get(payload, "location", "eastus")

    existing =
      case Store.get(:smalt_resource_groups, String.downcase(rg_id)) do
        {:ok, existing} when is_map(existing) -> existing
        _ -> nil
      end

    # EXPL9-R2 F3: real Azure requires `location` on CREATE. A PUT with an
    # empty/no-location body previously fell through to the "eastus" default
    # and minted a silently wrong record (success-on-missing-field). Updates
    # keep the R30 semantics: location immutable, defaulted value tolerated.
    refused_create? =
      is_nil(existing) and not Map.has_key?(payload, "location")

    # ARM treats a resource group's location as immutable on update (R30):
    # an update PUT that changes location is refused with a typed 400,
    # never a silent overwrite of the original.
    refused_update? =
      existing != nil and Map.get(existing, "location") != requested

    cond do
      refused_create? ->
        send_arm_error(
          conn,
          400,
          "LocationRequired",
          "The request body must specify a 'location' for resource group creation. Location: cannot be null or empty.",
          rg_id
        )

      refused_update? ->
        send_arm_error(
          conn,
          400,
          "LocationMismatch",
          "Resource group location cannot be changed. Existing location '#{Map.get(existing, "location")}' does not match requested location '#{requested}'.",
          rg_id
        )

      true ->
        build_and_put_rg(conn, rg_id, rg_name, payload)
    end
  end


  defp build_and_put_rg(conn, rg_id, rg_name, payload) do
    existed? = match?({:ok, _}, Store.get(:smalt_resource_groups, String.downcase(rg_id)))

    rg = %{
      "id" => rg_id,
      "name" => rg_name,
      "type" => "Microsoft.Resources/resourceGroups",
      "location" => Map.get(payload, "location", "eastus"),
      "properties" => %{"provisioningState" => "Succeeded"},
      # SHIM-COURT tags (lane 428): normalization is split by write shape —
      # rg_tags/2 owns the contract (see its comment).
      "tags" => rg_tags(payload, existed?),
      "systemData" => @system_data
    }

    Store.put(:smalt_resource_groups, String.downcase(rg_id), rg)
    :ok = ProviderState.touch_lifecycle(rg_id)

    # V7 lane: RG-level writes join the activity log (previously only generic
    # resource PUT/PATCH/DELETE were hooked — an RG-put alone never appeared).
    # Fail-safe post-store sideband, same law as the resource hooks.
    Smalt.ArmGateway.ActivityLog.record(conn, :write, rg_id, rg_name)

    send_json(conn, if(existed?, do: 200, else: 201), Jason.encode!(rg))
  end


  defp handle_rg_get(conn, sub_id, rg_name) do
    with :ok <- check_api_version(conn, @rg_type) do
      do_rg_get(conn, sub_id, rg_name)
    else
      {:respond, conn} -> conn
    end
  end


  defp do_rg_get(conn, sub_id, rg_name) do
    rg_id = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"

    case Store.get(:smalt_resource_groups, String.downcase(rg_id)) do
      {:ok, rg} ->
        if renderable_record?(rg) do
          # SHIM-COURT tags: GET normalizes via normalize_tags/1 (null-when-empty).
          send_json(conn, 200, Jason.encode!(normalize_rg(rg)))
        else
          # Deny-by-default (lens-11): a malformed record is not provably the
          # requested resource group — 404, never a 500.
          send_arm_error(
            conn,
            404,
            "ResourceGroupNotFound",
            "Resource group '#{rg_name}' could not be found.",
            rg_id
          )
        end

      :error ->
        send_arm_error(
          conn,
          404,
          "ResourceGroupNotFound",
          "Resource group '#{rg_name}' could not be found.",
          rg_id
        )
    end
  end

  # ARM RG delete is an LRO: 202 + Location polling URL + Retry-After (C1 row
  # 4, fixed). The RG and every resource inside it are removed from the Store
  # (cascade — previously children were orphaned and stayed GETable), and an
  # operation record backs the polling URL so the delete poll terminates.

  # ARM RG delete is an LRO: 202 + Location polling URL + Retry-After (C1 row
  # 4, fixed). The RG and every resource inside it are removed from the Store
  # (cascade — previously children were orphaned and stayed GETable), and an
  # operation record backs the polling URL so the delete poll terminates.
  defp handle_rg_delete(conn, sub_id, rg_name) do
    with :ok <- check_api_version(conn, @rg_type) do
      do_rg_delete(conn, sub_id, rg_name)
    else
      {:respond, conn} -> conn
    end
  end


  defp do_rg_delete(conn, sub_id, rg_name) do
    rg_id = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"
    _base = String.downcase("/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/")

    # Real ARM returns 404 ResourceGroupNotFound for a delete of a nonexistent
    # RG, not 202 + a phantom LRO (R30). Same envelope shape as do_rg_get/3.
    # SHIM-COURT affidavit-seal (lane 611): the RG record is captured here so
    # the delete cascade can seal its canonical bytes before removal.
    {exists?, rg} =
      case Store.get(:smalt_resource_groups, String.downcase(rg_id)) do
        {:ok, rg} -> {renderable_record?(rg), rg}
        :error -> {false, nil}
      end

    if exists? do
      # Management-lock gate (KD-113 leg b, wave-4 lane w4d): a CanNotDelete or
      # ReadOnly lock covering the RG refuses the delete with 409 ScopeLocked.
      if Policy.lock_blocks?(rg_id, :delete) do
        send_json(conn, 409, lock_scope_locked_body(rg_id))
      else
        do_rg_delete_confirmed(conn, sub_id, rg_name, rg_id, rg)
      end
    else
      send_rg_not_found(conn, rg_id, rg_name)
    end
  end

  # The lock-cleared delete body (wave-4 lane w4d): affidavit seal -> RG row
  # delete -> keyed cascade -> LRO 202. Split from do_rg_delete/3 so the
  # ScopeLocked refusal returns before any mutation.

  # The lock-cleared delete body (wave-4 lane w4d): affidavit seal -> RG row
  # delete -> keyed cascade -> LRO 202. Split from do_rg_delete/3 so the
  # ScopeLocked refusal returns before any mutation.
  defp do_rg_delete_confirmed(conn, sub_id, rg_name, rg_id, rg) do
    base = String.downcase("/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/")

    # SHIM-COURT affidavit-seal (lane 611): capture-then-sweep — the RG
    # record is sealed BEFORE deletion (state_delta = the deleted record's
    # canonical bytes). Best-effort sideband: never affects the 202.
    affidavit_seal(rg, %{
      subject: String.downcase(rg_id),
      lease_context: "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"
    })

    Store.delete(:smalt_resource_groups, String.downcase(rg_id))

    # Cascade by STORE KEY, never by the record's own "id" member (lens-11,
    # measured): list_prefix/2 returns records, and a malformed (non-map)
    # child — only reachable via a direct external write — raised
    # FunctionClauseError inside Access.get/3, 500-ing the whole delete and
    # leaking every remaining child. Store keys ARE the lowercased full ids,
    # so deleting by key is exact and needs no read of the record at all.
    # Capture-then-sweep: extract the storageAccount names from the swept
    # ARM keys BEFORE deleting them, so each account's data-plane rows
    # (blob containers/blobs/policies, D127) are cascade-swept too.
    swept_keys = Store.prefix_keys(:smalt_resources, base)

    for key <- swept_keys do
      Store.delete(:smalt_resources, key)
    end

    for acct <- storage_account_names(swept_keys) do
      BlobStorage.drop_account_data(acct)
    end

    # FR-6: the vault branch of the cascade. Keys in :smalt_vault_secrets are
    # bare secret names, so capture them from the swept ARM keys BEFORE the
    # rows are gone (capture-then-sweep, same shape as storage_account_names).
    vault_secret_sweep(swept_keys)

    # Cosmos pk_meta cascade (composite-identity lane): capture-then-sweep
    # from the swept ARM keys BEFORE deletion — extract db/coll names from
    # swept sqlDatabases/sqlContainers keys, then drop the pk_meta rows.
    cosmos_sweep(swept_keys)

    op = LRO.start_op(rg_id)
    authority = request_authority(conn)

    # V7 lane: the RG delete (cascade complete, LRO minted) records one
    # activity-log event — operationName Microsoft.Resources/resourceGroups/delete.
    Smalt.ArmGateway.ActivityLog.record(conn, :delete, rg_id, rg_name)

    conn
    |> put_resp_header("location", "#{authority}#{op["id"]}")
    |> put_resp_header("retry-after", "1")
    |> send_json(202, "")
  end


  # -- KD-COVERS: KD-58 — tenant tagNames CRUD over the :smalt_policy table
  # ("tagname:" prefix; discriminated-prefix law, KD-125 precedent).

  defp tagname_key(name), do: "tagname:" <> String.downcase(name)


  defp tagname_record(name, values) do
    %{
      "id" => "/tagNames/#{name}",
      "name" => name,
      "type" => "Microsoft.Resources/tags",
      "properties" => %{
        "tags" => Map.new(values, fn {v, _count} -> {v, "tagValue"} end)
      }
    }
  end


  defp handle_tenant_tags_list(conn) do
    with :ok <- check_api_version(conn, nil) do
      tags =
        :smalt_policy
        |> Store.list_prefix("tagname:")
        |> Enum.filter(fn rec -> is_map(rec) and rec["type"] == "Microsoft.Resources/tags" end)

      send_json(conn, 200, Jason.encode!(%{"value" => tags}))
    else
      {:respond, conn} -> conn
    end
  end


  defp handle_tenant_tags_get(conn, tag_name) do
    with :ok <- check_api_version(conn, nil) do
      case Store.get(:smalt_policy, tagname_key(tag_name)) do
        {:ok, rec} -> send_json(conn, 200, Jason.encode!(rec))
        :error -> send_json(conn, 404, tagname_not_found(tag_name))
      end
    else
      {:respond, conn} -> conn
    end
  end


  defp handle_tenant_tags_delete(conn, tag_name) do
    with :ok <- check_api_version(conn, nil) do
      case Store.get(:smalt_policy, tagname_key(tag_name)) do
        {:ok, rec} ->
          for {value, _} <- Map.get(rec, "values", %{}) do
            Store.delete(:smalt_policy, tagvalue_key(tag_name, value))
          end

          Store.delete(:smalt_policy, tagname_key(tag_name))
          send_json(conn, 200, "")

        :error ->
          send_json(conn, 404, tagname_not_found(tag_name))
      end
    else
      {:respond, conn} -> conn
    end
  end


  defp handle_tenant_tag_value_put(conn, tag_name, tag_value) do
    with :ok <- check_api_version(conn, nil) do
      now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      rec =
        case Store.get(:smalt_policy, tagname_key(tag_name)) do
          {:ok, rec} -> rec
          :error -> tagname_record(tag_name, %{})
        end

      values = Map.put(Map.get(rec, "values", %{}), tag_value, now)
      rec = Map.put(rec, "values", values)
      Store.put(:smalt_policy, tagname_key(tag_name), rec)

      Store.put(
        :smalt_policy,
        tagvalue_key(tag_name, tag_value),
        tagvalue_record(tag_name, tag_value)
      )

      send_json(conn, 201, Jason.encode!(tagvalue_record(tag_name, tag_value)))
    else
      {:respond, conn} -> conn
    end
  end


  defp handle_tenant_tag_value_get(conn, tag_name, tag_value) do
    with :ok <- check_api_version(conn, nil) do
      case Store.get(:smalt_policy, tagvalue_key(tag_name, tag_value)) do
        {:ok, rec} -> send_json(conn, 200, tagvalue_json(rec))
        :error -> send_json(conn, 404, tagvalue_not_found(tag_name, tag_value))
      end
    else
      {:respond, conn} -> conn
    end
  end


  defp handle_tenant_tag_value_delete(conn, tag_name, tag_value) do
    with :ok <- check_api_version(conn, nil) do
      case Store.get(:smalt_policy, tagvalue_key(tag_name, tag_value)) do
        {:ok, _rec} ->
          Store.delete(:smalt_policy, tagvalue_key(tag_name, tag_value))

          case Store.get(:smalt_policy, tagname_key(tag_name)) do
            {:ok, rec} ->
              values = Map.delete(Map.get(rec, "values", %{}), tag_value)

              if values == %{} do
                # last value gone: delete the tagName row itself (real ARM
                # deletes a tag with no remaining values)
                Store.delete(:smalt_policy, tagname_key(tag_name))
              else
                rec = Map.put(rec, "values", values)
                Store.put(:smalt_policy, tagname_key(tag_name), rec)
              end

              send_json(conn, 200, "")

            :error ->
              Store.delete(:smalt_policy, tagname_key(tag_name))
              send_json(conn, 200, "")
          end

        :error ->
          send_json(conn, 404, tagvalue_not_found(tag_name, tag_value))
      end
    else
      {:respond, conn} -> conn
    end
  end


  defp tagvalue_key(name, value), do: tagname_key(name) <> "/tagValues/" <> String.downcase(value)


  defp tagvalue_record(name, value) do
    %{
      "id" => "/tagNames/#{name}/tagValues/#{value}",
      "name" => value,
      "type" => "Microsoft.Resources/tagValues",
      "properties" => %{"tagName" => name, "value" => value},
      "count" => %{"type" => "Modified", "value" => 0}
    }
  end


  defp tagvalue_json(rec), do: Jason.encode!(rec)


  defp tagname_not_found(tag_name) do
    Jason.encode!(%{
      "error" => %{
        "code" => "TagNotFound",
        "message" => "Tag '#{tag_name}' was not found."
      }
    })
  end


  defp tagvalue_not_found(name, value) do
    Jason.encode!(%{
      "error" => %{
        "code" => "TagValueNotFound",
        "message" => "Tag value '#{value}' of tag '#{name}' was not found."
      }
    })
  end

  # -- KD-COVERS: KD-59 — exportTemplate delegates to the wave-6 export face
  # (Smalt.Arm.ExportTemplate.export_rg/3), previously unrouted. Synchronous
  # 200 (terminal for ARM LRO pollers — documented boundary); an RG with no
  # exportable resources is a typed 404 (ResourceGroupResourceNotFound).

  # -- KD-COVERS: KD-59 — exportTemplate delegates to the wave-6 export face
  # (Smalt.Arm.ExportTemplate.export_rg/3), previously unrouted. Synchronous
  # 200 (terminal for ARM LRO pollers — documented boundary); an RG with no
  # exportable resources is a typed 404 (ResourceGroupResourceNotFound).
  defp handle_export_template(conn, sub_id, rg_name) do
    with :ok <- check_api_version(conn, nil) do
      case Smalt.Arm.ExportTemplate.export_rg(sub_id, rg_name) do
        {:ok, template} -> send_json(conn, 200, Jason.encode!(template))
        {:error, status, body} -> send_json(conn, status, Jason.encode!(body))
      end
    else
      {:respond, conn} -> conn
    end
  end

  # -- KD-COVERS: KD-59 — moveResources / validateMoveResources: TYPED
  # UNSUPPORTED (row close condition: routes OR typed refusal; falsifier:
  # "never 404"). Real Azure refuses moves of unsupported types with 400
  # MoveUnsupportedResourceType; the emulator names the boundary directly.

  # -- KD-COVERS: KD-59 — moveResources / validateMoveResources: TYPED
  # UNSUPPORTED (row close condition: routes OR typed refusal; falsifier:
  # "never 404"). Real Azure refuses moves of unsupported types with 400
  # MoveUnsupportedResourceType; the emulator names the boundary directly.
  defp handle_move_resources(conn, sub_id, rg_name) do
    with :ok <- check_api_version(conn, nil) do
      send_json(
        conn,
        400,
        Jason.encode!(%{
          "error" => %{
            "code" => "MoveUnsupportedResourceType",
            "message" =>
              "Resource move is not supported by this emulator for resources in " <>
                "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}.",
            "target" => "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}",
            "innererror" => %{}
          }
        })
      )
    else
      {:respond, conn} -> conn
    end
  end

  # -- Management locks (KD-113 leg b): wired to Smalt.Policy (wave-4 lane w4d).
  # PUT/GET/DELETE/LIST at RG and subscription scope, api-version 2016-09-01
  # (monotonic-admission: <= the admitted 2020-05-01 latest). Inline envelopes,
  # NOT send_arm_error/5 — its (status, code) set is pinned by the
  # arm_error_corpus meta-test.

  # Tags at SUBSCRIPTION scope: the tags API envelope rides the subscription
  # record's "tags" member (null-when-empty render law).
  defp handle_subscription_tags_get(conn, sub_id) do
    with :ok <- check_api_version(conn, nil) do
      case TagsLocks.subscription_record(sub_id) do
        {:ok, sub} ->
          send_json(
            conn,
            200,
            Jason.encode!(tags_scope_envelope("/subscriptions/#{sub_id}", Map.get(sub, "tags")))
          )

        :error ->
          send_arm_error(
            conn,
            404,
            "SubscriptionNotFound",
            "The subscription '#{sub_id}' was not found.",
            "/subscriptions/#{sub_id}"
          )
      end
    else
      {:respond, conn} -> conn
    end
  end


  defp handle_subscription_tags_put(conn, sub_id, mode) do
    with :ok <- check_api_version(conn, nil) do
      case TagsLocks.put_subscription_tags(sub_id, conn.body_params, mode) do
        {:ok, sub} ->
          send_json(
            conn,
            200,
            Jason.encode!(tags_scope_envelope("/subscriptions/#{sub_id}", Map.get(sub, "tags")))
          )

        :error ->
          send_arm_error(
            conn,
            404,
            "SubscriptionNotFound",
            "The subscription '#{sub_id}' was not found.",
            "/subscriptions/#{sub_id}"
          )
      end
    else
      {:respond, conn} -> conn
    end
  end


  get "/tenant" do
    send_tenant_list(conn)
  end

  get "/tenants" do
    send_tenant_list(conn)
  end

  # -- Subscriptions -----------------------------------------------------------
  # api-version PRESENCE required on both subscription routes (real ARM requires
  # api-version on GET /subscriptions and GET /subscriptions/:sub; lens-2
  # typed receipt, coordinator-authorized Raise). Presence-only: the
  # subscriptions list/read is not an admitted Registry individual, so no
  # latest-version validation (mirrors the azapi action + inventory gates).
  # LRO polling (`/operations/:op_id`) stays versionless by convention — pinned
  # EXEMPT, do not gate it.
  get "/subscriptions" do
    with :ok <- check_api_version(conn, nil) do
      send_json(conn, 200, Jason.encode!(%{"value" => Store.list(:smalt_subscriptions)}))
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id" do
    with :ok <- check_api_version(conn, nil) do
      case Store.get(:smalt_subscriptions, sub_id) do
        {:ok, sub} ->
          send_json(conn, 200, Jason.encode!(sub))

        :error ->
          send_arm_error(
            conn,
            404,
            "SubscriptionNotFound",
            "The subscription '#{sub_id}' was not found.",
            "/subscriptions/#{sub_id}"
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  # -- LRO polling -------------------------------------------------------------
  get "/subscriptions/:sub_id/operations/:op_id" do
    case LRO.get_op(op_id, sub_id) do
      {:ok, op} ->
        # Only "InProgress" renders 202 — every other status is treated as
        # terminal (default-terminal, no wedge). Lens-9 cycle-1 fixed the
        # Failed face (a Failed terminal rendered as 202); cycle-4 widened to
        # the default so any other terminal vocabulary (Cancelled, …) can
        # never poll 202 forever.
        status = if op["status"] == "InProgress", do: 202, else: 200
        send_json(conn, status, Jason.encode!(lro_wire_body(op)))

      :error ->
        send_arm_error(
          conn,
          404,
          "OperationNotFound",
          "Operation '#{op_id}' was not found.",
          conn.request_path
        )
    end
  end

  # -- Resource group LIST collection (must precede :rg_name routes) -----------
  get "/subscriptions/:sub_id/resourcegroups" do
    handle_rg_list(conn, sub_id)
  end

  get "/subscriptions/:sub_id/resourceGroups" do
    handle_rg_list(conn, sub_id)
  end

  # -- Resource groups (case-normalized) ----------------------------------------
  put "/subscriptions/:sub_id/resourcegroups/:rg_name" do
    handle_rg_put(conn, sub_id, rg_name)
  end

  put "/subscriptions/:sub_id/resourceGroups/:rg_name" do
    handle_rg_put(conn, sub_id, rg_name)
  end

  get "/subscriptions/:sub_id/resourcegroups/:rg_name" do
    handle_rg_get(conn, sub_id, rg_name)
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name" do
    handle_rg_get(conn, sub_id, rg_name)
  end

  patch "/subscriptions/:sub_id/resourcegroups/:rg_name" do
    handle_rg_patch(conn, sub_id, rg_name)
  end

  patch "/subscriptions/:sub_id/resourceGroups/:rg_name" do
    handle_rg_patch(conn, sub_id, rg_name)
  end

  get "/subscriptions/:sub_id/resourcegroups/:rg_name/resources" do
    handle_rg_resources_list(conn, sub_id, rg_name)
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/resources" do
    handle_rg_resources_list(conn, sub_id, rg_name)
  end

  get "/subscriptions/:sub_id/locations" do
    handle_locations_list(conn, sub_id)
  end

  # AZURE-FIDELITY lane 5: Activity Log — the documented eventtypes/management
  # surface. Events are assembled from the generic-resource CRUD hook
  # (Smalt.ArmGateway.ActivityLog.record/4, fail-safe post-store sideband in
  # the PUT/PATCH/DELETE handlers). $filter subset: eventTimestamp ge/le,
  # resourceId eq, operationName eq (and-combined).
  get "/subscriptions/:sub_id/providers/microsoft.insights/eventtypes/management/values" do
    case Smalt.ArmGateway.ActivityLog.handle_query(conn, sub_id) do
      {:ok, status, body} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, body)
    end
  end

  # AZURE-FIDELITY lane 7: create-blade validation surface. ResourceSkus
  # list (documented shape incl. restrictions) + regional quota usage for
  # Compute and Network (currentValue derived from real stored resources).
  get "/subscriptions/:sub_id/providers/Microsoft.Compute/skus" do
    with :ok <- check_api_version(conn, nil) do
      send_json(
        conn,
        200,
        Jason.encode!(SkuQuota.list_skus(sub_id, conn.query_params["$filter"]))
      )
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/providers/Microsoft.Compute/locations/:location/usages" do
    with :ok <- check_api_version(conn, nil) do
      send_json(conn, 200, Jason.encode!(SkuQuota.usage("Microsoft.Compute", location, sub_id)))
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/providers/Microsoft.Network/locations/:location/usages" do
    with :ok <- check_api_version(conn, nil) do
      send_json(conn, 200, Jason.encode!(SkuQuota.usage("Microsoft.Network", location, sub_id)))
    else
      {:respond, conn} -> conn
    end
  end

  delete "/subscriptions/:sub_id/resourcegroups/:rg_name" do
    handle_rg_delete(conn, sub_id, rg_name)
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name" do
    handle_rg_delete(conn, sub_id, rg_name)
  end

  # -- KD-113 tags leg: tags AT SCOPE (Microsoft.Resources/tags) ---------------
  # ARM shape: the tags API at any scope is /providers/Microsoft.Resources/tags
  # (optionally /default). PUT replaces, PATCH merges; GET renders the tags
  # API envelope. Tags at RG scope live on the RG record's "tags" member, so
  # the RG delete cascade clears them for free and the RG GET/normalize path
  # (normalize_tags/1 null-when-empty law) renders them identically.
  get "/tagNames" do
    handle_tenant_tags_list(conn)
  end

  get "/tagNames/:tag_name" do
    handle_tenant_tags_get(conn, tag_name)
  end

  delete "/tagNames/:tag_name" do
    handle_tenant_tags_delete(conn, tag_name)
  end

  put "/tagNames/:tag_name/tagValues/:tag_value" do
    handle_tenant_tag_value_put(conn, tag_name, tag_value)
  end

  get "/tagNames/:tag_name/tagValues/:tag_value" do
    handle_tenant_tag_value_get(conn, tag_name, tag_value)
  end

  delete "/tagNames/:tag_name/tagValues/:tag_value" do
    handle_tenant_tag_value_delete(conn, tag_name, tag_value)
  end

  # -- KD-COVERS: KD-59 — resource-group exportTemplate + moveResources.
  # exportTemplate delegates to Smalt.Arm.ExportTemplate.export_rg/3 (the
  # wave-6 export face, previously unrouted); an RG with no exportable
  # resources is a typed 404 (ResourceGroupResourceNotFound). Responds 200
  # synchronous (terminal for ARM LRO pollers) — documented boundary.
  post "/subscriptions/:sub_id/resourcegroups/:rg_name/exportTemplate" do
    handle_export_template(conn, sub_id, rg_name)
  end

  post "/subscriptions/:sub_id/resourceGroups/:rg_name/exportTemplate" do
    handle_export_template(conn, sub_id, rg_name)
  end

  # moveResources / validateMoveResources: TYPED UNSUPPORTED (row KD-59 close
  # condition admits routes OR typed refusal; falsifier: "never 404").
  post "/subscriptions/:sub_id/resourcegroups/:rg_name/moveResources" do
    handle_move_resources(conn, sub_id, rg_name)
  end

  post "/subscriptions/:sub_id/resourceGroups/:rg_name/moveResources" do
    handle_move_resources(conn, sub_id, rg_name)
  end

  post "/subscriptions/:sub_id/resourcegroups/:rg_name/validateMoveResources" do
    handle_move_resources(conn, sub_id, rg_name)
  end

  post "/subscriptions/:sub_id/resourceGroups/:rg_name/validateMoveResources" do
    handle_move_resources(conn, sub_id, rg_name)
  end

  # -- Management locks (KD-113 leg b): wired to Smalt.Policy (wave-4 lane w4d).
  # api-version 2016-09-01 is admitted monotonic (<= latest 2020-05-01).
  # Subscription scope first (exact path prefix, no :ns shadow risk — the
  # single-namespace route matches one segment only).
  get "/subscriptions/:sub_id/providers/Microsoft.Resources/tags" do
    handle_subscription_tags_get(conn, sub_id)
  end

  get "/subscriptions/:sub_id/providers/Microsoft.Resources/tags/default" do
    handle_subscription_tags_get(conn, sub_id)
  end

  put "/subscriptions/:sub_id/providers/Microsoft.Resources/tags" do
    handle_subscription_tags_put(conn, sub_id, :replace)
  end

  put "/subscriptions/:sub_id/providers/Microsoft.Resources/tags/default" do
    handle_subscription_tags_put(conn, sub_id, :replace)
  end

  patch "/subscriptions/:sub_id/providers/Microsoft.Resources/tags" do
    handle_subscription_tags_put(conn, sub_id, :merge)
  end

  patch "/subscriptions/:sub_id/providers/Microsoft.Resources/tags/default" do
    handle_subscription_tags_put(conn, sub_id, :merge)
  end

  # -- Subscription-level provider listing (ProviderMatrix projection) ----------
  # api-version PRESENCE required (Microsoft.Resources/providers is not an
  # admitted Registry individual — no latest-version validation, mirroring the
  # azapi action gate). Wave-2: the listing is the Registry-projected
  # ProviderMatrix.provider_listing/1 — the store-scan inventory (and its
  # top-level subscriptionId field) is gone; azurerm reads "value" rows.

  # Extract storageAccount names from swept ARM store keys (capture-then-sweep
  # for the D127 data-plane cascade). Matches both store-key conventions:
  # prefixed (.../providers/microsoft.storage/storageaccounts/<acct>/...) and
  # the child-route form (.../storageaccounts/<acct>/...).
  defp storage_account_names(keys) do
    keys
    |> Enum.flat_map(fn key ->
      case Regex.run(~r/storageaccounts\/([^\/]+)/i, key, capture: :all_but_first) do
        [acct] -> [acct]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  # Microsoft.KeyVault vaults DELETE (FR-6): a deleted vault must not leave
  # GETable ARM children (secrets/keys under both store-key conventions) or
  # orphaned data-plane secret rows on the 8443 /secrets surface. Capture-then-
  # sweep: cascade_sweep/2 returns the swept store keys, from which the bare
  # secret names are extracted for the VaultData sweep (keys in
  # :smalt_vault_secrets are bare names, no vault scoping).

  # Pass-through tail (T06): a conn no route above claimed returns UNCHANGED
  # (not halted) so the next plug in the front pipeline complies unchanged.
  match _ do
    conn
  end
end
