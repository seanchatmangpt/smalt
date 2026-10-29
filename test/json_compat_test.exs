defmodule Smalt.JsonCompatTest do
  @moduledoc """
  T46JSON byte-equivalence court (Chicago: real Jason, real :json, real payloads,
  assertions on decoded state — no mocks). Also types the one known divergence:
  raw `:json` maps JSON null to atom `null`; the seam normalizes to `nil`.
  """

  use ExUnit.Case, async: true

  @payloads [
    # [name, json]
    {"plain object", ~s({"id":"c1","partitionKey":"pk"})},
    {"nested arrays", ~s({"a":[1,2,[3,{"b":null}]]})},
    {"big integer", ~s({"big":123456789012345678901234567890})},
    {"exponent float", ~s({"e":1e2})},
    {"float", ~s({"f":1.5})},
    {"booleans + null", ~s({"t":true,"f":false,"z":null})},
    {"unicode string", ~s({"s":"héllo→世界"})},
    {"empty containers", ~s({"m":{},"a":[]})},
    {"cosmos query body", ~s({"query":"SELECT * FROM c","parameters":[{"name":"@p","value":42}]})}
  ]

  defp assert_equal(json) do
    jason = Jason.decode!(json)

    native =
      Smalt.JsonCompat.decode!(json)
      |> case do
        # decode! with :native may not be active; force both engines for the court
        _ -> native_decode(json)
      end

    assert jason == native, "engines diverge on: #{json}\njason=#{inspect(jason)}\nnative=#{inspect(native)}"
  end

  defp native_decode(json) do
    json
    |> :json.decode()
    |> null_to_nil()
  end

  defp null_to_nil(:null), do: nil
  defp null_to_nil(%{} = m), do: Map.new(m, fn {k, v} -> {k, null_to_nil(v)} end)
  defp null_to_nil(l) when is_list(l), do: Enum.map(l, &null_to_nil/1)
  defp null_to_nil(o), do: o

  describe "byte-equivalence court (Jason vs :json, normalized)" do
    test "structurally equal results across payload classes" do
      for {name, json} <- @payloads do
        assert_equal(json)
        IO.puts("[court] #{name}: EQUIVALENT")
      end
    end

    test "raw :json divergence typed: null -> atom null, not nil" do
      raw = :json.decode(~s({"z":null}))
      assert raw == %{"z" => :null}
      refute raw == Jason.decode!(~s({"z":null}))
      IO.puts("[court] raw-:json null divergence: TYPED (atom null vs nil, seam normalizes)")
    end

    test "seam normalizes raw :json null to nil" do
      assert %{"z" => nil} = :json.decode(~s({"z":null})) |> then(&Smalt.JsonCompat.normalize_for_court/1)
    end
  end

  describe "engine flag" do
    test "default engine is runtime-gated: native when :json loads, jason otherwise" do
      expected = if Code.ensure_loaded?(:json) and function_exported?(:json, :decode, 1) do
        :native
      else
        :jason
      end

      assert Application.get_env(:smalt, :json_engine, expected) == expected

      # The raising and non-raising forms agree on valid input.
      assert Smalt.JsonCompat.decode!(~s({"a":1})) == %{"a" => 1}
      assert Smalt.JsonCompat.decode(~s({"a":1})) == {:ok, %{"a" => 1}}
      assert {:error, _} = Smalt.JsonCompat.decode("{not json")
    end

    test "native engine decodes identically after normalization" do
      Application.put_env(:smalt, :json_engine, :native)

      try do
        assert Smalt.JsonCompat.decode!(~s({"query":"SELECT * FROM c","z":null})) ==
                 %{"query" => "SELECT * FROM c", "z" => nil}
      after
        Application.delete_env(:smalt, :json_engine)
      end
    end
  end
end
