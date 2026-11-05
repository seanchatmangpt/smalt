defmodule Smalt.Aoq.NifHolderPqcTest do
  @moduledoc """
  PQC posture gate (v26.11.6 lane 13): `pqc: false` default; pqc-on with
  an incapable NIF refuses typed — never a quiet classical fallback.
  """

  use ExUnit.Case, async: false

  test "pqc off by default: gate is :ok with classical framing lawful" do
    assert :ok == Smalt.Aoq.NifHolder.pqc_gate()
    pqc? = :smalt |> Application.get_env(:aoq, []) |> Keyword.get(:pqc, false)
    assert pqc? == false, "config :smalt, :aoq must default pqc: false"
  end

  test "pqc on + incapable NIF refuses typed, never a quiet fallback" do
    Application.put_env(:smalt, :aoq, enabled: true, port: 9093, pqc: true)

    on_exit(fn ->
      Application.put_env(:smalt, :aoq, enabled: false, port: 9093, pqc: false)
    end)

    assert {:error, {:pqc_nif_incapable, Smalt.Aoq.Nif.Stub}} ==
             Smalt.Aoq.NifHolder.pqc_gate()
  end

  test "pqc on + capable NIF admits" do
    defmodule CapableNif do
      @behaviour Smalt.Aoq.Nif

      @impl true
      def pqc_capable?, do: true

      @impl true
      def parse(_frame), do: {:error, :unused_in_court}

      @impl true
      def encode(_term), do: {:error, :unused_in_court}
    end

    Application.put_env(:smalt, :aoq, enabled: true, port: 9093, pqc: true)
    :persistent_term.put({Smalt.Aoq.NifHolder, :impl}, CapableNif)

    on_exit(fn ->
      Application.put_env(:smalt, :aoq, enabled: false, port: 9093, pqc: false)
      :persistent_term.put({Smalt.Aoq.NifHolder, :impl}, Smalt.Aoq.Nif.Stub)
    end)

    assert :ok == Smalt.Aoq.NifHolder.pqc_gate()
  end
end
