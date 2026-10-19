defmodule IsoExitProbeTest do
  use ExUnit.Case, async: false

  setup do
    SmaltTest.Env.put_restored(probe_iso_key: "setup-put")
    :ok
  end

  test "t1" do
    SmaltTest.Env.put_restored(probe_iso_key: "v1")
    assert Application.get_env(:smalt, :probe_iso_key) == "v1"
  end

  test "t2" do
    prev = Application.get_env(:smalt, :probe_iso_key)
    IO.puts("T2_SEES #{inspect(prev)}")
    assert prev == "setup-put"
  end
end
