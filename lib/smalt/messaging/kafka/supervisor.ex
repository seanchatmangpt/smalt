defmodule Smalt.Messaging.Kafka.Supervisor do
  @moduledoc """
  AZ-1 — supervision subtree for the Kafka wire face:

  - `Smalt.Messaging.Kafka.ConnSup` — DynamicSupervisor for wire conns
  - `Smalt.Messaging.Kafka.Sink` — the segmented journal (`.wal` face +
    `.seal` gates) under the configured `:kafka_log_dir`
  - `Smalt.Messaging.Kafka.Log` — ETS log engine (sealed-segment replay on
    boot; byte-exact fetch-back)
  - `Smalt.Messaging.Kafka.Listener` — TCP accept loop on
    `:kafka_port` (default 9092; ephemeral under test)
  """

  use Supervisor

  @sink_dir_default "var/kafka-journal"

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    dir =
      Keyword.get(opts, :dir) || Application.get_env(:smalt, :kafka_log_dir) ||
        @sink_dir_default

    port =
      Keyword.get(opts, :port) || Application.get_env(:smalt, :kafka_port, 9092)

    children = [
      {DynamicSupervisor, name: Smalt.Messaging.Kafka.ConnSup},
      Supervisor.child_spec(
        {Smalt.Storage.JournalSink,
         dir: dir, name: Smalt.Messaging.Kafka.Sink, segment_ceiling: 8 * 1024 * 1024},
        restart: :permanent
      ),
      %{id: Smalt.Messaging.Kafka.Log, start: {Smalt.Messaging.Kafka.Log, :start_link, [[dir: dir]]}},
      %{id: Smalt.Messaging.Kafka.Listener,
        start: {Smalt.Messaging.Kafka.Listener, :start_link, [[port: port]]}}
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 10, max_seconds: 5)
  end
end
