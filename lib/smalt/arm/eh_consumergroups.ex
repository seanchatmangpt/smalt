defmodule Smalt.Arm.EhConsumerGroups do
  @moduledoc """
  Event Hubs consumer groups — ARM face semantics (wave-6 lane w6j).

  Owns the verb bodies for the
  `/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.EventHub/
  namespaces/{ns}/eventhubs/{hub}/consumergroups[/{name}]` surface; the
  router (`Smalt.ArmGateway.Router.handle_cg_engine/7`) keeps the admission
  gates (api-version / shape / properties-member) and delegates here.

  Semantics (directive-pinned, w6j):

    * PUT `$default`            → 400 `ConsumerGroupNotCreatable`
    * DELETE `$default`         → 400 `ConsumerGroupNotDeletable`
    * PUT new group             → 201 envelope (engine create + Store mirror)
    * PUT existing, same
      userMetadata              → 200 (idempotent re-PUT)
    * PUT existing, changed
      userMetadata              → 409 `ConsumerGroupConflict`
      (consumer groups do not support in-place update — real-service parity)
    * GET unknown               → 404 `ConsumerGroupNotFound`
    * DELETE unknown            → 404 `ConsumerGroupNotFound`
    * LIST                      → Store-driven, `$default` synthesized exactly
      once (same synthesis rule as the pre-existing shim-court cg-default
      enumeration)

  User metadata echoes verbatim on every envelope (`properties.userMetadata`).
  The engine (`Smalt.Messaging.EventHubs`) stays source of truth for
  existence/created-ts/deletability on the messaging plane; the ARM Store
  mirrors the rendered envelope so store-driven LIST stays coherent with
  engine state.
  """

  alias Smalt.Messaging.EventHubs
  alias Smalt.Store

  @default_group "$default"
  @system_data %{
    "createdBy" => "smalt-dev-substrate",
    "createdByType" => "Application",
    "createdAt" => "2026-01-01T00:00:00.0000000+00:00"
  }

  @type ctx :: %{
          required(:child_type) => String.t(),
          required(:base) => String.t(),
          required(:hub) => String.t(),
          required(:name) => String.t(),
          required(:send_json) => (Plug.Conn.t(), integer(), iodata() -> Plug.Conn.t()),
          required(:send_arm_error) =>
            (Plug.Conn.t(), integer(), String.t(), String.t() -> Plug.Conn.t()),
          required(:send_list) => (Plug.Conn.t(), [map()] -> Plug.Conn.t())
        }

  @doc "PUT verb body. Router has already run validate_child_put/2 gates."
  @spec put(Plug.Conn.t(), ctx()) :: Plug.Conn.t()
  def put(conn, ctx) do
    if ctx.name == @default_group do
      ctx.send_arm_error.(
        conn,
        400,
        "ConsumerGroupNotCreatable",
        "The default consumer group cannot be created or modified."
      )
    else
      meta = user_metadata(conn.body_params)
      key = String.downcase("#{ctx.base}/#{ctx.name}")

      prior_meta =
        case Store.get(:smalt_resources, key) do
          {:ok, stored} -> stored |> props() |> Map.get("userMetadata", "")
          :error -> nil
        end

      case prior_meta do
        nil ->
          with {:ok, rec} <- EventHubs.create_consumer_group(ctx.hub, ctx.name, user_metadata: meta) do
            record = envelope(ctx, rec)
            Store.put(:smalt_resources, key, record)
            ctx.send_json.(conn, 201, Jason.encode!(record))
          else
            {:error, face} -> face_error(conn, ctx, face)
          end

        ^meta ->
          # Idempotent re-PUT: same userMetadata, engine preserves created ts.
          with {:ok, rec} <- EventHubs.create_consumer_group(ctx.hub, ctx.name, user_metadata: meta) do
            record = envelope(ctx, rec)
            Store.put(:smalt_resources, key, record)
            ctx.send_json.(conn, 200, Jason.encode!(record))
          else
            {:error, face} -> face_error(conn, ctx, face)
          end

        _changed ->
          ctx.send_arm_error.(
            conn,
            409,
            "ConsumerGroupConflict",
            "Consumer group '#{ctx.name}' already exists with different properties; " <>
              "consumer groups do not support in-place update."
          )
      end
    end
  end

  @doc "GET verb body. Router has already run check_api_version/2."
  @spec get(Plug.Conn.t(), ctx()) :: Plug.Conn.t()
  def get(conn, ctx) do
    case EventHubs.get_consumer_group(ctx.hub, ctx.name) do
      {:ok, rec} ->
        record =
          case Store.get(:smalt_resources, String.downcase("#{ctx.base}/#{ctx.name}")) do
            {:ok, stored} -> stored
            :error -> envelope(ctx, rec)
          end

        ctx.send_json.(conn, 200, Jason.encode!(record))

      {:error, face} ->
        face_error(conn, ctx, face)
    end
  end

  @doc "DELETE verb body. Router has already run check_api_version/2."
  @spec delete(Plug.Conn.t(), ctx()) :: Plug.Conn.t()
  def delete(conn, ctx) do
    if ctx.name == @default_group do
      ctx.send_arm_error.(
        conn,
        400,
        "ConsumerGroupNotDeletable",
        "The default consumer group cannot be deleted."
      )
    else
      case EventHubs.delete_consumer_group(ctx.hub, ctx.name) do
        :ok ->
          Store.delete(:smalt_resources, String.downcase("#{ctx.base}/#{ctx.name}"))
          ctx.send_json.(conn, 200, "")

        {:error, face} ->
          face_error(conn, ctx, face)
      end
    end
  end

  @doc """
  LIST verb body: store-driven enumeration with the `$default` synthesis
  (byte-identical semantics to the pre-existing handle_cg_list/5 — a
  user-created literal `$default` renders verbatim exactly once).
  """
  @spec list(Plug.Conn.t(), ctx()) :: Plug.Conn.t()
  def list(conn, ctx) do
    prefix = String.downcase("#{ctx.base}/")

    items = Store.list_prefix(:smalt_resources, prefix)

    default? =
      Enum.any?(items, fn record ->
        is_map(record) and Map.get(record, "name") == @default_group
      end)

    items =
      if default? do
        items
      else
        [
          envelope(
            ctx,
            %{"user_metadata" => "", "created" => nil},
            @default_group
          )
          | items
        ]
      end

    ctx.send_list.(conn, items)
  end

  # -- internals ---------------------------------------------------------------

  defp user_metadata(payload) when is_map(payload) do
    case payload |> Map.get("properties", %{}) |> Map.get("userMetadata") do
      meta when is_binary(meta) -> meta
      _ -> ""
    end
  end

  defp user_metadata(_payload), do: ""

  defp props(stored) when is_map(stored), do: Map.get(stored, "properties", %{})
  defp props(_), do: %{}

  # Envelope identical in shape to the router's build_resource_record output
  # for this child type (id/name/type/location/properties/tags/systemData),
  # so store-driven LIST/GET renders are coherent across lanes.
  defp envelope(ctx, rec, name \\ nil) do
    name = name || ctx.name

    %{
      "id" => "#{ctx.base}/#{name}",
      "name" => name,
      "type" => ctx.child_type,
      "location" => "eastus",
      "properties" => %{
        "userMetadata" => rec["user_metadata"],
        "createdAt" => iso8601(rec["created"]),
        "provisioningState" => "Succeeded"
      },
      "tags" => %{},
      "systemData" => @system_data
    }
  end

  defp iso8601(ms) when is_integer(ms) do
    DateTime.from_unix!(ms, :millisecond) |> DateTime.to_iso8601()
  end

  defp iso8601(_), do: nil

  defp face_error(conn, ctx, %{status: status, code: code, description: description}) do
    ctx.send_arm_error.(conn, status, code, description)
  end
end
