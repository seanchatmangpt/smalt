defmodule Smalt.Powl2.AndonWireCourtTest do
  use ExUnit.Case, async: false

  # GL-8 wire-face court for `Smalt.Powl2.AndonWire`. Chicago: real
  # collaborators everywhere — a real GL-3 `Smalt.Powl2.Andon` receipt, a
  # real GL-1 executor run over a real DETS table, and a real Bandit HTTP
  # server on a kernel-assigned port serving a guarded mini-route. No mocks;
  # assertions are on wire bytes and final store state.
  #
  # NOTE: GL-3's `Smalt.Powl2.Andon` was mid-rewrite on the shared tree
  # while this court was authored (json_ld/agent_message clause churn);
  # assertions here depend only on the documented surface (format_andon/4,
  # agent_message/3, receipt fields), not the in-flight clauses.

  alias Smalt.Powl2.Andon
  alias Smalt.Powl2.AndonWire
  alias Smalt.POWL2.Executor
  alias Smalt.POWL2.Reticle.AST.PartialOrder
  alias Smalt.POWL2.Reticle.AST.Transition

  @transition Transition
  @partial_order PartialOrder

  # -- fixtures --------------------------------------------------------------

  defp t(id, op, extra \\ %{}) do
    Map.merge(%{__struct__: @transition, id: id, label: Atom.to_string(id), op: op}, extra)
  end

  defp open_dets(name) do
    table = String.to_atom("powl_gl8_#{name}_#{System.unique_integer([:positive])}")
    path = Path.join(System.tmp_dir!(), "#{table}.dets")
    {:ok, ^table} = :dets.open_file(table, file: String.to_charlist(path))
    on_exit(fn ->
      File.rm(path)
      :ok
    end)
    table
  end

  # A real GL-1 law guard: refusal unless the plan is signed.
  defp signature_guard do
    fn ctx ->
      if ctx[:risk_officer_signed] do
        :ok
      else
        {:andon_refusal, :risk_officer_signature, "missing Risk Officer signature"}
      end
    end
  end

  defp guarded_model do
    %{
      __struct__: @partial_order,
      id: :wire_model,
      children: %{
        commit:
          t(:commit, {:graphlaw_guard, :risk_shape, signature_guard(), fn ctx -> {:ok, ctx} end})
      },
      order: []
    }
  end

  # -- HTTP envelope over a GL-3 Andon receipt -------------------------------

  test "http_envelope serializes a GL-3 receipt to a 422 GraphlawRefusal envelope" do
    receipt =
      Andon.format_andon(
        "risk_officer_signature",
        "missing Risk Officer signature",
        %{order: "8921"},
        ts: 1_700_000_000_000_000_000,
        session: "gl8@node"
      )

    env = AndonWire.http_envelope(receipt)

    assert env.status == 422
    assert env.content_type == "application/json; charset=utf-8"

    assert %{"error" => err} = Jason.decode!(env.body)
    assert err["code"] == "GraphlawRefusal"
    assert err["rule_id"] == "risk_officer_signature"
    assert err["diagnostic"] == "missing Risk Officer signature"
    assert err["context_digest"] == receipt.context_digest
    assert err["session"] == "gl8@node"
    assert err["ts"] == 1_700_000_000_000_000_000
    assert err["agent_message"] =~ "[ANDON risk_officer_signature]"
    assert err["repair_hint"] =~ "Risk Officer signature"
  end

  test "amqp_properties carries typed fields and a byte-identical body to the HTTP face" do
    receipt =
      Andon.format_andon(
        "order_capacity",
        "order exceeds tick capacity",
        %{order: "8921"},
        ts: 1_700_000_000_000_000_001,
        session: "gl8@node"
      )

    env = AndonWire.http_envelope(receipt)
    amqp = AndonWire.amqp_properties(receipt)

    assert amqp.body == env.body
    assert amqp.content_type == "application/json"
    assert amqp.content_encoding == "utf-8"
    assert amqp.message_annotations == %{"x-opt-andon" => true}

    props = amqp.application_properties
    assert props["andon.code"] == "GraphlawRefusal"
    assert props["andon.rule_id"] == "order_capacity"
    assert props["andon.diagnostic"] == "order exceeds tick capacity"
    assert is_binary(props["andon.agent_message"])
    assert is_binary(props["andon.repair_hint"])
    assert props["andon.context_digest"] == receipt.context_digest
    assert props["andon.session"] == "gl8@node"

    # AMQP long round-trip: the ts survives as a signed 64-bit integer.
    <<ts::signed-size(64)>> = amqp.andon_ts_long
    assert ts == 1_700_000_000_000_000_001
  end

  # -- normalization of the GL-1 executor shapes ------------------------------

  test "normalizes the executor andon tuple; digest commits to refusal identity" do
    {:ok, wr} = AndonWire.normalize({:powl2_andon, :inst7, :r42, "worm container locked"})

    assert wr.code == "GraphlawRefusal"
    assert wr.rule_id == "r42"
    assert wr.diagnostic == "worm container locked"
    assert wr.instance_id == "inst7"
    assert is_integer(wr.ts)
    assert String.length(wr.context_digest) == 64

    # Deterministic and shape-committed: same tuple -> same digest; a
    # different instance id or diagnostic -> a different digest.
    {:ok, wr2} = AndonWire.normalize({:powl2_andon, :inst7, :r42, "worm container locked"})
    {:ok, wr3} = AndonWire.normalize({:powl2_andon, :inst8, :r42, "worm container locked"})
    assert wr.context_digest == wr2.context_digest
    refute wr.context_digest == wr3.context_digest
  end

  test "normalizes the executor DETS receipt (shape_id present, ts from at_ms)" do
    dets_receipt = %{
      shape_id: :risk_shape,
      rule_id: :risk_officer_signature,
      diagnostic: "missing signature",
      at_ms: 1_700_000_000_123,
      at_rel_ms: 12
    }

    {:ok, wr} = AndonWire.normalize(dets_receipt)
    assert wr.shape_id == "risk_shape"
    assert wr.ts == 1_700_000_000_123

    env = AndonWire.http_envelope(dets_receipt)
    assert env.status == 422
    assert %{"error" => err} = Jason.decode!(env.body)
    assert err["shape_id"] == "risk_shape"
    assert err["ts"] == 1_700_000_000_123
  end

  test "fails closed on shapes it cannot wire" do
    assert {:error, :unwirable_shape} = AndonWire.normalize(%{unrelated: true})
    assert {:error, :unwirable_shape} = AndonWire.normalize(:ok)
    assert {:error, :unwirable_shape} = AndonWire.http_envelope({:not_an_andon, 1})
    assert {:error, :unwirable_shape} = AndonWire.amqp_properties(%{"rule_id" => "string-keys"})
  end

  # -- wire witness: guarded mini-route over real HTTP ------------------------

  defmodule WireWitness do
    @moduledoc false
    use Plug.Router

    plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
    plug(:match)
    plug(:dispatch)

    # Runs a real GL-1-guarded transition: the plan id keys a persistent_term
    # handle to {dets, model, store}. The request body supplies the guard
    # fact (`signed`). Refusal -> 422 ANDON envelope on the wire; conforming
    # -> 200. The executor's caller message is drained in-process.
    post "/plans/:id/transition" do
      {dets, model, store} = :persistent_term.get({:gl8_wire, id})
      ctx = %{risk_officer_signed: conn.body_params["signed"] == true}

      verdict = Smalt.POWL2.Executor.execute_admitted(id, {:ok, model}, ctx, dets, self())

      receive do
        _ -> :ok
      after
        0 -> :ok
      end

      case verdict do
        :ok ->
          conn
          |> put_resp_header("content-type", "application/json; charset=utf-8")
          |> send_resp(200, Jason.encode!(%{"status" => "completed", "plan" => id}))

        {:error, {:powl2_andon, _, _, _} = andon} ->
          env = Smalt.Powl2.AndonWire.http_envelope(andon)

          conn
          |> put_resp_header("content-type", env.content_type)
          |> send_resp(env.status, env.body)

        {:error, other} ->
          conn
          |> put_resp_header("content-type", "application/json; charset=utf-8")
          |> send_resp(400, Jason.encode!(%{"error" => %{"code" => "BadRequest", "detail" => inspect(other)}}))
      end
    end
  end

  test "wire witness: violating proposal -> 422 ANDON envelope; conforming -> 200" do
    dets = open_dets(:wire)
    store = :ets.new(:gl8_wire_store, [:set, :public])

    model = %{
      __struct__: @partial_order,
      id: :wire_plan,
      children: %{
        commit:
          t(:commit, {:graphlaw_guard, :risk_shape, signature_guard(),
                     fn _ctx ->
                       :ets.insert(store, {:committed, true})
                       {:ok, %{}}
                     end})
      },
      order: []
    }

    :persistent_term.put({:gl8_wire, "wire_plan"}, {dets, model, store})
    on_exit(fn -> :persistent_term.erase({:gl8_wire, "wire_plan"}); :ok end)

    server = start_supervised!({Bandit, plug: WireWitness, scheme: :http, port: 0})
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    :inets.start()

    url = ~c"http://127.0.0.1:#{port}/plans/wire_plan/transition"

    # Violating proposal: unsigned. The guard refuses, the op never runs,
    # and the refusal crosses the wire as a 422 ANDON envelope.
    violating = {url, [], ~c"application/json", Jason.encode!(%{"signed" => false})}
    {:ok, {{_v, 422, _reason}, _headers, body}} = :httpc.request(:post, violating, [], [])
    assert %{"error" => err} = Jason.decode!(IO.iodata_to_binary(body))
    assert err["code"] == "GraphlawRefusal"
    assert err["rule_id"] == "risk_officer_signature"
    assert err["diagnostic"] == "missing Risk Officer signature"
    assert is_binary(err["context_digest"]) and String.length(err["context_digest"]) == 64
    assert err["repair_hint"] =~ "resubmit"
    assert :ets.tab2list(store) == []

    # Same request with the fact satisfied: guard passes, op runs, 200.
    conforming = {url, [], ~c"application/json", Jason.encode!(%{"signed" => true})}
    {:ok, {{_v2, 200, _reason2}, _headers2, body2}} = :httpc.request(:post, conforming, [], [])
    assert %{"status" => "completed", "plan" => "wire_plan"} = Jason.decode!(IO.iodata_to_binary(body2))
    assert :ets.lookup(store, :committed) == [{:committed, true}]
  end
end
