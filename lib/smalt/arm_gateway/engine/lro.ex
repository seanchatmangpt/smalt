
defmodule Smalt.ArmGateway.Engine.Lro do
  @moduledoc """
  LRO wire-shaping engine (T06, v26.10.29): async response minting and
  terminal poll-body enrichment, extracted verbatim from the router.
  """

  import Plug.Conn
  require Logger
  import Smalt.ArmGateway.Plug.Common
  alias Smalt.Store



  # LRO PUT async response: polling URLs resolve from the client's seat — the
  # same request-authority derivation the OIDC envelopes use (never a hardcoded
  # management.smalt.local).
  def async_put_response(conn, status, op) do
    authority = request_authority(conn)

    conn
    |> put_resp_header("azure-asyncoperation", "#{authority}#{op["id"]}")
    |> put_resp_header("location", "#{authority}#{op["id"]}")
    |> put_resp_header("retry-after", "1")
    |> send_json(status, Jason.encode!(op))
  end

  # LRO-async types (azurerm polls these via Azure-AsyncOperation)
  # KD-COVERS: KD-111 — widening to the full Azure async set. PUT create ->
  # 202 async for every type below; PUT update stays SYNC 200 for the
  # widened types (AZB-25b law: only create is async at ARM), while the
  # original witness set keeps its 200-async update (lro_async_update_type?/1).
  # DELETE for these types is already sync 200 (handle_child_delete /
  # dedicated delete routes) — no change needed.
  # The LRO Sweeper (Smalt.ArmGateway.LRO.Sweeper.flip_pass/0) is
  # TYPE-BLIND: it drives every InProgress record in :smalt_operations by
  # startedAtMs + delayMs, so new types need no sweeper change.

  # LRO-async types (azurerm polls these via Azure-AsyncOperation)
  # KD-COVERS: KD-111 — widening to the full Azure async set. PUT create ->
  # 202 async for every type below; PUT update stays SYNC 200 for the
  # widened types (AZB-25b law: only create is async at ARM), while the
  # original witness set keeps its 200-async update (lro_async_update_type?/1).
  # DELETE for these types is already sync 200 (handle_child_delete /
  # dedicated delete routes) — no change needed.
  # The LRO Sweeper (Smalt.ArmGateway.LRO.Sweeper.flip_pass/0) is
  # TYPE-BLIND: it drives every InProgress record in :smalt_operations by
  # startedAtMs + delayMs, so new types need no sweeper change.
  def lro_type?(type) do
    type in [
      "Microsoft.Storage/storageAccounts",
      "Microsoft.Compute/virtualMachines",
      "Microsoft.ServiceBus/namespaces",
      "Microsoft.EventHub/namespaces",
      "Microsoft.KeyVault/vaults",
      "Microsoft.DocumentDB/databaseAccounts"
    ]
  end

  # The subset whose PUT UPDATE is also async (original azurerm witness set
  # only — the KD-111 widening deliberately keeps update sync per ARM).

  # The subset whose PUT UPDATE is also async (original azurerm witness set
  # only — the KD-111 widening deliberately keeps update sync per ARM).
  def lro_async_update_type?(type) do
    type in ["Microsoft.Storage/storageAccounts", "Microsoft.Compute/virtualMachines"]
  end

  # KD-T5-F3: real ARM async-operation terminal bodies carry only operation
  # fields, but azurerm 4.54's storage LRO poller synthesizes the Terraform
  # resource identity from the FINAL poll body — with the bare operation
  # record it produced "Missing Resource Identity After Create" (T5
  # cleanroom wire evidence, tf-apply.log). The terminal wire body is
  # enriched with the target resource's id/name/type plus its stored
  # properties/location; the STORED operation record is untouched (the
  # subscription-scope ownership check still runs on the operation id), so
  # this is a render-time transform only.
  # KD-COVERS: KD-81
  # resource identity from the FINAL poll body — with the bare operation
  # record it produced "Missing Resource Identity After Create" (T5
  # cleanroom wire evidence, tf-apply.log). The terminal wire body is
  # enriched with the target resource's id/name/type plus its stored
  # properties/location; the STORED operation record is untouched (the
  # subscription-scope ownership check still runs on the operation id), so
  # this is a render-time transform only.
  # KD-COVERS: KD-81
  def lro_wire_body(%{"status" => "InProgress"} = op), do: op

  def lro_wire_body(%{"resourceId" => res_id} = op) when is_binary(res_id) do
    enrichment =
      case String.split(res_id, "/") do
        ["", "subscriptions", _sub, "resourceGroups", _rg, "providers", ns, leaf, name] ->
          %{"id" => res_id, "name" => name, "type" => "#{ns}/#{leaf}"}

        _ ->
          %{}
      end

    stored =
      case Store.get(:smalt_resources, String.downcase(res_id)) do
        {:ok, %{"properties" => props, "location" => loc}}
        when is_map(props) and is_binary(loc) ->
          %{"properties" => props, "location" => loc}

        _ ->
          %{}
      end

    # merge order: op base → stored record (resource-like properties/
    # location/tags) → identity enrichment (resource id/name/type wins).
    op
    |> Map.merge(stored)
    |> Map.merge(enrichment)
  end

  def lro_wire_body(op), do: op

end
