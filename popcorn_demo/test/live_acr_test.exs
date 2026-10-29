defmodule PopcornDemo.LiveAcrTest do
  @moduledoc """
  Chicago test for the ACR leg: asserts on the real repo state (real
  collaborator = the actual router/registry sources on disk), no mocks.
  """

  use ExUnit.Case, async: true

  @router "/Users/sac/smalt/lib/smalt/arm_gateway/router.ex"
  @popcorn_router "/Users/sac/smalt/popcorn_demo/lib/smalt/arm_gateway/router.ex"

  test "run/0 returns the typed unsupported skip" do
    assert {:unsupported, :acr_face_absent} = PopcornDemo.LiveAcr.run()
  end

  test "ACR face is genuinely absent from the real router source" do
    for path <- Enum.uniq([@router, @popcorn_router]) do
      if File.exists?(path) do
        src = File.read!(path)
        refute src =~ "Microsoft.ContainerRegistry",
               "ACR provider face landed in #{path} — re-author live_acr.ex as a real leg"
        refute Regex.match?(~r{"/v2/"}, src),
               "docker /v2/ face landed in #{path} — re-author live_acr.ex as a real leg"
      end
    end
  end

  test "provider registry carries no ContainerRegistry types" do
    for path <- ["/Users/sac/smalt/lib/smalt/registry.ex"] do
      refute File.read!(path) =~ "Microsoft.ContainerRegistry"
    end
  end
end
