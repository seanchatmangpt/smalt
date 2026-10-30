# KD-124 witness: first-ever `PUT .../namespaces/:ns` with a sku body answered
# 500 AFTER storing the record (retry → 200). Root cause (substrate.log
# :10943, live 9443): ** (UndefinedFunctionError)
# Smalt.EgressRouter.Peers.emit_resource_write_success/2 undefined — the AZB-10
# post-store cross-plane emission at the generic resource PUT success arm
# (router.ex handle_resource_put/5) raised after Store.put.
#
# Fix: the emission is a post-store SIDEBAND — any raise/exit is logged and
# dropped (KD-COVERS: KD-124 on the try arm in router.ex).
#
# Chicago discipline: real Store rows, real ARM router dispatch
# (Plug.Router.call in-process), real code-path deletion to witness the
# module-unavailable face — no mocks.
#
# Context: solo (integration tier, in-process dispatch).

defmodule Smalt.Internal.NamespacePutTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.Store

  @api_version "2021-04-01"
  @sub "sub-kd124"
  @rg "rg-kd124"
  @base "/subscriptions/#{@sub}/resourceGroups/#{@rg}"

  defp arm_req(method, path, body \\ nil) do
    url = "#{path}?api-version=#{@api_version}"

    conn =
      if body do
        conn(method, url, Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
      else
        conn(method, url)
      end

    Smalt.ArmGateway.Router.call(Plug.Conn.fetch_query_params(conn), [])
  end

  defp ns_key(ns), do: String.downcase("#{@base}/providers/Microsoft.ServiceBus/namespaces/#{ns}")

  defp put_ns(ns) do
    arm_req(:put, "#{@base}/providers/Microsoft.ServiceBus/namespaces/#{ns}", %{
      "location" => "eastus",
      "sku" => %{"name" => "Standard", "tier" => "Standard"},
      "properties" => %{}
    })
  end

  test "first PUT namespace with sku answers 201/202 (never 500) and record is intact" do
    ns = "kd124-#{System.unique_integer([:positive])}"
    conn = put_ns(ns)

    assert conn.status in [201, 202],
           "first PUT with sku answered #{conn.status}: #{inspect(conn.resp_body)}"

    # Record intact after the first PUT (the KD-124 signature: a store must
    # not be followed by a 500).
    get = arm_req(:get, "#{@base}/providers/Microsoft.ServiceBus/namespaces/#{ns}")
    assert get.status == 200
    assert %{"sku" => %{"name" => "Standard"}} = Jason.decode!(get.resp_body)
  end

  test "retry PUT with sku answers 200 (KD-124 second face)" do
    ns = "kd124r-#{System.unique_integer([:positive])}"
    first = put_ns(ns)
    assert first.status in [201, 202]

    retry = put_ns(ns)
    assert retry.status == 200
  end

  test "EH namespace first PUT with sku also never 500s (same seam, EventHub twin)" do
    ns = "kd124eh-#{System.unique_integer([:positive])}"

    conn =
      arm_req(:put, "#{@base}/providers/Microsoft.EventHub/namespaces/#{ns}", %{
        "location" => "eastus",
        "sku" => %{"name" => "Standard", "tier" => "Standard", "capacity" => 1},
        "properties" => %{}
      })

    assert conn.status in [201, 202],
           "first EH PUT with sku answered #{conn.status}: #{inspect(conn.resp_body)}"
  end

  # -- the KD-124 crash face, reproduced: module unavailable post-store -------
  #
  # The wire 500 was `UndefinedFunctionError: module Smalt.EgressRouter.Peers
  # is not available` raised at the post-store emission. We reproduce that
  # exact face by really deleting the module from the code server (no mocks —
  # the collaborator is genuinely absent), then asserting the PUT still
  # answers 202 instead of 500. The module is restored from its on-disk beam.

  test "first PUT still succeeds when Smalt.EgressRouter.Peers is unavailable (KD-124 crash face)" do
    beam_path = :code.which(Smalt.EgressRouter.Peers)
    refute beam_path in [nil, :non_existing]

    on_exit(fn ->
      :code.load_abs(:filename.rootname(beam_path))
    end)

    {:module, _} = :code.ensure_loaded(Smalt.EgressRouter.Peers)
    true = :code.delete(Smalt.EgressRouter.Peers)
    :code.purge(Smalt.EgressRouter.Peers)
    refute function_exported?(Smalt.EgressRouter.Peers, :emit_resource_write_success, 2)

    ns = "kd124gone-#{System.unique_integer([:positive])}"
    conn = put_ns(ns)

    assert conn.status in [201, 202],
           "module-unavailable first PUT answered #{conn.status} (KD-124 defect face was 500): " <>
             inspect(conn.resp_body)

    # The record is still stored and GET renders it (record-intact law).
    get = arm_req(:get, "#{@base}/providers/Microsoft.ServiceBus/namespaces/#{ns}")
    assert get.status == 200

    # Reload for the rest of the suite (restore also re-proven in on_exit).
    assert match?({:module, _}, :code.load_abs(:filename.rootname(beam_path)))
  end

  test "store hygiene: witness keys are unique-per-run, no cross-test coupling" do
    assert Store.get(:smalt_resources, ns_key("never-created")) == :error
  end

  # GL28-2 gate-verdict shape court (lane E1): the gate returns refusals as
  # 3-tuples ({:refused, code, details}); the router's gate-verdict match must
  # render the typed SMALT-* code through the pinned GraphLaw refusal face
  # (400 InvalidResourceShape), never the "unexpected admission-gate verdict"
  # catch-all. Real AdmissionGate collaborator, real in-process dispatch —
  # no mocks. Wave-1 lane-12 finding.
  describe "admission gate 3-tuple refusals" do
    @tag :admission_gate_shape
    test "fail-closed PUT renders the typed gate code, not the catch-all" do
      prev = Application.get_env(:smalt, :graph_law)

      Application.put_env(:smalt, :graph_law, enforcement: :fail_closed)

      try do
        conn =
          put_ns("kd124-gate-shape-#{System.unique_integer([:positive])}")

        assert conn.status == 400,
               "expected 400 InvalidResourceShape, got #{conn.status}: " <>
                 inspect(conn.resp_body)

        body = Jason.decode!(conn.resp_body)

        assert body["error"]["code"] == "InvalidResourceShape"

        assert body["error"]["message"] =~ "smalt_no_receipt",
               "typed gate code must surface in the refusal message, got: " <>
                 inspect(body["error"]["message"])

        refute body["error"]["message"] =~ "unexpected admission-gate verdict"
      after
        if prev, do: Application.put_env(:smalt, :graph_law, prev), else: Application.delete_env(:smalt, :graph_law)
      end
    end
  end
end
