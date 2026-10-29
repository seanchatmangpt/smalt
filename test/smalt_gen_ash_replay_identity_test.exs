defmodule Smalt.GenAshReplayIdentityTest do
  @moduledoc """
  Replay fence (wave v26.10.29, W3): re-running the task over the committed
  slice fixture must be a DISK no-op — file count stable, registry/domain/
  sample-resource checksums byte-identical, exit 0.

  `--yes` (auto-injected on non-tty) suppresses igniter's diff/no-change
  output, so the fence asserts disk state, not stdout. Non-vacuity witness:
  the defmodule-less registry (r01) would flip this fence — a gate that
  cannot flip is the failure.
  """

  use ExUnit.Case, async: false

  @ttl "test/fixtures/ash_gen_sample.ttl"
  @watched ~w(lib/smalt/ash_gen/registry.ex lib/smalt/network.ex lib/smalt/network/virtual_network.ex lib/smalt/network/subnet.ex)

  test "task re-run over the landed slice is a disk no-op (replay identity)" do
    before = snapshot()

    {out, exit} = System.cmd("mix", ["smalt.gen.ash", @ttl, "--provider", "Microsoft.Network"],
      cd: File.cwd!(),
      env: %{"MIX_ENV" => "dev"},
      stderr_to_stdout: true
    )

    assert exit == 0, "task failed: #{String.slice(out, -800, 800)}"
    after_state = snapshot()

    assert before == after_state,
           "replay identity broken — disk state changed:\n" <>
             inspect(Enum.unzip(before -- after_state), limit: :infinity)
  end

  defp snapshot do
    count = Path.wildcard("lib/smalt/network/*.ex") |> length()

    hashes =
      @watched
      |> Map.new(fn path -> {path, sha(path)} end)

    [{:count, count} | Map.to_list(hashes)]
  end

  defp sha(path) do
    case File.read(path) do
      {:ok, bin} -> :crypto.hash(:sha256, bin)
      :error -> :missing
    end
  end
end
