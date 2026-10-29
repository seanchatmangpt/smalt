defmodule Smalt.Internal.EXPL5R1CourtTest do
  @moduledoc """
  EXPL5-R1 lane court — repairs for EXPL5-T1 (MHSM non-list anyOf/allOf/
  assertions fail-open) and EXPL5-T2 (DTDL cyclic extends non-termination).

  Chicago: real compiled modules, real malformed policies / real cyclic docs.
  """

  use ExUnit.Case, async: false

  alias Smalt.DataPlane.MHSM
  alias Smalt.DTDL

  @satisfying %{"x-ms-attestation-type" => "sevsnpvm"}

  @match_any_of [
    %{"claim" => "x-ms-attestation-type", "condition" => "equals", "value" => "sevsnpvm"}
  ]

  @mismatch_any_of [
    %{"claim" => "x-ms-attestation-type", "condition" => "equals", "value" => "other"}
  ]

  # -- EXPL5-T1: malformed constraint types refuse (fail-closed) ----------------

  test "T1a: non-list anyOf (string) refuses typed 403 KeyReleasePolicyViolation" do
    assert {:error, 403, %{"error" => %{"code" => "KeyReleasePolicyViolation", "message" => msg}}} =
             MHSM.evaluate_policy(%{"anyOf" => "oops"}, @satisfying)

    assert msg =~ "anyOf must be a list"
  end

  test "T1b: non-list anyOf (map) refuses typed" do
    assert {:error, 403, %{"error" => %{"code" => "KeyReleasePolicyViolation", "message" => msg}}} =
             MHSM.evaluate_policy(%{"anyOf" => %{"claim" => "c"}}, @satisfying)

    assert msg =~ "anyOf must be a list"
  end

  test "T1c: non-list allOf refuses typed" do
    assert {:error, 403, %{"error" => %{"code" => "KeyReleasePolicyViolation", "message" => msg}}} =
             MHSM.evaluate_policy(%{"allOf" => "oops"}, @satisfying)

    assert msg =~ "allOf must be a list"
  end

  test "T1d: non-list assertions refuses typed" do
    assert {:error, 403, %{"error" => %{"code" => "KeyReleasePolicyViolation", "message" => msg}}} =
             MHSM.evaluate_policy(%{"assertions" => 42}, @satisfying)

    assert msg =~ "assertions must be a list"
  end

  test "T1 controls: list forms evaluate exactly as before the fix" do
    # satisfying list anyOf still allows
    assert :ok = MHSM.evaluate_policy(%{"anyOf" => @match_any_of}, @satisfying)
    # mismatching list anyOf still refuses
    assert {:error, 403, %{"error" => %{"code" => "KeyReleasePolicyViolation"}}} =
             MHSM.evaluate_policy(%{"anyOf" => @mismatch_any_of}, @satisfying)
    # ops-only policy unchanged
    assert :ok = MHSM.evaluate_policy(%{"allowed_operations" => ["sign"]}, %{})
    # list allOf/assertions unchanged
    assert :ok =
             MHSM.evaluate_policy(
             %{"allOf" => @match_any_of, "assertions" => @match_any_of}, @satisfying
             )
  end

  # -- EXPL5-T2: cyclic / self extends terminate with a typed refusal -----------

  @cyclic_doc Jason.encode!([
    %{"@id" => "dtmi:a;1", "@type" => "Interface", "extends" => "dtmi:b;1", "contents" => []},
    %{"@id" => "dtmi:b;1", "@type" => "Interface", "extends" => "dtmi:a;1", "contents" => []}
  ])

  @self_doc Jason.encode!(%{
    "@id" => "dtmi:s;1",
    "@type" => "Interface",
    "extends" => "dtmi:s;1",
    "contents" => []
  })

  @acyclic_doc Jason.encode!([
    %{
      "@id" => "dtmi:p;1",
      "@type" => "Interface",
      "contents" => [
        %{"@id" => "dtmi:p;1/prop", "@type" => "Property", "name" => "temp", "schema" => "string"}
      ]
    },
    %{"@id" => "dtmi:c;1", "@type" => "Interface", "extends" => "dtmi:p;1", "contents" => []}
  ])

  test "T2a: cyclic A<->B extends returns typed error promptly" do
    assert {:error, {:circular_extends, ref}} =
             Task.await(Task.async(fn -> DTDL.convert(@cyclic_doc) end), 5_000)

    assert ref in ["dtmi:a;1", "dtmi:b;1"]
  end

  test "T2b: self-extends returns typed error promptly" do
    assert {:error, {:circular_extends, "dtmi:s;1"}} =
             Task.await(Task.async(fn -> DTDL.convert(@self_doc) end), 5_000)
  end

  test "T2 control: acyclic extends graph unchanged" do
    assert {:ok, m} = DTDL.convert(@acyclic_doc)
    assert m.shapes == 2
    assert m.interfaces == ["dtmi:p;1", "dtmi:c;1"]
  end
end
