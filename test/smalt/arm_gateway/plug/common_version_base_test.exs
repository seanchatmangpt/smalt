defmodule Smalt.ArmGateway.Plug.CommonVersionBaseTest do
  use ExUnit.Case, async: true

  alias Smalt.ArmGateway.Plug.Common

  describe "version_base/1" do
    @doc """
    Table: real function calls, assert on returned base. Day-less bases must
    normalize to day-prefixed ISO so Date.from_iso8601 admits them.
    """
    test "normalizes day-less bases to day-prefixed ISO, passthrough otherwise" do
      table = [
        {"2023-06-preview", "2023-06-01"},
        {"2023-06", "2023-06-01"},
        {"2024-03-01", "2024-03-01"},
        {"2021-04-01-preview", "2021-04-01"},
        {"2023-06-preview2", "2023-06-01"},
        {"garbage", "garbage"}
      ]

      for {input, expected} <- table do
        assert Common.version_base(input) == expected, "input: #{inspect(input)}"
      end
    end

    test "day-less versions are admitted by version_lte?/2" do
      assert Common.version_lte?("2023-06-preview", "2024-03-01")
      assert Common.version_lte?("2023-06", "2024-03-01")
      # Earlier-than comparison still holds after normalization.
      refute Common.version_lte?("2024-01", "2023-06-preview")
    end
  end
end
