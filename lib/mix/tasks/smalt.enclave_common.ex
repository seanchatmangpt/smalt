defmodule Mix.Tasks.Smalt.EnclaveCommon do
  @moduledoc """
  Shared plumbing for the `smalt.*` enclave CLI tasks: argv parsing
  (--help / missing-required-flag), typed stderr errors with proper exit
  codes, and the minimal in-process substrate boot (Store only — every hop
  is a plain function call through the ARM router; no Bandit listeners, no
  ports, no sockets).

  SHIM-COURT-free CLI tooling; not a data-path module.
  """

  alias Smalt.Store

  @spec ensure_store!() :: :ok
  def ensure_store! do
    if Process.whereis(Store) == nil do
      {:ok, _pid} = Store.start_link([])
      :ok
    else
      :ok
    end
  end

  @doc "Prints a typed error to stderr and exits 1."
  @spec fail!(term()) :: no_return()
  def fail!(reason) do
    IO.puts(:stderr, "[smalt] ERROR " <> to_string(reason))
    exit({:shutdown, 1})
  end

  @doc """
  `mix help`-style usage text; exits 0 for --help.
  """
  @spec help!(String.t(), no_return() | nil) :: no_return()
  def help!(text, halt \\ nil) do
    IO.puts(text)
    if halt, do: exit({:shutdown, 0}), else: exit({:shutdown, 0})
  end

  @doc """
  Resolves a --fixture path: a directory means the conventional main.tf
  inside it (Hcl.parse reads a single file).
  """
  @spec resolve_fixture(String.t()) :: String.t()
  def resolve_fixture(path) do
    if File.dir?(path), do: Path.join(path, "main.tf"), else: path
  end

  @spec require_flag!(OptionParser.parsed(), atom(), String.t()) :: String.t()
  def require_flag!(opts, key, task) do
    case Keyword.fetch(opts, key) do
      {:ok, v} ->
        v

      :error ->
        IO.puts(:stderr, "[smalt] ERROR :missing_required_flag task=#{task} flag=--#{key}")
        IO.puts(:stderr, "run `mix help #{task}` for usage")
        exit({:shutdown, 1})
    end
  end
end
