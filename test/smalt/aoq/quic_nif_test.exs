defmodule Smalt.Aoq.QuicNifTest do
  use ExUnit.Case, async: false

  # The gate must agree with the loader's own witness: the staged-artifact
  # branch can only be true when loaded?/0 is true.
  test "load_status and loaded? agree" do
    status = Smalt.Aoq.Quic.Nif.load_status()

    case status do
      {:loaded, _path} -> assert Smalt.Aoq.Quic.Nif.loaded?()
      {:stub, _reason} -> refute Smalt.Aoq.Quic.Nif.loaded?()
    end
  end

  test "gate task module exposes run/1" do
    assert Code.ensure_loaded?(Mix.Tasks.Smalt.Aoq.NifGate)
    assert function_exported?(Mix.Tasks.Smalt.Aoq.NifGate, :run, 1)
  end
end
