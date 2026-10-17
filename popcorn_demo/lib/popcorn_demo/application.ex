defmodule PopcornDemo.Application do
  @moduledoc """
  Popcorn entrypoint for the smalt pure-decision slice.

  Popcorn boots this supervision tree inside the browser BEAM. The smoke
  child runs smalt's pure modules end to end and reports via `Popcorn.JS`
  when running under the browser runtime; under host `mix run`/`mix test`
  it returns values without any JS bridge.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task, fn -> PopcornDemo.Smoke.run() end}
      # {Task, &PopcornDemo.Smoke.run/0}
    ]

    # In-browser there is no higher-order supervisor to crash into; keep the
    # tree one_for_one so a failed smoke task doesn't kill the VM boot.
    Supervisor.start_link(children, strategy: :one_for_one, name: PopcornDemo.Supervisor)
  end
end
