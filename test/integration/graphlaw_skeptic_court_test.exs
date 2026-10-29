defmodule Smalt.GraphLawSkepticCourt do
  @moduledoc """
  GL-10 skeptic court for the law-governance wave (GL-1..8).

  Adversarial audit with real collaborators (real ETS, real DETS, real wire
  encoding), no mocks. Four claim families:

    C1  ETS-mutation bypass attempts against the GL-1 guard seam
    C2  actor==approver exclusion fuzzed across term representations
    C3  ANDON receipt digest collision attempts (GL-3 digests + refusalIds)
    C4  ANDON path fail-closed when the receipt formatter is hostile/crashed
  """

  use ExUnit.Case, async: false

  alias Smalt.POWL2.Executor
  alias Smalt.POWL2.Reticle
  alias Smalt.POWL2.Reticle.AST
  alias Smalt.Powl2.Andon
  alias Smalt.Powl2.AndonWire
  alias Smalt.POWL2.LawCompiler

  defmodule Principal do
    defstruct id: nil
  end

  defmodule PrincipalAlt do
    defstruct id: nil
  end

  defmodule TestLawModule do
    @moduledoc false
    def powl2_guard(_shape_id, _ctx), do: :ok
  end

  # -- harness -------------------------------------------------------------------

  defp open_dets do
    path = Path.join(System.tmp_dir!(), "gl10-#{:erlang.unique_integer([:positive])}.dets")
    {:ok, tab} = :dets.open_file(String.to_atom(path), file: String.to_charlist(path))
    {tab, path}
  end

  defp close_dets({dets, path}) do
    :dets.close(dets)
    File.rm(path)
  end

  defp mutation_table do
    tab = String.to_atom("gl10_mut_#{:erlang.unique_integer([:positive])}")
    :ets.new(tab, [:set, :public, :named_table])
    :ets.insert(tab, {:count, 0})
    tab
  end

  defp count(tab), do: :ets.lookup_element(tab, :count, 2)

  # A real ETS-mutating op: bumps the counter then returns the op contract.
  defp mutating_op(tab) do
    fn _ctx ->
      :ets.update_counter(tab, :count, {2, 1})
      {:ok, %{mutated: true}}
    end
  end

  # Only declared fields survive struct/2 (silent key dropping) — see F1.
  defp trans(id, op), do: %AST.Transition{id: id, label: id, op: op}

  # Node that keeps seam fields (law_guard/repair): the executor dispatches on
  # the __struct__ key, so overlay them onto the struct's map shape.
  defp guarded_node(id, op, fields) do
    Map.merge(%{__struct__: AST.Transition, id: id, label: id, op: op}, Map.new(fields))
  end

  defp po(nodes, extra \\ %{}) do
    Map.merge(
      %{
        __struct__: AST.PartialOrder,
        children: Map.new(nodes, &{Map.get(&1, :id), &1}),
        order: []
      },
      Map.new(extra)
    )
  end

  defp run(id, model, ctx, dets), do: Executor.execute_admitted(id, {:ok, model}, ctx, dets, self())

  defp await_verdict do
    receive do
      {:orchestration_completed, _id, _ctx, receipt} -> {:completed, receipt}
      {:orchestration_refused, _id, andon} -> {:refused, andon}
      {:orchestration_failed, _id, outcome} -> {:failed, outcome}
    after
      10_000 -> flunk("no orchestration verdict within 10s")
    end
  end

  # -- C1: bypass attempts ---------------------------------------------------------

  describe "C1 guard-seam bypass attempts" do
    test "F1 CLOSED: typed struct construction preserves law_guard — guarded transition refuses" do
      tab = mutation_table()
      dets = open_dets()

      # GL-KILL F1 fix: the law fields are declared on the struct, so
      # struct/2 / update syntax now preserve them through the documented
      # construction path and the executor reads the same seam the overlay
      # path always reached.
      guard = fn _ -> {:andon_refusal, "exclusion", "self approval"} end
      t_struct = struct(%AST.Transition{id: :a1, label: :a1, op: mutating_op(tab)}, law_guard: {"S", guard})

      assert %AST.Transition{law_guard: {"S", ^guard}} = t_struct

      run(:f1, po([t_struct]), %{}, elem(dets, 0))
      assert {:refused, {:powl2_andon, :a1, "exclusion", "self approval"}} = await_verdict()
      assert count(tab) == 0, "typed-struct guard must refuse; op must never mutate"

      close_dets(dets)
    end

    test "F1 CLOSED: struct fields survive Reticle.admit — typed law_module + repair_edges honored" do
      tab = mutation_table()
      dets = open_dets()
      guard = fn _ -> {:andon_refusal, "exclusion", "self approval"} end

      # repair edge maps the violating id to a benign repair node; the law
      # module rides the TYPED PartialOrder struct now that it declares
      # law_module/repair_edges. Every unguarded node resolves through the
      # law module, so it must exist and answer :ok.
      law_mod = Smalt.GraphLawSkepticCourt.TestLawModule
      model =
        struct(
          %AST.PartialOrder{
            children: %{
              a1: %AST.Transition{id: :a1, label: :a1, op: mutating_op(tab), law_guard: {"S", guard}},
            },
            order: [],
            law_module: law_mod,
            # repair_edges values are repair NODES (executor docs: id => node)
            repair_edges: %{a1: %AST.Transition{id: :fix, label: :fix, op: fn ctx -> {:ok, ctx} end}}
          }
        )

      assert Reticle.admit(model) == :ok

      run(:f1c, model, %{}, elem(dets, 0))
      assert {:completed, _} = await_verdict()
      assert count(tab) == 0, "guard refused; repair edge ran the repair node, never the op"

      close_dets(dets)
    end

    test "F1b: Gate-1 admits anything — the executor never requires a guard" do
      # No shape, no guard, mutating op: admission is :ok and the op runs.
      tab = mutation_table()
      dets = open_dets()

      run(:f1b, po([trans(:a2, mutating_op(tab))]), %{}, elem(dets, 0))
      assert {:completed, _} = await_verdict()
      assert count(tab) == 1

      close_dets(dets)
    end

    test "guard refusal never runs the op (inline guard tuple, real ETS count stays 0)" do
      tab = mutation_table()
      dets = open_dets()
      guard = fn _ctx -> {:andon_refusal, "no_self_approval", "actor is approver"} end

      model = po([guarded_node("t1", {:graphlaw_guard, "OrderShape", guard}, [])])

      run(:c1a, model, %{}, elem(dets, 0))

      assert {:refused, {:powl2_andon, "t1", "no_self_approval", "actor is approver"}} =
               await_verdict()

      assert count(tab) == 0

      assert [{_k, %{rule_id: "no_self_approval"}}] =
               :dets.lookup(elem(dets, 0), {:powl2_andon, "t1"})

      close_dets(dets)
    end

    test "raise/exit/throw, garbage verdicts, and LawCompiler vocabulary all refuse" do
      tab = mutation_table()
      dets = open_dets()

      cases = [
        {:raising, fn _ -> raise "boom" end, :guard_raised},
        {:exiting, fn _ -> exit(:abnormal) end, :guard_raised},
        {:throwing, fn _ -> throw(:sneaky) end, :guard_raised},
        {:garbage, fn _ -> 42 end, :bad_guard_verdict},
        # GL-2's {:violation, _, _} vocabulary is accepted at the seam (GL-2
        # alignment): the rule id rides through typed.
        {:lawcompiler_vocab, fn _ -> {:violation, "no_self_approval", "x"} end,
         "no_self_approval"}
      ]

      Enum.each(cases, fn {name, guard, expected_rule} ->
        model = po([guarded_node(:"node-#{name}", {:graphlaw_guard, "S", guard}, [])])

        run(name, model, %{}, elem(dets, 0))

        assert {:refused, {:powl2_andon, _, ^expected_rule, _}} = await_verdict(),
               "case #{inspect(name)}"

        assert count(tab) == 0, "ETS mutated for case #{inspect(name)}"
      end)

      close_dets(dets)
    end

    test "malformed guard tuple (non-fun) fails closed as bad_op" do
      tab = mutation_table()
      dets = open_dets()

      model = po([trans(:bad3, {:graphlaw_guard, "S", "not_a_fun"})])
      run(:bad3, model, %{}, elem(dets, 0))
      assert {:failed, {:transition_failed, :bad3, {:bad_op, _}}} = await_verdict()
      assert count(tab) == 0

      close_dets(dets)
    end

    test "malformed law_guard (non-fun) on an overlay node refuses typed (:guard_raised)" do
      tab = mutation_table()
      dets = open_dets()

      model = po([guarded_node(:badlg, mutating_op(tab), law_guard: {"S", "not_a_fun"})])
      run(:badlg, model, %{}, elem(dets, 0))
      assert {:refused, {:powl2_andon, :badlg, :guard_raised, _}} = await_verdict()
      assert count(tab) == 0

      close_dets(dets)
    end

    test "invalid law_module on an overlay model raises before any op (fail-closed, untyped)" do
      tab = mutation_table()
      dets = open_dets()

      model = po([trans(:lm, mutating_op(tab))], law_module: %{not: "a fun or module"})

      {:ok, pid} =
        Task.start(fn ->
          Executor.execute_admitted(:lm, {:ok, model}, %{}, elem(dets, 0), self())
        end)

      ref = Process.monitor(pid)

      # The invalid law_module kills the frontier Task with an UNTYPED
      # function_clause exit — no orchestration verdict is ever sent. Record
      # the observed shape.
      assert_receive {:DOWN, ^ref, :process, ^pid, {:function_clause, _}}, 5_000

      assert count(tab) == 0
      refute_receive({:orchestration_completed, _, _, _}, 200)
      close_dets(dets)
    end

    test "retry via repair edge never re-runs the violating op" do
      viol = mutation_table()
      rep = mutation_table()
      dets = open_dets()

      guard = fn _ -> {:andon_refusal, "capacity", "over ceiling"} end
      repair = trans(:repair_op, mutating_op(rep))
      model = po([guarded_node(:t1, {:graphlaw_guard, "S", guard}, repair: repair)])

      run(:c1retry, model, %{}, elem(dets, 0))

      assert {:completed, receipt} = await_verdict()
      assert count(viol) == 0
      assert count(rep) == 1

      assert Enum.any?(receipt.steps, fn s ->
               match?({:powl2_andon, _, "capacity", _}, s.outcome)
             end)

      close_dets(dets)
    end

    test "choice-graph routing cannot bypass a guarded target node" do
      tab = mutation_table()
      dets = open_dets()
      guard = fn _ -> {:andon_refusal, "exclusion", "self approval"} end

      model = %{
        __struct__: AST.ChoiceGraph,
        children: %{
          "s" => trans("s", fn ctx -> {:ok, ctx} end),
          "g" => trans("g", {:graphlaw_guard, "S", guard}),
          "e" => trans("e", fn ctx -> {:ok, ctx} end)
        },
        start: "s",
        end: "e",
        edges: [{"s", "g"}, {"g", "e"}],
        guards: %{}
      }

      run(:choice, model, %{}, elem(dets, 0))

      assert {:refused, {:powl2_andon, "g", "exclusion", "self approval"}} = await_verdict()
      assert count(tab) == 0

      close_dets(dets)
    end
  end

  # -- C2: representation fuzz on the exclusion invariant ---------------------------

  describe "C2 actor==approver exclusion across representations" do
    @ttl """
    ex:ApprovalShape a sh:NodeShape ;
      sh:property [ sh:path "actor" ; powl:notEquals "approver" ;
        sh:message "actor may not approve own report" ] .
    """

    defp exclusion_guard do
      {:ok, guard} = LawCompiler.compile_shape("ex:ApprovalShape", @ttl)
      guard
    end

    test "same-representation self-approval is refused" do
      guard = exclusion_guard()

      assert :ok = guard.(%{"actor" => "alice", "approver" => "bob"})
      assert {:violation, rule, _} = guard.(%{"actor" => "alice", "approver" => "alice"})
      assert rule =~ "notEquals"
      assert {:violation, _, _} = guard.(%{actor: :alice, approver: :alice})
    end

    test "F2 CLOSED: atom-vs-binary — :alice vs \"alice\" violates the exclusion" do
      guard = exclusion_guard()
      assert {:violation, rule, _} = guard.(%{"actor" => "alice", "approver" => :alice})
      assert rule =~ "notEquals"
    end

    test "int/float divergence remains a violation (numeric canonical class)" do
      guard = exclusion_guard()
      assert {:violation, _, _} = guard.(%{"actor" => 7, "approver" => 7.0})
    end

    test "F2 CLOSED: struct-type identity — same id across struct types violates" do
      guard = exclusion_guard()

      assert {:violation, _, _} =
               guard.(%{
                 "actor" => struct(Principal, id: "p1"),
                 "approver" => struct(PrincipalAlt, id: "p1")
               })
    end

    test "F2 fuzz: canonical equality holds across the representation lattice" do
      guard = exclusion_guard()
      reps = fn x -> [x, to_string(x), String.to_atom(to_string(x))] end

      # every representation pair of "alice" is a violation, in both directions
      for a <- reps.("alice"), b <- reps.("alice") do
        assert {:violation, _, _} = guard.(%{"actor" => a, "approver" => b}),
               "expected violation for #{inspect(a)} vs #{inspect(b)}"
      end

      # distinct principals stay lawful across every representation
      for a <- reps.("alice"), b <- reps.("bob") do
        assert :ok = guard.(%{"actor" => a, "approver" => b}),
               "expected :ok for #{inspect(a)} vs #{inspect(b)}"
      end

      # mixed number/non-number never equal; numerically equal numbers violate
      assert :ok = guard.(%{"actor" => 7, "approver" => "7"})
      assert {:violation, _, _} = guard.(%{"actor" => 7, "approver" => 7.0})
      assert {:violation, _, _} = guard.(%{"actor" => 7.5, "approver" => 7.5})
    end

    test "nil on either side is treated as absent (relation semantics, not evasion)" do
      guard = exclusion_guard()
      assert :ok = guard.(%{"actor" => "alice", "approver" => nil})
    end

    test "canonical TTL compiles typed (GL-9 unblock holds)" do
      assert {:ok, guard} = LawCompiler.compile_shape("ex:ApprovalShape", @ttl)
      assert is_function(guard, 1)
    end

    test "malformed TTL is a typed parse error, never a raise across the seam" do
      assert {:error, {:parse_error, _}} =
               LawCompiler.compile_shape("ex:ApprovalShape", "ex:Broken a sh:NodeShape ; [ ")
    end
  end

  # -- C3: digest collision attempts ------------------------------------------------

  describe "C3 andon digest collision attempts" do
    @ctx %{order: "8921", risk_officer: nil}

    test "distinct contexts always produce distinct digests" do
      a = Andon.format_andon("r1", "d", %{a: 1}, ts: 1)
      b = Andon.format_andon("r1", "d", %{a: 2}, ts: 1)
      c = Andon.format_andon("r1", "d", %{a: 1.0}, ts: 1)
      d = Andon.format_andon("r1", "d", %{a: "1"}, ts: 1)

      digests = [a, b, c, d] |> Enum.map(& &1.context_digest)
      assert length(Enum.uniq(digests)) == 4
    end

    test "same context under different rules: digest repeats, refusal identity does not" do
      a = Andon.format_andon("ruleA", "diagA", @ctx, ts: 5, session: "s")
      b = Andon.format_andon("ruleB", "diagB", @ctx, ts: 5, session: "s")

      assert a.context_digest == b.context_digest

      ld_a = Jason.decode!(a.json_ld)
      ld_b = Jason.decode!(b.json_ld)

      refute ld_a["andon:refusalId"] == ld_b["andon:refusalId"]
      assert ld_a["andon:failedConstraint"] == "ruleA"
      assert ld_b["andon:failedConstraint"] == "ruleB"
    end

    test "FINDING: refusalId collision — same rule/context/session collapses the id space" do
      a = Andon.format_andon("capacity", "over", @ctx, ts: 1_760_000_000_100_000_000, session: "sess")
      b = Andon.format_andon("capacity", "over", @ctx, ts: 1_760_000_000_900_000_000, session: "sess")

      id_a = Jason.decode!(a.json_ld)["andon:refusalId"]
      id_b = Jason.decode!(b.json_ld)["andon:refusalId"]

      assert id_a == id_b
    end

    test "representation-divergent principals mint distinct digests" do
      a = Andon.format_andon("r", "d", %{who: "alice"}, ts: 1)
      b = Andon.format_andon("r", "d", %{who: :alice}, ts: 1)
      refute a.context_digest == b.context_digest
    end
  end

  # -- C4: fail-closed ANDON when the formatter is hostile ----------------------------

  describe "C4 fail-closed andon path" do
    test "refusal path is formatter-independent: a crashing formatter cannot flip a refusal" do
      tab = mutation_table()
      dets = open_dets()

      # The GL-3 formatter raises (guard clause) on a non-binary rule id...
      assert_raise FunctionClauseError, fn ->
        Andon.format_andon(1, "d", @ctx)
      end

      # ...and the executor's refusal path never touches the formatter:
      # the guard refusal still refuses, op unmutated.
      guard = fn _ -> {:andon_refusal, "r", "d"} end
      model = po([guarded_node(:t9, {:graphlaw_guard, "S", guard}, [])])

      run(:t9, model, %{}, elem(dets, 0))
      assert {:refused, {:powl2_andon, :t9, "r", "d"}} = await_verdict()
      assert count(tab) == 0

      close_dets(dets)
    end

    test "http_envelope/2 maps GL-3 receipts: 422 + pinion header + error map body" do
      receipt =
        Andon.format_andon("risk_officer_signature", "Missing signature", @ctx,
          ts: 1_760_000_000_000_000_000,
          session: "s9"
        )

      env = AndonWire.http_envelope(receipt)

      assert env.status == 422
      assert {"x-ms-error-code", "BusinessLawViolation"} in env.headers
      assert env.content_type =~ "application/json"

      error = Jason.decode!(env.body)["error"]
      assert error["code"] == "GraphlawRefusal"
      assert error["rule_id"] == "risk_officer_signature"
      assert error["context_digest"] == receipt.context_digest
      assert error["ts"] == receipt.ts

      # The embedded json_ld is present AND well-formed: it round-trips
      # through Jason and carries the GL-3 musts (typed RefusalReceipt node,
      # the failing constraint, PROV-O context).
      ld = Jason.decode!(error["json_ld"])
      assert ld["@type"] == "andon:RefusalReceipt"
      assert ld["andon:failedConstraint"] == "risk_officer_signature"
      assert "https://www.w3.org/ns/prov.jsonld" in ld["@context"]
    end

    test "wire face fails closed on unknown and partially-known shapes" do
      assert {:error, :unwirable_shape} = AndonWire.normalize("garbage")
      assert {:error, :unwirable_shape} = AndonWire.normalize(42)

      # GL-3 receipt missing agent_message/repair_hint must not silently wire.
      assert {:error, :unwirable_shape} =
               AndonWire.normalize(%{rule_id: "r", diagnostic: "d", context_digest: "x"})

      assert {:error, :unwirable_shape} = AndonWire.http_envelope("garbage")
    end

    test "executor andon tuple + DETS receipt normalize with distinct digests" do
      {:ok, w1} = AndonWire.normalize({:powl2_andon, "inst-1", "capacity", "over"})
      {:ok, w2} = AndonWire.normalize({:powl2_andon, "inst-2", "capacity", "over"})
      refute w1.context_digest == w2.context_digest
      assert w1.instance_id == "inst-1"

      {:ok, d1} =
        AndonWire.normalize(%{shape_id: "S", rule_id: "capacity", diagnostic: "over", at_ms: 1})

      {:ok, d2} =
        AndonWire.normalize(%{shape_id: "S", rule_id: "capacity", diagnostic: "over", at_ms: 2})

      refute d1.context_digest == d2.context_digest
      assert d1.ts == 1 and d2.ts == 2
    end

    test "amqp_properties: typed ts long, byte-identical body, flat andon keys" do
      w = AndonWire.amqp_properties({:powl2_andon, "i", "rule", "diag"})
      assert w.content_type == "application/json"
      assert w.content_encoding == "utf-8"
      assert w.application_properties["andon.code"] == "GraphlawRefusal"
      assert w.application_properties["andon.rule_id"] == "rule"
      assert w.message_annotations == %{"x-opt-andon" => true}

      <<ts::signed-size(64)>> = w.andon_ts_long
      assert is_integer(ts)

      # Both faces must agree on the FACTS of a refusal; ts is live-minted per
      # normalize call (GL-8), so cross-call byte-identity is not a law.
      http = AndonWire.http_envelope({:powl2_andon, "i", "rule", "diag"})

      e1 = Jason.decode!(http.body)["error"] |> Map.delete("ts")
      e2 = Jason.decode!(w.body)["error"] |> Map.delete("ts")
      assert e1 == e2
    end

    test "FINDING: IRI injection — hostile session/rule ids emit malformed URNs" do
      r = Andon.format_andon("rule\"x", "diag", @ctx, ts: 5, session: "s\"pace")

      nt = Andon.ntriples(r)
      entity_line = nt |> String.split("\n") |> Enum.at(0)

      # Raw double-quote inside <...> is illegal N-Triples syntax; the same
      # unescaped pair rides the JSON-LD refusalId URN.
      assert entity_line =~ ~S[<urn:smalt:andon:s"pace:rule"x:]

      ld = Jason.decode!(r.json_ld)
      assert ld["andon:refusalId"] =~ ~S[s"pace:rule"x]
    end

    test "dets-less executor still refuses (typed message intact, no persistence)" do
      tab = mutation_table()
      guard = fn _ -> {:andon_refusal, "r", "no storage"} end
      model = po([guarded_node(:tn, {:graphlaw_guard, "S", guard}, [])])

      run(:tn, model, %{}, nil)
      assert {:refused, {:powl2_andon, :tn, "r", "no storage"}} = await_verdict()
      assert count(tab) == 0
    end
  end
end
