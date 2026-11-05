defmodule Smalt.PlanesTest do
  @moduledoc false
  # L28r (aq-architecture-spec.md §1.3): :aoq admitted as a plane name —
  # naming it permits the AoQ gate via the az_prod_aoq profile; unknown
  # names still refuse boot typed. Chicago: real resolve() against real
  # Application env + real SMALT_PLANES env, assert final state.
  use ExUnit.Case, async: false

  alias Smalt.Planes
  alias Smalt.Planes.InvalidPlane

  setup do
    prior_planes = Application.get_env(:smalt, :planes)
    prior_env = System.get_env("SMALT_PLANES")

    on_exit(fn ->
      if prior_planes do
        Application.put_env(:smalt, :planes, prior_planes)
      else
        Application.delete_env(:smalt, :planes)
      end

      if prior_env do
        System.put_env("SMALT_PLANES", prior_env)
      else
        System.delete_env("SMALT_PLANES")
      end
    end)

    :ok
  end

  test "known() admits :aoq" do
    assert :aoq in Planes.known()
  end

  test "accept fixture: config planes [:data, :aoq] resolves" do
    Application.put_env(:smalt, :planes, [:data, :aoq])
    assert Planes.resolve() == [:data, :aoq]
  end

  test "accept fixture: SMALT_PLANES=control,aoq resolves via CSV path" do
    System.put_env("SMALT_PLANES", "control,aoq")
    assert Planes.resolve() == [:control, :aoq]
  end

  test "refusal fixture: unknown plane name still refuses typed, no atom minted" do
    # Built dynamically so the test itself never mints the atom the gate
    # exists to refuse (JA-R1).
    bad = :"unknown_#{System.unique_integer([:positive])}_plane"
    Application.put_env(:smalt, :planes, [:data, bad])

    assert_raise InvalidPlane, ~r/:invalid_plane/, fn ->
      Planes.resolve()
    end
  end

  test "refusal fixture: unknown SMALT_PLANES csv name refuses without minting" do
    bad = "not_a_plane_#{System.unique_integer([:positive])}"
    System.put_env("SMALT_PLANES", "aoq,#{bad}")

    assert_raise InvalidPlane, ~r/:invalid_plane/, fn ->
      Planes.resolve()
    end
  end
end
