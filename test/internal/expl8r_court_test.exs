# EXPL8-R repair court (v26.10.22, lane EXPL8-R).
#
# Repairs the EXPL-8 findings (docs/jira/v26.10.22/receipts/
# expl8-mcp-sync-receipt-errc.md, tickets E8-T1..T7). Chicago discipline:
# real JSON-RPC over the real router via Plug.Test, real MAA attest face,
# real ETS, real signer. Zero sleeps — all legs are synchronous calls.
#
# Court legs:
#   E8-T1  TTL-vs-descriptor drift fence (fail-closed) + per-tool
#          dispatchability over the real wire face (all TTL tools).
#   E8-T2  MAA nonce table survives its creator process (heir); replay
#          still refused after owner death.
#   E8-T3  hostile policy cannot override the JWT envelope claims
#          (typed reserved_claim refusal).
#   E8-T4  re-authored moduledoc-cited fences: actuation-verb gate +
#          hostile :doctor_supervisor seam, both over the wire.
#   E8-T5  unparseable rules -> typed bad_rule (no widening).
#   E8-T6  a FAILED attestation does not burn the nonce (retry-same-nonce
#          succeeds; consumption recorded only on issue).
#   E8-T7  Sync.Store.commit typed refusals (negative seq, non-binary wire).


