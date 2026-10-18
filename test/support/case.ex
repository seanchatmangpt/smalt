defmodule SmaltTest.Case do
  @moduledoc """
  Canonical base for new/migrated suites: ExUnit.Case with the shared helper
  imports. Migration is per-file and optional — `use ExUnit.Case` keeps
  working; this template exists so AssertEventually/Env/Store are one `use`
  away instead of a per-file import stanza.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import ExUnit.Callbacks
      import SmaltTest.AssertEventually
      import SmaltTest.Env
      import SmaltTest.Store
      import SmaltTest.Singleton, only: [start_supervised_singleton!: 2]
    end
  end
end
