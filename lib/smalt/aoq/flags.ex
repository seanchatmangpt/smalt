defmodule Smalt.Aoq.Flags do
  @moduledoc """
  AoQ VM-flag court (LANE-09, AoQ program brief §4).

  Smalt.Aoq.Flags.verify!/0 is fail-closed: when `SMALT_AOQ_FLAGS=1` the app
  boots only if the active VM args file carries both AoQ flags. A release
  whose VM args dropped them refuses to boot.
  """

  @flags ["+sbt db", "+sbwt none", "+hms 2097152"]

  @doc "Required AoQ VM flags, in the order they appear in rel/vm.args.eex."
  @spec required_flags() :: [String.t()]
  def required_flags, do: @flags

  @doc """
  Fail-closed check: reads the active VM args file and raises if any required
  flag is missing.

  Source resolution:
  - inside a release (`RELEASE_SYS_CONFIG` set): `<RELEASE_SYS_CONFIG>/vm.args`
  - from source checkout: `rel/vm.args.eex`

  Returns `:ok` or raises `RuntimeError`.
  """
  @spec verify!() :: :ok | no_return()
  def verify! do
    path = vm_args_path()

    with {:ok, content} <- File.read(path),
         {:ok, _} <- check_flags(content) do
      :ok
    else
      {:error, :enoent} ->
        raise RuntimeError,
              "SMALT_AOQ_FLAGS=1 but the VM args file is missing (#{path}); " <>
                "the AoQ scheduling posture cannot be confirmed"

      {:error, reason} ->
        raise RuntimeError,
              "SMALT_AOQ_FLAGS=1 but the VM args file is unreadable (#{path}): " <>
                inspect(reason)

      {:missing, missing} ->
        raise RuntimeError,
              "SMALT_AOQ_FLAGS=1 but VM args are missing required AoQ flags " <>
                "#{inspect(missing)} in #{path}"
    end
  end

  @doc false
  @spec check_flags(String.t()) :: {:ok, :present} | {:missing, [String.t()]}
  def check_flags(content) do
    missing = Enum.reject(@flags, &flag_present?(content, &1))

    if missing == [] do
      {:ok, :present}
    else
      {:missing, missing}
    end
  end

  # A flag is present only as a whole-line directive outside comments.
  defp flag_present?(content, flag) do
    content
    |> String.split("\n")
    |> Enum.any?(fn line ->
      line |> strip_comment() |> String.trim() |> Kernel.==(flag)
    end)
  end

  defp strip_comment(line) do
    case String.split(line, "#", parts: 2) do
      [code, _rest] -> code
      [code] -> code
    end
  end

  defp vm_args_path do
    case System.get_env("RELEASE_SYS_CONFIG") do
      nil -> Path.join(File.cwd!(), "rel/vm.args.eex")
      "" -> Path.join(File.cwd!(), "rel/vm.args.eex")
      root -> Path.join(root, "vm.args")
    end
  end
end
