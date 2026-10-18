defmodule SmaltTest.PortEnv do
  @moduledoc """
  Canonical save-prev/on_exit-restore discipline for :smalt Application-env
  mutations (test-isolation-leak gate, i21-leak-batch4 pattern).

      prev = SmaltTest.PortEnv.snapshot([:arm_port, :egress_port])
      SmaltTest PortEnv.apply(arm_port: 19443)
      on_exit(fn -> SmaltTest.PortEnv.restore(prev) end)

  Nil-preserving: a key that was absent is deleted on restore, not written
  as literal nil (fixes the runtime_contracts_test.exs setup drift where a
  bare `put_env(k, prev)` re-puts nil). Complements `SmaltTest.Env`:
  `Env.with/2` and `Env.put_restored/1` are the scoped/setup forms for
  ExUnit; `PortEnv` adds the explicit snapshot/apply/restore triple that a
  mix-run script (checkpoint_chain.exs, no ExUnit, no test_helper) can
  `Code.require_file` and drive manually, plus `free_port/0` (D4 collapse
  of the 10+ private `get_free_port/0` copies).
  """

  @doc """
  Save the current :smalt values for `keys` as a map. A key that is absent
  records `nil`; `restore/1` turns that back into `delete_env`.
  """
  @spec snapshot([atom]) :: %{optional(atom) => term}
  def snapshot(keys), do: Map.new(keys, &{&1, Application.get_env(:smalt, &1)})

  @doc "Put each {key, value} into :smalt Application env."
  @spec apply(keyword | map) :: :ok
  def apply(kvs), do: Enum.each(kvs, fn {k, v} -> Application.put_env(:smalt, k, v) end)

  @doc """
  Restore a `snapshot/1` map: put when the previous value was non-nil,
  `delete_env` when it was absent (nil-preserving, key order = snapshot
  order, deterministic).
  """
  @spec restore(%{optional(atom) => term}) :: :ok
  def restore(prev) do
    Enum.each(prev, fn
      {k, nil} -> Application.delete_env(:smalt, k)
      {k, v} -> Application.put_env(:smalt, k, v)
    end)
  end

  @doc """
  Ephemeral free TCP port (D4 collapse of the private `get_free_port/0`
  copies across the wire/compliance census). Listen-then-close probe.
  """
  @spec free_port() :: :inet.port_number()
  def free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
