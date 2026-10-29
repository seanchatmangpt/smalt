defmodule Smalt.Plane.DataSupervisor do
  @moduledoc """
  Supervision subtree for the Data Plane:
  - Smalt.Store — the TTV-5 store ensemble as ONE child (coordinator
    decision 2026-10-21: the store.ex-internal tree is canonical —
    Smalt.Store.start_link/1 boots Heir -> Boot(journal replay) -> 16
    permanent Partition workers under its own named supervisor; this file
    no longer lists them individually, superseding STORE-2's expansion)
  - Bandit egress router (Cosmos DB SQL AST & Blob Storage)
  - Bandit WS->AMQP relay (BK-58)
  """
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      Smalt.Store,
      # AZB-22b: bound graceful-stop. Bandit's own child_spec omits
      # `shutdown`, so with type :supervisor it defaults to :infinity —
      # a stuck ThousandIsland listener hung the whole tree's stop
      # (>60s witnessed in the burn ring). 10s bounds the wait; the
      # supervisor then brutal-kills and stop completes.
      Supervisor.child_spec(
        # Latency-realism lane: gate-off cost is ONE Application.get_env —
        # Smalt.Egress.LatencyPlug delegates straight to the router when the
        # :latency gate is off (default).
        {Bandit,
         plug: {Smalt.Egress.LatencyPlug, []},
         scheme: :http,
         port: egress_port(),
         ip: bind_ip()},
        shutdown: 10_000
      ),
      # BK-58 (BK-40 lane 3): domain-blind WebSocket -> AMQP relay. Host-side
      # bridge only (workspace transport law: smaltFetch cannot do WS); the
      # socket process owns the raw TCP leg to the sb/eh listeners.
      Supervisor.child_spec(
        {Bandit,
         plug: Smalt.Messaging.WsAmqpRelay, scheme: :http, port: ws_relay_port(), ip: bind_ip()},
        shutdown: 10_000
      ),
      # AZ-5: Web PubSub face (broker edge: client-access JWT + groups +
      # server push + CloudEvents webhook) over the BK-58 WS substrate.
      Supervisor.child_spec(
        {Bandit,
         plug: Smalt.WebPubSub.Router, scheme: :http, port: wps_port(), ip: bind_ip()},
        shutdown: 10_000
      ),
      {Smalt.WebPubSub, []},
      # AZ-1: Kafka wire face on :9092 (default; ephemeral under test) —
      # ApiVersions/Metadata/Produce/Fetch terminated directly on the wire,
      # partitions journaled through JournalSink (.wal + .seal gates),
      # records fanned out to the EH partition receivers (5673).
      Supervisor.child_spec(
        {Smalt.Messaging.Kafka.Supervisor,
         [port: kafka_port(), dir: kafka_log_dir()]},
        shutdown: 10_000
      ),
      # AZ-3b: Confidential Ledger REST face (append/seal-ladder certification/
      # chain receipts) on its own pinned port + own dedicated journal dir —
      # KD-166: 8443 /app/* remains the ETS-ledger face.
      Supervisor.child_spec(
        {Smalt.ConfidentialLedger.Supervisor, []},
        shutdown: 10_000
      )
    ] ++ egress_tls_child()

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 5)
  end

  # TLS-everywhere (P14): additive data-plane https listener. Default (flag
  # unset) is [] — byte-for-byte the old boot. SMALT_TLS_ALL_PLANES=1 mounts
  # an extra https Bandit on :egress_tls_port (8445) running the same
  # TlsTwinDispatch plug as the 9444 twin, so the same client code is
  # exercised over TLS on the data plane too. Cert material rides the same
  # Smalt.TLS.bandit_opts resolution path (env cert / dev cert) as the twin.
  defp egress_tls_child do
    if Smalt.TLS.all_planes?() do
      [
        Supervisor.child_spec(
          {Bandit,
           Smalt.TLS.bandit_opts(Smalt.Application.TlsTwinDispatch, Smalt.TLS.egress_tls_port()) ++
             [ip: bind_ip()]},
          shutdown: 10_000
        )
      ]
    else
      []
    end
  end

  defp egress_port, do: Application.get_env(:smalt, :egress_port, 8443)

  # BK-58: relay listener port; default 5675 (adjacent to the sb/eh lanes),
  # probed-free under MIX_ENV=test via config/test.exs.
  defp ws_relay_port, do: Smalt.Messaging.AmqpWsBridge.port()

  # AZ-5: Web PubSub listener port; default 5676 (adjacent to the relay),
  # probed-free under MIX_ENV=test via config/test.exs.
  defp wps_port, do: Application.get_env(:smalt, :web_pubsub_port, 5676)

  # AZ-1: Kafka wire face port (9092 default) + journal dir; probed-free
  # port under MIX_ENV=test via config/test.exs; test dir under tmp/.
  defp kafka_port, do: Application.get_env(:smalt, :kafka_port, 9092)

  defp kafka_log_dir,
    do: Application.get_env(:smalt, :kafka_log_dir, "var/kafka-journal")

  defp bind_ip do
    case Application.get_env(:smalt, :bind_all_interfaces, false) do
      true -> {0, 0, 0, 0}
      _ -> {127, 0, 0, 1}
    end
  end
end
