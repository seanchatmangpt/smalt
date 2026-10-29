defmodule Smalt.ConfidentialLedger.Supervisor do
  @moduledoc """
  AZ-3b — supervision subtree for the Azure Confidential Ledger REST face:

  - `Smalt.Storage.JournalSink` — the ACL ledger's dedicated sink
    (`Smalt.ConfidentialLedger.Sink`, own `:acl_journal_dir` — the face
    owns its ledger; it does NOT ride the Store's `:journal_sink_dir`)
  - `Smalt.ConfidentialLedger.Service` — append + seal-ladder certification
    + sha256-chain receipts
  - `Bandit` — `Smalt.ConfidentialLedger.Router` on `:confidential_ledger_port`
    (default 8444; ephemeral under test via config/test.exs)

  KD-166: 8443 `/app/*` remains the pre-existing ETS-ledger face; the ACL
  REST face owns a dedicated port.
  """

  use Supervisor

  @acl_dir_default "var/acl-journal"

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    dir = Application.get_env(:smalt, :acl_journal_dir) || @acl_dir_default
    port = Application.get_env(:smalt, :confidential_ledger_port, 8444)

    children = [
      Supervisor.child_spec(
        {Smalt.Storage.JournalSink,
         dir: dir, name: Smalt.ConfidentialLedger.Sink, segment_ceiling: 8 * 1024 * 1024},
        id: Smalt.ConfidentialLedger.Sink,
        restart: :permanent
      ),
      {Smalt.ConfidentialLedger.Service, [dir: dir, sink: Smalt.ConfidentialLedger.Sink]},
      # AZB-22b: bound graceful-stop (a stuck ThousandIsland listener must
      # not hang the data-plane tree stop, same as the other Bandit children).
      Supervisor.child_spec(
        {Bandit,
         plug: Smalt.ConfidentialLedger.Router, scheme: :http, port: port, ip: acl_bind_ip()},
        id: Bandit,
        shutdown: 10_000
      )
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 10, max_seconds: 5)
  end

  # Same bind law as the data-plane faces (loopback default).
  defp acl_bind_ip do
    case Application.get_env(:smalt, :bind_all_interfaces, false) do
      true -> {0, 0, 0, 0}
      _ -> {127, 0, 0, 1}
    end
  end
end
