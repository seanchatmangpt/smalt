defmodule Smalt.Messaging.Kafka.Supervisor do
  @moduledoc """
  AZ-1 — supervision subtree for the Kafka wire face:

  - `Smalt.Messaging.Kafka.ConnSup` — DynamicSupervisor for wire conns
  - `Smalt.Messaging.Kafka.Sink` — the segmented journal (`.wal` face +
    `.seal` gates) under the configured `:kafka_log_dir`
  - `Smalt.Messaging.Kafka.Log` — ETS log face over the shared
    `Smalt.Messaging.PartitionLog` engine (sealed-segment replay on boot;
    byte-exact fetch-back)
  - `Smalt.Messaging.Kafka.Listener` — TCP accept loop on
    `:kafka_port` (default 9092; ephemeral under test)
  - v26.11.6 L6 child wiring: the AoQ log face over the SAME shared
    engine/tables — its own journal sink (`Smalt.Aoq.LogSink` under
    `:aoq_log_dir`) + the AoQ PartitionLog instance (`Smalt.Aoq.Storage.Server`,
    event_type `0x414F`, passthrough parser, no guard, no fan-out). Face
    isolation is by topic, never by process or table.
  """

  use Supervisor

  @sink_dir_default "var/kafka-journal"
  @aoq_sink_dir_default "var/aoq-journal"

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

    aoq_dir =
      Keyword.get(opts, :aoq_dir) || Application.get_env(:smalt, :aoq_log_dir) ||
        @aoq_sink_dir_default

    children = [
      {DynamicSupervisor, name: Smalt.Messaging.Kafka.ConnSup},
      Supervisor.child_spec(
        {Smalt.Storage.JournalSink,
         dir: dir, name: Smalt.Messaging.Kafka.Sink, segment_ceiling: 8 * 1024 * 1024},
        restart: :permanent
      ),
      %{id: Smalt.Messaging.Kafka.Log, start: {Smalt.Messaging.Kafka.Log, :start_link, [[dir: dir]]}},
      # v26.11.4 — Durable Offset Journal (DETS + append-only binary journal)
      %{id: Smalt.Messaging.OffsetJournal,
        start: {Smalt.Messaging.OffsetJournal, :start_link, [[]]}},
      # KD-COVERS: KD-190 — group coordinator face (lane L1 v26.11.6 appends
      # this child only; L6 owns stage-1 of this file, overlap disclosed).
      %{id: Smalt.Messaging.Kafka.GroupManager,
        start: {Smalt.Messaging.Kafka.GroupManager, :start_link, [[]]}},
      %{id: Smalt.Messaging.Kafka.Listener,
        start: {Smalt.Messaging.Kafka.Listener, :start_link, [[port: port]]}},
      # v26.11.6 L6 — AoQ log face (shared engine, shared tables, own journal).
      # SLA-UNBLOCK (LANE-05, disclosed in both receipts): the default
      # child_spec id collided with the L1 JournalSink child above
      # (module-name id) and refused the whole app boot; a distinct :id
      # is the minimal unblock. L6 supersedes at integration.
      Supervisor.child_spec(
        {Smalt.Storage.JournalSink,
         dir: aoq_dir, name: Smalt.Aoq.LogSink, segment_ceiling: 8 * 1024 * 1024},
        id: Smalt.Aoq.LogSink,
        restart: :permanent
      ),
      %{
        id: Smalt.Aoq.Storage.Server,
        start:
          {Smalt.Messaging.PartitionLog, :start_link,
           [
             [
               name: Smalt.Aoq.Storage.Server,
               label: %{service: :aoq, role: :log},
               log_prefix: "aoq",
               dir: aoq_dir,
               sink: Smalt.Aoq.LogSink,
               parser: {Smalt.Aoq.Storage, :passthrough_parser, []},
               fan_out: nil,
               guard: nil,
               event_type: 0x414F
             ]
           ]}
      }
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 10, max_seconds: 5)
  end
end
