defmodule Smalt.Arm.SbManagement do
  @moduledoc """
  Azure Service Bus ARM management face (wave-6 lane w6aj).

  Namespace-scoped entity management in the ARM shape, delegating to the
  REAL underlying stores as the single source of truth (no shadow copy):

    - `:smalt_resources` (ARM records, key = downcased ARM id) — the same
      table the ARM gateway's SB child handlers write; properties here are
      what `QueueStore.queue_settings/1` reads for lockDuration /
      maxDeliveryCount, so an entity created here is honored by the AMQP
      delivery engine.
    - `:smalt_sb_queues` (AMQP entities) — provisioned at create and torn
      down at delete, mirroring the arm_gateway's `sb_materialize_amqp`
      contract (topic -> entity "name"; delete tears down the topic's
      "name/Subscriptions/*" entities too).

  Faces: list / create (POST) / get / delete for queues and topics.
  Typed errors: `{:error, {:arm_error, status, code, message}}` so the
  post-split router mount renders a real ARM error envelope. ROUTER HOLD
  respected: no edits to egress_router.ex / arm_gateway/router.ex; the
  staged mount patch lives at tmp/w6aj_router_patch.md.
  """

  alias Smalt.Amqp.QueueStore
  alias Smalt.Amqp.RuleStore

  @queue_type "Microsoft.ServiceBus/namespaces/queues"
  @topic_type "Microsoft.ServiceBus/namespaces/topics"

  @queue_defaults %{
    "properties" => %{
      "lockDuration" => "PT1M",
      "maxDeliveryCount" => 10,
      "defaultMessageTimeToLive" => "P14D",
      "status" => "Active"
    }
  }

  @topic_defaults %{
    "properties" => %{
      "defaultMessageTimeToLive" => "P14D",
      "status" => "Active",
      "supportOrdering" => true,
      "enableBatchedOperations" => true
    }
  }

  @doc """
  Lists queues or topics under namespace `ns`. Enumerates the real
  `:smalt_resources` table — no shadow copy. Sorted by name.
  """
  @spec list_entities(:queues | :topics, String.t()) :: [map()]
  def list_entities(kind, ns) when kind in [:queues, :topics] and is_binary(ns) do
    suffix = "/namespaces/#{String.downcase(ns)}/#{kind}/"

    all_resources()
    |> Enum.filter(fn {key, record} ->
      is_binary(key) and String.contains?(key, suffix) and
        is_map(record) and record["type"] == full_type(kind)
    end)
    |> Enum.map(fn {_key, record} -> to_wire(record) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn %{"name" => n} -> n end)
  end

  @doc """
  Creates a queue or topic (POST face): defaults merged UNDER the user
  payload per key (user values win), the ARM record persisted to
  `:smalt_resources` (downcased ARM id key), and the AMQP entity
  materialized via `QueueStore.ensure_queue/1`. Duplicate ARM record
  (already present) -> `{:error, {:arm_error, 409, "Conflict", ...}}`.
  """
  @spec create_entity(:queues | :topics, String.t(), String.t(), map()) ::
          {:ok, map(), created? :: boolean()}
          | {:error, {:arm_error, pos_integer(), String.t(), String.t()}}
  def create_entity(kind, ns, name, body) when kind in [:queues, :topics] and is_binary(name) do
    with :ok <- validate_name(name),
         :ok <- validate_body(body) do
      key = arm_key(kind, ns, name)

      if match?({:ok, _}, Smalt.Store.get(:smalt_resources, key)) do
        {:error, {:arm_error, 409, "Conflict", entity_label(kind, name) <> " already exists"}}
      else
        merged = deep_merge(defaults(kind), body)

        record = %{
          "id" => arm_id(kind, ns, name),
          "name" => name,
          "type" => full_type(kind),
          "location" => Map.get(body, "location", "eastus"),
          "properties" => merged["properties"] || %{}
        }

        Smalt.Store.put(:smalt_resources, key, record)
        materialize(kind, name)

        {:ok, to_wire(record), true}
      end
    end
  end

  @doc """
  Fetches one entity's ARM record; `{:error, {:arm_error, 404, "NotFound",
  ...}}` when absent.
  """
  @spec get_entity(:queues | :topics, String.t(), String.t()) ::
          {:ok, map()} | {:error, {:arm_error, 404, String.t(), String.t()}}
  def get_entity(kind, ns, name) do
    case Smalt.Store.get(:smalt_resources, arm_key(kind, ns, name)) do
      {:ok, record} -> {:ok, to_wire(record)}
      :error -> {:error, {:arm_error, 404, "NotFound", entity_label(kind, name) <> " not found"}}
    end
  end

  @doc """
  Deletes the ARM record + AMQP entity; `{:error, {:arm_error, 404, ...}}`
  when absent. Topic delete also tears down `topic/Subscriptions/*`
  entities (mirroring the arm_gateway sb_child_delete contract).
  """
  @spec delete_entity(:queues | :topics, String.t(), String.t()) ::
          :ok | {:error, {:arm_error, 404, String.t(), String.t()}}
  def delete_entity(kind, ns, name) do
    key = arm_key(kind, ns, name)

    case Smalt.Store.get(:smalt_resources, key) do
      {:ok, _record} ->
        Smalt.Store.delete(:smalt_resources, key)
        teardown(kind, name)
        :ok

      :error ->
        {:error, {:arm_error, 404, "NotFound", entity_label(kind, name) <> " not found"}}
    end
  end

  # --- topic subscriptions child face (wave-6 lane w6bd) ------------------------------

  @sub_type_prefix "Microsoft.ServiceBus/namespaces/topics"

  @subscription_defaults %{
    "lockDuration" => "PT1M",
    "maxDeliveryCount" => 10,
    "deadLetteringOnMessageExpiration" => false,
    "forwardTo" => nil,
    "status" => "Active"
  }

  @doc """
  Lists subscriptions under a topic (ARM child face). Enumerates the real
  `:smalt_resources` table — no shadow copy. Sorted by name.
  """
  @spec list_subscriptions(String.t(), String.t()) ::
          {:ok, [map()]} | {:error, {:arm_error, 404, String.t(), String.t()}}
  def list_subscriptions(ns, topic) when is_binary(ns) and is_binary(topic) do
    with {:ok, _} <- get_entity(:topics, ns, topic) do
      subs =
        all_resources()
        |> Enum.filter(fn {key, record} ->
          is_binary(key) and String.contains?(key, sub_suffix(ns, topic)) and
            is_map(record) and String.ends_with?(record["type"] || "", "/subscriptions")
        end)
        |> Enum.map(fn {_key, record} -> sub_to_wire(record) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(fn %{"name" => n} -> n end)

      {:ok, subs}
    end
  end

  @doc """
  Creates a topic subscription (ARM child POST): defaults merged UNDER the
  user body, ARM record in `:smalt_resources`, AMQP entity materialized at
  `"<topic>/Subscriptions/<sub>"` in `:smalt_sb_queues` via
  `QueueStore.ensure_queue/1` (the same seam w6aj's create path uses, so
  the AMQP delivery engine honors it). Errors: 400 invalid shape, 404
  unknown topic, 409 duplicate subscription.
  """
  @spec create_subscription(String.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, {:arm_error, pos_integer(), String.t(), String.t()}}
  def create_subscription(ns, topic, sub, body) when is_binary(ns) and is_binary(topic) do
    with :ok <- validate_name(sub),
         :ok <- validate_body(body),
         {:ok, _} <- get_entity(:topics, ns, topic) do
      key = sub_arm_key(ns, topic, sub)

      if match?({:ok, _}, Smalt.Store.get(:smalt_resources, key)) do
        {:error, {:arm_error, 409, "Conflict", "Subscription '#{sub}' already exists"}}
      else
        props = deep_merge(%{"properties" => @subscription_defaults}, %{"properties" => body})

        record = %{
          "id" => sub_arm_id(ns, topic, sub),
          "name" => sub,
          "type" => "#{@sub_type_prefix}/#{topic}/subscriptions",
          "location" => Map.get(body, "location", "eastus"),
          "properties" => props["properties"]
        }

        Smalt.Store.put(:smalt_resources, key, record)
        QueueStore.ensure_queue("#{topic}/Subscriptions/#{sub}")

        {:ok, sub_to_wire(record)}
      end
    end
  end

  @doc """
  Fetches one subscription's ARM record; 404 when the topic or the
  subscription is absent.
  """
  @spec get_subscription(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, {:arm_error, 404, String.t(), String.t()}}
  def get_subscription(ns, topic, sub) do
    case Smalt.Store.get(:smalt_resources, sub_arm_key(ns, topic, sub)) do
      {:ok, record} -> {:ok, sub_to_wire(record)}
      :error -> {:error, {:arm_error, 404, "NotFound", "Subscription '#{sub}' not found"}}
    end
  end

  @doc """
  Deletes the subscription's ARM record + AMQP entity; 404 when absent
  (mirrors the landed topic-delete cascade: the AMQP row at
  `"<topic>/Subscriptions/<sub>"` goes with it).
  """
  @spec delete_subscription(String.t(), String.t(), String.t()) ::
          :ok | {:error, {:arm_error, 404, String.t(), String.t()}}
  def delete_subscription(ns, topic, sub) do
    key = sub_arm_key(ns, topic, sub)

    case Smalt.Store.get(:smalt_resources, key) do
      {:ok, _} ->
        Smalt.Store.delete(:smalt_resources, key)
        Smalt.Store.delete(:smalt_sb_queues, "#{topic}/Subscriptions/#{sub}")
        :ok

      :error ->
        {:error, {:arm_error, 404, "NotFound", "Subscription delete: '#{sub}' not found"}}
    end
  end

  @doc """
  Lists a subscription's rules via the landed RuleStore (w6m) — read-only.
  """
  @spec list_rules(String.t(), String.t(), String.t()) ::
          {:ok, [map()]} | {:error, {:arm_error, 404, String.t(), String.t()}}
  def list_rules(ns, topic, sub) do
    with {:ok, _} <- get_subscription(ns, topic, sub) do
      {:ok, stored} = RuleStore.list_rules(topic, sub)

      {:ok, Enum.map(stored, &RuleStore.wire_description/1)}
    end
  end

  # --- internals (w6bd) ---------------------------------------------------------------

  defp sub_suffix(ns, topic), do: "/namespaces/#{String.downcase(ns)}/topics/#{topic}/subscriptions/"

  defp sub_arm_id(ns, topic, sub),
    do: "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ServiceBus/namespaces/#{ns}/topics/#{topic}/subscriptions/#{sub}"

  defp sub_arm_key(ns, topic, sub), do: String.downcase(sub_arm_id(ns, topic, sub))

  defp sub_to_wire(record) when is_map(record) do
    props = record["properties"] || %{}

    %{
      "id" => record["id"],
      "name" => sub_name_from_id(record["id"]),
      "name2" => record["name"],
      "type" => record["type"],
      "properties" => %{
        "lockDuration" => props["lockDuration"] || "PT1M",
        "maxDeliveryCount" => props["maxDeliveryCount"] || 10,
        "deadLetteringOnMessageExpiration" => props["deadLetteringOnMessageExpiration"] || false,
        "forwardTo" => props["forwardTo"] || nil,
        "status" => props["status"] || "Active"
      }
    }
  end

  defp sub_to_wire(_), do: nil

  defp sub_name_from_id(id) when is_binary(id) do
    id
    |> String.split("/subscriptions/")
    |> List.last()
  end

  defp sub_name_from_id(_), do: nil

  defp all_resources do
    if :ets.info(:smalt_resources) == :undefined do
      []
    else
      :ets.tab2list(:smalt_resources)
    end
  end

  defp validate_name(name) do
    if name == "" or byte_size(name) > 260 do
      {:error, {:arm_error, 400, "InvalidResourceShape", "invalid entity name"}}
    else
      :ok
    end
  end

  defp validate_body(body) when is_map(body), do: :ok
  defp validate_body(_), do: {:error, {:arm_error, 400, "InvalidResourceShape", "body must be a JSON object"}}

  defp entity_label(:queues, name), do: "Queue '#{name}'"
  defp entity_label(:topics, name), do: "Topic '#{name}'"

  defp arm_id(kind, ns, name),
    do: "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ServiceBus/namespaces/#{ns}/#{kind}/#{name}"

  defp arm_key(kind, ns, name), do: String.downcase(arm_id(kind, ns, name))

  defp full_type(:queues), do: @queue_type
  defp full_type(:topics), do: @topic_type

  defp defaults(:queues), do: @queue_defaults
  defp defaults(:topics), do: @topic_defaults

  defp deep_merge(defaults, user) when is_map(defaults) and is_map(user) do
    Map.merge(defaults, user, fn _k, d, u -> deep_merge(d, u) end)
  end

  defp deep_merge(_defaults, user), do: user

  defp to_wire(record) when is_map(record) do
    props = record["properties"] || %{}

    %{
      "id" => record["id"],
      "name" => record["name"],
      "type" => record["type"],
      "properties" => %{
        "lockDuration" => props["lockDuration"] || "PT1M",
        "maxDeliveryCount" => props["maxDeliveryCount"] || 10,
        "defaultMessageTimeToLive" => props["defaultMessageTimeToLive"] || "P14D",
        "status" => props["status"] || "Active"
      }
    }
  end

  defp to_wire(_), do: nil

  # AMQP entity materialization / teardown (arm_gateway sb_materialize_amqp /
  # sb_child_delete contract).
  defp materialize(:queues, name), do: QueueStore.ensure_queue(name)
  defp materialize(:topics, name), do: QueueStore.ensure_queue(name)

  defp teardown(:queues, name), do: Smalt.Store.delete(:smalt_sb_queues, name)

  defp teardown(:topics, name) do
    Smalt.Store.delete(:smalt_sb_queues, name)

    if :ets.info(:smalt_sb_queues) != :undefined do
      for q <- :ets.tab2list(:smalt_sb_queues), is_binary(elem(q, 0)) do
        if String.starts_with?(elem(q, 0), "#{name}/Subscriptions/") do
          Smalt.Store.delete(:smalt_sb_queues, elem(q, 0))
        end
      end
    end

    :ok
  end
end
