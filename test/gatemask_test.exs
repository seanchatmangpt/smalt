defmodule Smalt.GatemaskTest do
  use ExUnit.Case, async: true

  @vectors "/Users/sac/fnox/fixtures/gatemask_vectors.json"

  test "shared vectors" do
    vecs = @vectors |> File.read!() |> Jason.decode!()
    assert vecs != []

    for %{"mask" => "0x" <> hex, "expect" => expect} <- vecs do
      mask = String.to_integer(hex, 16)
      got = Smalt.Gatemask.admit_instant_wire(mask)

      case expect do
        nil -> assert got == :admitted, "mask 0x#{hex}"
        code -> assert got == {:refused, code}, "mask 0x#{hex}"
      end
    end
  end

  test "setting all 16 gates admits" do
    mask = Enum.reduce(Smalt.Gatemask.gates(), 0, &Smalt.Gatemask.set_gate(&2, &1))
    assert mask == 0xFFFF
    assert Smalt.Gatemask.admit_instant_wire(mask) == :admitted
  end
end
