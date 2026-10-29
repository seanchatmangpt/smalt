defmodule PopcornActors.Application do
  @moduledoc """
  Minimal popcorn actor bundle (MOONSHOT lane 6): a pure-decision surface with
  nothing beyond what Popcorn itself requires. No :logger, no :jason, no
  crypto/socket/file/et imports.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {PopcornActors.Store, name: PopcornActors.Store}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: PopcornActors.Supervisor)
  end
end
