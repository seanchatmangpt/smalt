defmodule SmaltTest.Singleton do
  @moduledoc """
  Start a child spec under the test supervisor under a UNIQUE per-test name
  (`{:via, Registry, {SmaltTest.Registry, {module, ref}}}`), so async sibling
  suites can never collide on a registered name and the app-owned named
  singleton is never shadowed.

  `SmaltTest.Registry` is started ONCE per run in test_helper.exs (after
  `ExUnit.start/0`); this module never starts it (per-test registry starts
  are themselves a collision class — two async setups racing start_link on
  one name).

  Contract: `start_supervised!/1` (ExUnit.Callbacks) remains the lifetime
  owner — the wrapper only derives the unique name; a crash fails the owning
  test with the child's exit reason, cleanup is supervisor-ordered before
  on_exit.
  """

  @doc """
  Start `child_spec` under a unique per-test via-name. Returns `{pid, name}`.

  Call-site shape:

      {pid, name} =
        start_supervised_singleton!({Sweeper, tick_ms: :manual},
          module: Smalt.ArmGateway.LRO.Sweeper
        )
  """
  @spec start_supervised_singleton!(term, keyword) :: {pid, {:via, Registry, term}}
  # The lifetime owner is ExUnit.Callbacks.start_supervised!/1 — the test
  # supervisor stays the parent, crash reporting and ordering are ExUnit's.
  import ExUnit.Callbacks, only: [start_supervised!: 1]

  def start_supervised_singleton!(child_spec, opts \\ []) do
    module = opts[:module] || elem(child_spec, 0)
    ref = make_ref()
    name = {:via, Registry, {SmaltTest.Registry, {module, ref}}}

    child =
      Supervisor.child_spec({module, Keyword.put(opts, :name, name)}, id: ref)

    pid = start_supervised!(child)
    {pid, name}
  end
end
