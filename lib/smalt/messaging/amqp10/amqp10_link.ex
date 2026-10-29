defmodule Smalt.Amqp10.Link do
  @moduledoc """
  Per-link actor of the crash-only AMQP 10 family. Spawned (linked, non-trapping)
  by its session on ATTACH; grants immediate flow credit, dispatches settled
  transfers into the named ETS table, and answers each settled transfer with an
  `accepted` disposition back through the connection.
  """

  @credit 100

  @doc """
  The message contract between `Connection`/`Session` routing and this link:
  `{:amqp10_frame, {performative_name, fields_map}, payload_iodata}`.
  """
  @spec frame_message() :: {:amqp10_frame, {atom(), map()}, iodata() | nil}
  def frame_message, do: {:amqp10_frame, {:transfer, %{}}, <<>>}

  @spec start_link(keyword()) :: pid()
  def start_link(opts) do
    parent = self()

    pid =
      spawn_link(fn ->
        :proc_lib.set_label({__MODULE__, Keyword.fetch!(opts, :name)})
        send(parent, {:amqp10_link_ready, self()})
        loop(opts, 0)
      end)

    pid
  end

  # Single 100-credit grant (granted once, on the attach flow); no
  # replenishment. Each settled transfer consumes one credit; at exhaustion
  # the link answers the over-run with a typed exit -> cascade (crash-only
  # law: the credit boundary is an auditable transition, never a silent drop).
  defp loop(opts, credit) do
    receive do
      {:amqp10_frame, {:transfer, %{delivery_id: id, settled: settled?}}, payload} ->
        if credit > 0 do
          dispatch_settled(opts, id, settled?, payload)
          loop(opts, credit - 1)
        else
          exit({:amqp10_link_credit_exhausted, opts[:handle], id})
        end

      {:amqp10_grant_credit, channel, handle} ->
        send(opts[:conn], {:amqp10_tx, channel,
                           {:flow, %{next_incoming_id: 0, incoming_window: 1000,
                                     next_outgoing_id: 1, outgoing_window: 1000,
                                     handle: handle, delivery_count: 0,
                                     link_credit: @credit}}})
        loop(opts, @credit)

      {:amqp10_frame, {:disposition, _fields}, _payload} ->
        loop(opts, credit)

      {:amqp10_frame, {:detach, _fields}, _payload} ->
        :ok

      {:amqp10_flow, _fields} ->
        loop(opts, credit)

      # Crash-only law: an unmatched routing message is a protocol defect in
      # the family, not noise — die loudly so the cascade surfaces it.
      other ->
        exit({:amqp10_bad_internal_message, other})
    end
  end

  defp dispatch_settled(opts, delivery_id, settled?, payload) do
    if settled? do
      table = opts[:table]

      :ets.insert(table, {{opts[:channel], delivery_id}, payload,
                          :erlang.system_time(:millisecond)})

      send(opts[:conn], {:amqp10_tx, opts[:channel],
                         {:disposition, %{role: true, first: delivery_id,
                                          settled: true, state: :accepted}}})
    end
  end
end
