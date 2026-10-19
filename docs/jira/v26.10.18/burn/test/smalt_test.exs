defmodule SmaltTest do
  use ExUnit.Case
  doctest Smalt

  test "greets the world" do
    assert Smalt.hello() == :world
  end
end
