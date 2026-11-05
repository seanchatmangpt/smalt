defmodule Smalt.Aoq.Supervisor do
  @moduledoc """
  Root of the AoQ plane subtree (aq-architecture-spec.md §1.2, LANE-11).

  one_for_one: Listener crash restarts the wire face; WorkerPool crash
  restarts the pool (workers are stateless — restart, never data loss);
  NifHolder crash restarts resource-lifetime ownership only.

  Boot order: NifHolder FIRST — it publishes the persistent_term parse/encode
  impl that pool workers read on their first call, so a worker never races
  the holder on boot. Then WorkerPool, then Listener (the wire face comes up
  only once workers can actually ingest frames).

  one_for_one: Listener crash restarts the wire face; WorkerPool crash
  restarts the pool (workers are stateless — restart, never data loss);
  NifHolder crash restarts resource-lifetime ownership only.

  Boot: config-gated, default OFF (byte-identical boot for every existing
  surface). Enable with `config :smalt, :aoq, enabled: true, port: 9093`.
  9093 (not 9092) — 9092 is the Kafka wire face's default in the same data
  plane, and a fixed-port collision would fail both binds. Under test the
  port is ephemeral (the config/test.exs test_port precedent).
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    cfg = config()

    # Arrow schema boot source (lanes C3 + L52): the bundle is the
    # registry of truth, and `Smalt.Aoq.Tables.boot/1` is the only
    # lawful write path (writes frame_types/epochs/arrow_schemas and
    # seals). A refused bundle is a loud log + compile-time fallback
    # (`Smalt.Aoq.Arrow.Boot.registry/2`); the plane still boots. The
    # default bundle is the shipped empty one, so this is byte-identical
    # with the compile-time empty registry.
    Smalt.Aoq.Tables.boot(arrow_schemas: Smalt.Aoq.Arrow.Boot.registry())

    # Durable-cursor checkpoint chain (v26.11.6 offset-restart lane): the
    # journal sink (matter scope "aoq") boots FIRST, then CursorPersist —
    # which folds sealed checkpoints back into the ring cursor at boot
    # (boot-only restore, fail-closed on integrity refusals) — and only
    # then the NifHolder/WorkerPool/Listener data path consumes that
    # cursor. The cursor is minted here and shared: restore happens before
    # any worker can claim a slot.
    cursor = Smalt.Aoq.Cursor.new()
    journal_dir = Smalt.Aoq.CursorPersist.journal_dir(cfg)
    sink = Smalt.Aoq.CursorPersist.Sink
    cfg = Keyword.put(cfg, :cursor, cursor)

    persist = [
      {Smalt.Storage.JournalSink,
       name: sink, dir: journal_dir, sync_interval_ms: Keyword.get(cfg, :journal_sync_ms, 500)},
      {Smalt.Aoq.CursorPersist,
       cursor: cursor,
       sink: sink,
       dir: journal_dir,
       checkpoint_every: Keyword.get(cfg, :checkpoint_every, 1024)}
    ]

    base =
      persist ++
        [
          {Smalt.Aoq.NifHolder, cfg},
          {Smalt.Aoq.WorkerPool, cfg},
          {Smalt.Aoq.Listener, cfg}
        ]

    # Partitioned plane (LANE-05): config-gated, default OFF — byte-identical
    # boot for every existing surface. Enable with
    # `config :smalt, :aoq, partitioned: true`.
    children =
      if cfg[:partitioned] do
        base ++ [{Smalt.Aoq.Partitions, cfg}, {Smalt.Aoq.PartitionSup, cfg}]
      else
        base
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "AoQ plane config (`config :smalt, :aoq, [...]`), defaults baked in."
  @spec config() :: keyword
  def config do
    cfg = Application.get_env(:smalt, :aoq, [])

    # Port resolution: an explicit `:port` inside `config :smalt, :aoq` wins;
    # otherwise the flat `config :smalt, :aoq_port` (the config/test.exs
    # ephemeral-probe contract) otherwise the 9093 default.
    port =
      cfg[:port] || Application.get_env(:smalt, :aoq_port, 9093)

    cfg
    |> Keyword.put(:port, port)
    |> Keyword.put_new(:workers, System.schedulers_online())
  end
end
