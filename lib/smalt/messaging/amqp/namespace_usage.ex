defmodule Smalt.Amqp.NamespaceUsage do
  @moduledoc """
  Service Bus namespace usage/quota face (wave-6 lane w6n).

  Chicago-school: every count is a live read over the substrate's own real
  stores — `:smalt_sb_queues` (entity rows), `:smalt_resources` (ARM topic
  records), `:smalt_sb_messages` (message rows). No shadow tables, no ETS
  duplication. Create a queue and the next usage read reflects it.
  """

  @dlq_suffix "/$deadletterqueue"
  @sub_marker "/Subscriptions/"

  @doc "Configured messaging units (env `:sb_messaging_units`, default 1)."
  @spec messaging_units() :: pos_integer()
  def messaging_units do
    case Application.get_env(:smalt, :sb_messaging_units) do
      n when is_integer(n) and n >= 1 -> n
      _ -> 1
    end
  end

  @doc """
  Namespace usage map. `{:ok, usage}` when the store tables are materialized,
  `{:error, :no_table}` otherwise (typed refusal, never a badarg on a cold
  store).
  """
  @spec usage() :: {:ok, map()} | {:error, :no_table}
  def usage do
    if tables_ready?() do
      {:ok, compute()}
    else
      {:error, :no_table}
    end
  end

  @doc "Fail-closed gate: the tables this face reads are materialized."
  @spec tables_ready?() :: boolean()
  def tables_ready? do
    :ets.info(:smalt_sb_queues) != :undefined and
      :ets.info(:smalt_sb_messages) != :undefined and
      :ets.info(:smalt_resources) != :undefined
  end

  ## ------------------------------------------------------------------
  ## Internal
  ## ------------------------------------------------------------------

  defp compute do
    entities =
      :smalt_sb_queues
      |> Smalt.Store.keys()
      |> Enum.reject(&subscription_row?/1)
      |> Enum.reject(&dlq_row?/1)
      |> Enum.uniq()

    topics = Enum.filter(entities, &topic_entity?/1)

    %{
      "messagingUnits" => messaging_units(),
      "activeQueues" => length(entities) - length(topics),
      "topics" => length(topics),
      "totalMessages" => count_all_messages(),
      "activeMessages" => count_active_messages()
    }
  end

  defp subscription_row?(name), do: String.contains?(name, @sub_marker)
  defp dlq_row?(name), do: String.ends_with?(name, @dlq_suffix)

  defp topic_entity?(name) do
    has_subscription_row?(name) or arm_topic_record?(name)
  end

  defp has_subscription_row?(name) do
    :smalt_sb_queues
    |> Smalt.Store.list_prefix(name <> @sub_marker)
    |> Enum.count() > 0
  end

  defp arm_topic_record?(name) do
    suffix = "/topics/#{String.downcase(name)}"

    Enum.any?(Smalt.Store.keys(:smalt_resources), fn key ->
      is_binary(key) and String.ends_with?(key, suffix)
    end)
  end

  defp count_all_messages do
    :ets.select_count(:smalt_sb_messages, [{{{:"$1", :_}, :_}, [], [true]}])
  end

  defp count_active_messages do
    dlq_count =
      :smalt_sb_queues
      |> Smalt.Store.keys()
      |> Enum.filter(&dlq_row?/1)
      |> Enum.map(fn dlq_entity ->
        :ets.select_count(:smalt_sb_messages, [{{{dlq_entity, :_}, :_}, [], [true]}])
      end)
      |> Enum.sum()

    count_all_messages() - dlq_count
  end
end