defmodule InternalTier.Expl8rRepairCourtTest do
  use ExUnit.Case, async: false

  alias Smalt.Attestation.Maa

  @measurement :crypto.strong_rand_bytes(32)
  @measurement_hex Base.encode16(@measurement, case: :lower)

  setup do
    Maa.reset_nonces!()
    :ok
  end

  # -- wire helpers -------------------------------------------------------------

  defp rpc(method, params, id) do
    body =
      Jason.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params, "id" => id})

    conn =
      Plug.Test.conn(:post, "/", body)
      |> Smalt.Mcp.Router.call([])

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp tool_call(name, args, id),
    do: rpc("tools/call", %{"name" => name, "arguments" => args}, id)

  defp structured(%{"result" => %{"structuredContent" => sc}}), do: sc
  defp structured(body), do: body

  # -- quote helpers -------------------------------------------------------------

  defp quote_bytes(measurement, runtime_json) do
    <<"SMQ1", measurement::binary-size(32), byte_size(runtime_json)::unsigned-integer-size(32),
      runtime_json::binary>>
  end

  defp runtime_data(claims), do: runtime_data_for(@measurement, claims)

  defp runtime_data_for(measurement, claims) do
    json = Jason.encode!(claims)

    %{
      "report" => Base.url_encode64(quote_bytes(measurement, json), padding: false),
      "runtimeData" => %{"data" => Base.encode64(json), "dataType" => "JSON"}
    }
  end

  defp ttl_ids do
    ttl = File.read!("lib/smalt/mcp/gen/smalt_mcp_surface.ttl")

    Regex.scan(~r/ema:capabilityId "([^"]+)"/, ttl)
    |> Enum.map(&Enum.at(&1, 1))
    |> Enum.uniq()
  end

  # -- E8-T1: TTL <-> descriptor drift fence + dispatchability -------------------

  test "E8-T1: TTL capability set == descriptor capability set (drift fence, fail-closed)" do
    ttl_ids = ttl_ids() |> Enum.sort()
    assert ttl_ids != [], "TTL parse found no capabilityIds (premise rot)"

    desc_ids = Smalt.Mcp.Descriptor.capabilities() |> Map.keys() |> Enum.sort()

    assert ttl_ids == desc_ids,
           "MCP descriptor drifted from the TTL surface " <>
             "(ttl-only: #{inspect(ttl_ids -- desc_ids)}, " <>
             "descriptor-only: #{inspect(desc_ids -- ttl_ids)})"

    # tools/list carries the same set over the wire.
    {200, body} = rpc("tools/list", %{}, "expl8r-list")
    wire_ids = body["result"]["tools"] |> Enum.map(& &1["name"]) |> Enum.sort()
    assert wire_ids == ttl_ids
  end

  test "E8-T1: every TTL tool dispatches over the real wire face (no TOOL_NOT_FOUND)" do
    for id <- ttl_ids() do
      {status, body} = tool_call(id, %{}, "expl8r-dispatch-" <> id)

      # A dispatched call may still refuse typed for missing arguments
      # (INVALID_PARAMS) or an empty store — but it must NOT be
      # TOOL_NOT_FOUND / ACTUATION_REFUSED, which is the drift signature.
      sc = structured(body)

      refute sc["code"] == "TOOL_NOT_FOUND", "tool #{id} is unreachable (TOOL_NOT_FOUND)"
      refute sc["code"] == "ACTUATION_REFUSED", "tool #{id} mis-gated as actuation"

      assert status in [200, 400, 500],
             "unexpected wire status #{status} for #{id}: #{inspect(body)}"
    end
  end

  # -- E8-T4: re-authored moduledoc fences ---------------------------------------

  test "E8-T4: actuation verb over the wire -> ACTUATION_REFUSED (re-authored fence)" do
    {_status, body} = tool_call("kv.put", %{"name" => "x"}, "expl8r-actuation")

    assert structured(body)["code"] == "ACTUATION_REFUSED"
  end

  test "E8-T4: hostile :doctor_supervisor seam is read over the wire (re-authored fence)" do
    sentinel =
      "hostile\tchild\u001b[31m-expl8r-" <> Integer.to_string(System.unique_integer([:positive]))

    {:ok, sup} =
      Supervisor.start_link(
        [
          Supervisor.child_spec({Task.Supervisor, name: :expl8r_hostile_child_sup},
            id: sentinel
          )
        ],
        strategy: :one_for_one
      )

    Application.put_env(:smalt, :doctor_supervisor, sup)

    on_exit(fn ->
      Application.delete_env(:smalt, :doctor_supervisor)
      if pid = Process.whereis(:expl8r_hostile_child_sup), do: Process.exit(pid, :kill)
    end)

    {status, body} =
      rpc("tools/call", %{"name" => "doctor.summary", "arguments" => %{}}, "expl8r-doc")

    assert status == 200

    child_ids =
      body["result"]["structuredContent"]["supervisor_children"] |> Enum.map(& &1["id"])

    assert inspect(sentinel) in child_ids,
           "hostile sentinel child id not observed verbatim over the wire"
  end

  # -- E8-T2: nonce registry outlives its creator ---------------------------------

  test "E8-T2: nonce table survives creator-process death; replay still refused" do
    runtime = %{"x-ms-measurement" => @measurement_hex, "nonce" => "expl8r-t2-nonce"}

    task =
      Task.async(fn ->
        assert {:ok, _, _} = Maa.attest("SevSnpVM", runtime_data(runtime))
        :ets.whereis(:smalt_maa_nonces)
      end)

    table_when_created = Task.await(task)

    assert table_when_created != :undefined

    assert :ets.whereis(:smalt_maa_nonces) != :undefined,
           "nonce table died with its creator process (E8-T2 regression)"

    assert {:error, 400, %{"error" => %{"code" => "nonceReplay"}}, _} =
             Maa.attest("SevSnpVM", runtime_data(runtime))
  end

  # -- E8-T6: failed attempt does not burn the nonce -------------------------------

  test "E8-T6: failed attest releases the nonce for a corrected retry; success consumes it" do
    nonce = "expl8r-t6-nonce"
    wrong = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

    assert {:error, 400, %{"error" => %{"code" => "invalidmeasurement"}}, _} =
             Maa.attest(
               "SevSnpVM",
               runtime_data_for(@measurement, %{
                 "x-ms-measurement" => wrong,
                 "nonce" => nonce
               })
             )

    assert {:ok, _, _} =
             Maa.attest(
               "SevSnpVM",
               runtime_data_for(@measurement, %{
                 "x-ms-measurement" => @measurement_hex,
                 "nonce" => nonce
               })
             )

    # Consumed on the SUCCESS path only: a third use is the typed replay refusal.
    assert {:error, 400, %{"error" => %{"code" => "nonceReplay"}}, _} =
             Maa.attest(
               "SevSnpVM",
               runtime_data(%{"x-ms-measurement" => @measurement_hex, "nonce" => nonce})
             )
  end

  # -- E8-T3: envelope claim namespace is provider-controlled -----------------------

  test "E8-T3: hostile policy cannot override iss/exp (typed reserved_claim refusal)" do
    hostile =
      """
      version=1.0; authorizationrules { c:[type=="SevSnpVM"] => permit(); }; issuancerules { c:[type=="SevSnpVM"] => issue(iss="https://evil.example/"); };
      """

    assert {:error, {:policy_refusal, "reserved_claim:iss"}} =
             Maa.evaluate_policy(hostile, %{"type" => "SevSnpVM"})

    hostile_exp =
      """
      version=1.0; authorizationrules { c:[type=="SevSnpVM"] => permit(); }; issuancerules { c:[type=="SevSnpVM"] => issue(exp="never"); };
      """

    assert {:error, {:policy_refusal, "reserved_claim:exp"}} =
             Maa.evaluate_policy(hostile_exp, %{"type" => "SevSnpVM"})
  end

  test "E8-T3: envelope defaults win at the issue_token merge (non-reserved issued claim)" do
    # x-ms-compliance-status is NOT in the reserved namespace, so it parses
    # — but the envelope default must still win at the merge (second layer
    # of the E8-T3 defense, past the parse-time refusal).
    policy =
      """
      version=1.0; authorizationrules { c:[type=="SevSnpVM"] => permit(); }; issuancerules { c:[type=="SevSnpVM"] => issue(x-ms-compliance-status="forged"); };
      """

    assert {:ok, token, claims} =
             Maa.attest(
               "SevSnpVM",
               runtime_data(%{"x-ms-measurement" => @measurement_hex}),
               policy: policy
             )

    assert is_binary(token)
    assert claims["x-ms-compliance-status"] == "azure-compliant-cvm"
  end

  # -- E8-T5: unparseable rule is a typed refusal, never a widening -----------------

  test "E8-T5: unparseable authorization rule -> typed bad_rule (no widening)" do
    # The EXPL-8 probe's exact widening witness: Tpm-only intent (rule 1
    # unparseable, previously silently dropped) must NOT admit SevSnpVM.
    widening =
      """
      version=1.0; authorizationrules { c:[type=="Tpm"] => permit; c:[type=="SevSnpVM"] => permit(); }; issuancerules { c:[type=="SevSnpVM"] => issue(type="sevsnpvm"); };
      """

    assert {:error, {:policy_refusal, "bad_rule"}} =
             Maa.evaluate_policy(widening, %{"type" => "SevSnpVM"})
  end

  test "E8-T5: unparseable issuance rule -> typed bad_rule (fail-closed both sections)" do
    bad_issue =
      """
      version=1.0; authorizationrules { c:[type=="SevSnpVM"] => permit(); }; issuancerules { c:[type=="SevSnpVM"] => issue(type=); };
      """

    assert {:error, {:policy_refusal, "bad_rule"}} =
             Maa.evaluate_policy(bad_issue, %{"type" => "SevSnpVM"})
  end

  # -- E8-T7: Sync.Store.commit typed refusals --------------------------------------

  test "E8-T7: Sync.Store.commit refuses negative seq and non-binary wire typed" do
    assert_raise FunctionClauseError, fn ->
      Smalt.Sync.Store.commit(1, -1, <<1, 2, 3>>)
    end

    assert_raise FunctionClauseError, fn ->
      Smalt.Sync.Store.commit(1, 1, :not_a_binary)
    end

    # Control leg: a well-formed commit still admits (real CAS path).
    client = System.unique_integer([:positive]) |> abs()
    assert {:ok, %{seq: 1}} = Smalt.Sync.Store.commit(client, 1, Jason.encode!(%{"e8t7" => 1}))
  end
end
