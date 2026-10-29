defmodule Smalt.ArmGateway.TagsLocks do
  @moduledoc """
  Tags-at-scope + management-lock state law (AZURE-FIDELITY lane 4).

  Owns the store-level logic for the Microsoft.Resources/tags and
  Microsoft.Authorization/locks surfaces at scopes the earlier KD-113 leg
  did not cover:

  - tags at SUBSCRIPTION scope (on the :smalt_subscriptions record's
    "tags" member) and RESOURCE scope (on the :smalt_resources record's
    "tags" member) — same null-when-empty render law as the router's
    normalize_tags/1 (azurerm documented: empty tags render null;
    echoing `{}` drifts refresh-only plans).
  - locks at RESOURCE scope ride Smalt.Policy's existing lock table and
    `lock_blocks?/2` law untouched (a lock whose scope is the resource id
    covers it; an RG/subscription-scope lock covers it by prefix).
  - the LOCK LAW gate: `write_gate/1` / `delete_gate/1` are consulted by
    the router's resource PUT/PATCH/DELETE paths; a covering ReadOnly
    lock refuses :write and a covering CanNotDelete or ReadOnly lock
    refuses :delete with the documented 409 ScopeLocked envelope (the
    router renders it via lock_scope_locked_body/1 — same shape as the
    RG delete gate, wave-4 lane w4d).
  """

  alias Smalt.ArmGateway.ProviderState
  alias Smalt.Policy
  alias Smalt.Store

  # -- shared tags law ---------------------------------------------------------

  @doc """
  Tags-body ingress law (KD-COVERS: KD-58): both the 2022-09-01 tags API
  shape `{"properties":{"tags":{...}}}` and the top-level `{"tags":{...}}`
  shape are accepted; "properties" wins when both present.
  """
  def tags_in(%{"properties" => %{"tags" => %{} = tags}}), do: tags
  def tags_in(%{"tags" => %{} = tags}), do: tags
  def tags_in(_), do: %{}

  @doc "PATCH merge law: key-wise union, incoming wins."
  def merge_tags(old, incoming, :merge) when is_map(old), do: Map.merge(old, incoming)
  def merge_tags(_old, incoming, :merge), do: incoming
  def merge_tags(_old, incoming, :replace), do: incoming

  @doc "Null-when-empty render law (router normalize_tags/1 parity)."
  def normalize_tags(nil), do: nil

  def normalize_tags(%{} = tags) do
    if map_size(tags) == 0, do: nil, else: tags
  end

  def normalize_tags(_), do: nil

  # -- subscription-scope tags -------------------------------------------------

  @doc "GET law: {:ok, record} when the subscription exists, :error otherwise."
  def subscription_record(sub_id) do
    case Store.get(:smalt_subscriptions, sub_id) do
      {:ok, sub} -> {:ok, sub}
      :error -> :error
    end
  end

  @doc """
  PUT/PATCH law at subscription scope. `mode` is :replace (PUT) or :merge
  (PATCH). Returns {:ok, record} | :error (unknown subscription).
  """
  def put_subscription_tags(sub_id, body, mode) do
    case subscription_record(sub_id) do
      {:ok, sub} ->
        incoming = tags_in(body)
        merged = merge_tags(Map.get(sub, "tags") || %{}, incoming, mode)
        sub = Map.put(sub, "tags", normalize_tags(merged))
        Store.put(:smalt_subscriptions, sub_id, sub)
        {:ok, sub}

      :error ->
        :error
    end
  end

  # -- resource-scope tags + the lock law gate ---------------------------------

  @doc "GET law: {:ok, record} when the resource exists, :error otherwise."
  def resource_record(res_id) do
    case Store.get(:smalt_resources, res_id_low(res_id)) do
      {:ok, rec} -> {:ok, rec}
      :error -> :error
    end
  end

  @doc """
  PUT/PATCH law at resource scope: a covering ReadOnly lock refuses the
  write (:locked) before any mutation; unknown resource -> :error.
  Returns {:ok, record} | :locked | :error.
  """
  def put_resource_tags(res_id, body, mode) do
    case write_gate(res_id) do
      :ok ->
        case Store.get(:smalt_resources, res_id_low(res_id)) do
          {:ok, rec} ->
            incoming = tags_in(body)
            merged = merge_tags(Map.get(rec, "tags") || %{}, incoming, mode)
            rec = Map.put(rec, "tags", normalize_tags(merged))
            Store.put(:smalt_resources, res_id_low(res_id), rec)
            ProviderState.touch_lifecycle(res_id)
            {:ok, rec}

          :error ->
            :error
        end

      :locked ->
        :locked
    end
  end

  # -- the lock law gate -------------------------------------------------------

  @doc """
  :ok when no covering lock refuses the write verb (:write); :locked when
  a covering ReadOnly lock blocks the write. Consulted by the router's
  resource PUT/PATCH paths and resource-scope tags writes.
  """
  def write_gate(res_id) do
    if Policy.lock_blocks?(res_id, :write), do: :locked, else: :ok
  end

  @doc """
  :ok when no covering lock refuses the delete verb; :locked when a
  covering CanNotDelete or ReadOnly lock blocks. Consulted by the router's
  generic resource DELETE and the RG delete cascade (which already gates).
  """
  def delete_gate(res_id) do
    if Policy.lock_blocks?(res_id, :delete), do: :locked, else: :ok
  end

  # -- locks at resource scope (thin delegation, Policy owns the law) ----------

  @doc "PUT a management lock whose scope is the resource id."
  def put_resource_lock(res_id, name, body), do: Policy.put_lock(res_id, name, body)

  @doc "GET a management lock whose scope is the resource id."
  def get_resource_lock(res_id, name), do: Policy.get_lock(res_id, name)

  @doc "DELETE a management lock whose scope is the resource id."
  def delete_resource_lock(res_id, name), do: Policy.delete_lock(res_id, name)

  @doc "LIST management locks at resource scope."
  def list_resource_locks(res_id), do: Policy.list_locks(res_id)

  # -- internal ----------------------------------------------------------------

  defp res_id_low(res_id), do: res_id |> String.downcase()
end
