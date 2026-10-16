defmodule Smalt.AdmissionProjectionTest do
  use ExUnit.Case, async: false

  alias Smalt.Auth.Bearer
  alias Smalt.DataPlane.SKR
  alias Smalt.GraphLaw.Validator
  alias Smalt.Ocel.DeviationAdmission
  alias Smalt.Projection.Admission
  alias Smalt.Store
  alias Smalt.Telemetry

  @tmp_dir Path.join(["tmp", "ocel", "admission-projection-test"])

  setup do
    # The telemetry handler table lives in the :telemetry app; standalone
    # runs of this suite (--no-start) previously only worked when another
    # lane suite had booted :smalt first — latent ordering defect (lens-2
    # cycle 3).
    {:ok, _} = Application.ensure_all_started(:telemetry)

    case Store.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case Telemetry.RollingCounters.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok = Admission.attach()
    :ok = Admission.reset()

    on_exit(fn ->
      :telemetry.detach("smalt-admission-projection")
      File.rm_rf(@tmp_dir)
    end)

    :ok
  end

  defp empty_conn(headers \\ []) do
    %Plug.Conn{req_headers: headers}
  end

  test "graphlaw verdicts project into the matrix with real shape evaluation" do
    shape = %{
      target_class: nil,
      closed: false,
      required: [%{path: "location", min_count: 1, datatype: nil, message: nil}]
    }

    admit_row =
      Admission.seed(
        :graphlaw,
        "Microsoft.Compute/virtualMachines",
        Validator.validate_shape(shape, %{"location" => "eastus"})
      )

    assert %{family: :graphlaw, verdict: :admit, standing: :admitted, code: nil} = admit_row

    {:invalid, violations} = Validator.validate_shape(shape, %{})

    refuse_row =
      Admission.seed(:graphlaw, "Microsoft.Compute/virtualMachines", {:invalid, violations})

    assert refuse_row.verdict == :refuse
    assert refuse_row.standing == :unknown
    assert refuse_row.code in ["minCount", "SHAPE_INVALID"]
  end

  test "skr admission projects release admit and typed refusals" do
    # Real surface call: a key that was never put is a 404 KeyNotFound refusal.
    {:error, 404, body} = SKR.release("no-such-key-#{System.unique_integer()}", empty_conn())

    refuse_row = Admission.seed(:skr, "no-such-key", {:error, 404, body})
    assert %{family: :skr, verdict: :refuse, standing: :unknown, code: "KeyNotFound"} = refuse_row

    admit_row = Admission.seed(:skr, "k", {:ok, 200, %{"value" => "released"}})
    assert %{verdict: :admit, standing: :admitted} = admit_row
  end

  test "auth bearer refusals project with typed codes" do
    {:refuse, code, reason} = Bearer.verify_bearer(empty_conn())

    row = Admission.seed(:auth, "/egress/x", {:refuse, code, reason})
    assert %{family: :auth, verdict: :refuse, standing: :unknown, code: "AuthenticationFailed"} =
             row

    # The :ok contract projects on the same verdict axis.
    assert %{verdict: :admit} = Admission.seed(:auth, "/egress/y", :ok)
  end

  test "ledger deviation admission projects admit/deviation/refuse rows and from_store replays" do
    path = Path.join(@tmp_dir, "dev-#{System.unique_integer([:positive])}.jsonl")

    # conforms -> admit
    assert %{verdict: :admit} =
             Admission.seed(
               :ledger_deviation,
               "ref/cand",
               DeviationAdmission.admit(%{conforms: true, fitness: 1.0, deviations: []},
                 path: path
               )
             )

    # deviation admitted into evidence
    {:ok, record_id} =
      result =
      DeviationAdmission.admit(
        %{conforms: false, fitness: 0.4, deviations: [["join_gate", "approve_gate"]]},
        path: path,
        reference_trace_id: "reference",
        candidate_trace_id: "candidate"
      )

    assert %{verdict: :deviation, standing: :admitted} =
             Admission.seed(:ledger_deviation, "reference/candidate", result)

    # contract violation -> refuse
    assert %{verdict: :refuse, code: :no_deviation} =
             Admission.seed(
               :ledger_deviation,
               "ref/cand",
               DeviationAdmission.admit(%{conforms: false, fitness: 0.5, deviations: []},
                 path: path
               )
             )

    # Durable ledger replays into the matrix, idempotently.
    rows = Admission.from_store(path)
    assert [%{id: "ledger_deviation:" <> _} = deviation_row] = rows
    assert deviation_row.verdict == :deviation
    assert deviation_row.code == "join_gate/approve_gate"

    assert ^deviation_row = hd(Admission.from_store(path))
    assert deviation_row.id == "ledger_deviation:" <> record_id
  end

  test "from_store boundary fuzz: malformed ledger raises typed ArgumentError, enoent is empty" do
    # Class parity with SemanticEpoch (cycle-3/4): DeviationAdmission.read_all/1
    # decodes with Jason.decode!/1; the projection must adapt the raise, not
    # leak it.
    dir = Path.join(System.tmp_dir!(), "smalt-adm-fuzz-#{System.system_time(:native)}")
    File.mkdir_p!(dir)
    malformed = Path.join(dir, "deviations.jsonl")
    File.write!(malformed, "{\"id\": \"x\"\n{not json\n")

    assert_raise ArgumentError, ~r/malformed deviation ledger/, fn ->
      Admission.from_store(malformed)
    end

    # enoent -> read_all {:ok, []} -> empty matrix projection, no raise.
    assert [] = Admission.from_store(Path.join(dir, "nope.jsonl"))

    # Lens-2 cycle 5: tampered ledger record without a binary id -> typed
    # ArgumentError, never "arg" <> nil crash with ArgumentError leaking
    # raw. (Pre-fix kill: ArgumentError from binary concat, message lacks
    # the identity refusal.)
    File.write!(malformed, ~s({"id": null, "referenceTraceId": "r"}\n))
    assert_raise ArgumentError, ~r/malformed_ledger_identity/, fn ->
      Admission.from_store(malformed)
    end

    # Real ledger admission + projection round-trip still works after fuzz.
    {:ok, _} =
      DeviationAdmission.admit(
        %{conforms: false, fitness: 0.5, deviations: [["loop", "skip"]]},
        path: Path.join(dir, "real.jsonl"),
        reference_trace_id: "r-fuzz",
        candidate_trace_id: "c-fuzz"
      )

    assert [%{verdict: :deviation, code: "loop/skip"}] = Admission.from_store(Path.join(dir, "real.jsonl"))
    File.rm_rf!(dir)
  end

  # Lens-3 cycle 1: the empty string IS a binary. Before the fence, two
  # blank-id records both mapped to row key "ledger_deviation:" and the
  # second silently overwrote the first (measured: returned_rows had both
  # codes, stored_rows held only "move_b"). Refused on the same
  # malformed_ledger_identity axis as a null id.
  test "from_store fuzz: blank-string ledger ids are refused, no silent row collision" do
    dir = Path.join(System.tmp_dir!(), "smalt-adm-blank-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "deviations.jsonl")

    rec = fn id, move ->
      Jason.encode!(%{
        "id" => id,
        "referenceTraceId" => "r",
        "candidateTraceId" => "c",
        "deviatingMove" => move,
        "timestamp" => "t"
      })
    end

    File.write!(path, Enum.join([rec.("", "move_a"), rec.("", "move_b")], "\n"))

    assert_raise ArgumentError, ~r/malformed_ledger_identity/, fn ->
      Admission.from_store(path)
    end

    # Mixed null/blank/real: refused wherever the vacuous identity sits.
    File.write!(path, Enum.join([rec.("ok1", "m1"), rec.(nil, "m2")], "\n"))

    assert_raise ArgumentError, ~r/malformed_ledger_identity/, fn ->
      Admission.from_store(path)
    end

    # Real ids still project, one row per record, no collision.
    File.write!(path, Enum.join([rec.("id1", "m1"), rec.("id2", "m2")], "\n"))
    rows = Admission.from_store(path)
    assert Enum.map(rows, & &1.id) == ["ledger_deviation:id1", "ledger_deviation:id2"]

    # Lens-3 cycle 3 (M6 gap): a SINGLE blank id — the dup fence cannot be
    # the refuser here (one record cannot duplicate), so the blank guard
    # itself must fire.
    File.write!(path, rec.("", "only"))
    assert_raise ArgumentError, ~r/malformed_ledger_identity/, fn ->
      Admission.from_store(path)
    end

    File.rm_rf!(dir)
  end

  # Lens-3 cycle 3: duplicate NON-blank ids hit the same key collision as
  # the blank-id class — measured: from_store returned 2 rows but the
  # matrix stored only the LAST ("move_b"); the first admission silently
  # lost. Refused typed.
  test "from_store fuzz: duplicate ledger ids are refused, no silent row loss" do
    dir = Path.join(System.tmp_dir!(), "smalt-adm-dup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "deviations.jsonl")

    rec = fn id, move ->
      Jason.encode!(%{
        "id" => id,
        "referenceTraceId" => "r",
        "candidateTraceId" => "c",
        "deviatingMove" => move,
        "timestamp" => "t"
      })
    end

    File.write!(path, Enum.join([rec.("dup", "move_a"), rec.("dup", "move_b")], "\n"))

    assert_raise ArgumentError, ~r/duplicate_ledger_identity/, fn ->
      Admission.from_store(path)
    end

    File.rm_rf!(dir)
  end

  # Lens-5 cycle 4: a valid-JSON NON-MAP ledger line (array/string) through
  # the producer boundary previously crashed from_store out of Access on
  # `& &1["id"]`. Refused typed on the malformed-ledger axis, never a crash.
  test "from_store fuzz: non-map JSONL line refuses typed, never crashes" do
    dir = Path.join(System.tmp_dir!(), "smalt-adm-nonmap-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "deviations.jsonl")

    rec = %{
      "id" => "d1",
      "referenceTraceId" => "r",
      "candidateTraceId" => "c",
      "deviatingMove" => "m",
      "timestamp" => "t"
    }

    File.write!(path, Jason.encode!(rec) <> "\n[1,2]\n")

    assert_raise ArgumentError, ~r/malformed_ledger_record/, fn ->
      Admission.from_store(path)
    end

    File.rm_rf!(dir)
  end

  # Lens-4 cycle 1: this test was order-dependent — Telemetry.dump() is a
  # CUMULATIVE global counter while Admission.counts() is reset per test, so
  # `counts == dump_sum` held only when no earlier test in the shuffled run
  # had emitted admit/refuse telemetry (measured: 2 vs 27 once the lens-4
  # modules changed the shuffle). Compare deltas instead.
  defp telemetry_total(dump, event) do
    dump
    |> Enum.filter(fn
      # Enum over the dump map yields {key, count}; smalt-native keys are
      # {[:smalt, event], metadata} 2-tuples.
      {{[:smalt, ^event], _meta}, _n} -> true
      # Bandit keys are 3-tuples {:bandit_request_stop, route, status} (route/
      # status may be nil) or the 2-tuple {:bandit_request_stop, :error} — not
      # {name, meta} pairs. Catch-all, never a FunctionClauseError.
      _ -> false
    end)
    |> Enum.map(fn {_k, n} -> n end)
    |> Enum.sum()
  end

  test "verdict counter-aggregation matches Telemetry.dump() where overlapping" do
    before_admits = telemetry_total(Telemetry.dump(), :admit)
    before_refuses = telemetry_total(Telemetry.dump(), :refuse)

    Telemetry.admit(:ok, route: "/arm/shapes")
    Telemetry.admit(:ok, route: "/arm/shapes")
    Telemetry.refuse(:SHAPE_INVALID, code: :SHAPE_INVALID, route: "/egress/x")
    Telemetry.refuse(:UNAUTHORIZED_ROUTE, code: :UNAUTHORIZED_ROUTE, route: "/egress/y")

    counts = Admission.counts()

    # Every telemetry event produced exactly one matrix row (matrix is
    # reset per-test in setup).
    assert counts[{:smalt_event, :admit}] == 2
    assert counts[{:smalt_event, :refuse}] == 2

    dump = Telemetry.dump()

    assert counts[{:smalt_event, :admit}] == telemetry_total(dump, :admit) - before_admits
    assert counts[{:smalt_event, :refuse}] == telemetry_total(dump, :refuse) - before_refuses
  end

  test "matrix is one typed stream across all four families" do
    shape = %{
      target_class: nil,
      closed: false,
      required: [%{path: "location", min_count: 1, datatype: nil, message: nil}]
    }

    Admission.seed(:graphlaw, "t1", Validator.validate_shape(shape, %{"location" => "x"}))
    Admission.seed(:skr, "t2", {:error, 404, %{"error" => %{"code" => "KeyNotFound"}}})
    Admission.seed(:auth, "t3", {:refuse, "AuthenticationFailed", "MissingBearerToken"})

    Admission.seed(
      :ledger_deviation,
      "ref/cand",
      {:ok, "ocel_deviation_abcdef1234567890"}
    )

    families = Admission.matrix() |> Enum.map(& &1.family) |> Enum.uniq() |> Enum.sort()

    assert families == [:auth, :graphlaw, :ledger_deviation, :skr]

    # Every row carries the full who/what/verdict/standing tuple.
    for row <- Admission.matrix() do
      assert match?(
               %{id: <<_::binary>>, family: _, subject: <<_::binary>>, verdict: _, standing: _},
               row
             )

      assert row.standing in Admission.standings()
    end
  end

  # Lens-2 cycle 3: ensure_table/0 raced (info-then-new) — concurrent
  # telemetry handle_event/4 or seed/3 callers could both see :undefined and
  # both :ets.new; the loser raised ArgumentError. The lost :ets.new now
  # folds to :ok. This test hammers the window: table deleted, 48 concurrent
  # first-touches, x150 rounds. The kill receipt for the pre-fix code is the
  # failing run preserved in cycle-3.md.
  test "concurrent first-touch does not race table creation" do
    for _round <- 1..150 do
      :ets.delete(:smalt_admission_matrix)

      tasks =
        for i <- 1..48 do
          Task.async(fn ->
            case rem(i, 3) do
              0 -> Admission.attach()
              1 -> Admission.seed(:auth, "race-#{i}", :ok)
              _ -> Admission.matrix()
            end
          end)
        end

      Task.await_many(tasks, 10_000)
      assert :ets.info(:smalt_admission_matrix) != :undefined
    end
  end

  # Lens-3 cycle 1: the lens-2 owner-exit fix makes the Store GenServer the
  # table heir, so the matrix survives its (transient) creator. Mutation
  # court: drop `heir: owner` from ensure_table/0 — this test fails (the
  # table vanishes with the killed creator, row lost).
  test "admission matrix survives its transient creator via the Store heir" do
    :ets.delete(:smalt_admission_matrix)

    parent = self()

    creator =
      spawn(fn ->
        Admission.seed(:auth, "heir-survivor", :ok)
        send(parent, :created)
      end)

    assert_receive :created, 5_000
    assert :ets.info(:smalt_admission_matrix) != :undefined
    assert {:ok, %{subject: "heir-survivor"}} = Store.get(:smalt_admission_matrix, row_key())

    Process.exit(creator, :kill)

    # Heir handoff is asynchronous relative to the killer; poll briefly.
    surviving? = fn ->
      match?(
        {:ok, %{subject: "heir-survivor"}},
        Store.get(:smalt_admission_matrix, row_key())
      )
    end

    survived =
      Enum.any?(1..200, fn _ ->
        if surviving?.(), do: true, else: Process.sleep(10) && false
      end)

    assert survived, "table or its rows vanished after creator exit (heir missing)"

    assert :ets.info(:smalt_admission_matrix) != :undefined
  end

  defp row_key do
    :smalt_admission_matrix
    |> Store.keys()
    |> Enum.find(fn key ->
      match?({:ok, %{subject: "heir-survivor"}}, Store.get(:smalt_admission_matrix, key))
    end)
  end

  # Lens-3 cycle 4: attach_many from 50 concurrent processes. Exactly one
  # attach wins; the other 49 fold {:error, :already_exists} -> :ok. The
  # handler must be registered exactly once and every one of N distinct
  # telemetry events must produce exactly ONE matrix row (no double-writes).
  test "50-process concurrent attach registers the handler exactly once" do
    :telemetry.detach("smalt-admission-projection")

    tasks =
      for _ <- 1..50 do
        Task.async(fn -> :ok = Admission.attach() end)
      end

    Task.await_many(tasks, 10_000)

    handlers = :telemetry.list_handlers([:smalt, :admit])

    assert Enum.count(handlers, fn h -> h.id == "smalt-admission-projection" end) == 1

    routes = for i <- 1..50, do: "/race-50/#{i}"

    for {route, i} <- Enum.with_index(routes, 1) do
      if rem(i, 2) == 0, do: Telemetry.admit(:ok, route: route), else: Telemetry.refuse(:code_r, code: :code_r, route: route)
    end

    eventually = fn fun ->
      Enum.any?(1..100, fn _ ->
        fun.() or (Process.sleep(20) and false)
      end)
    end

    rows_for = fn route ->
      Admission.matrix() |> Enum.count(&(&1.subject == route))
    end

    assert eventually.(fn ->
             Enum.all?(routes, fn r -> rows_for.(r) == 1 end)
           end),
           "expected exactly one matrix row per telemetry event"

    assert Enum.all?(routes, fn r -> rows_for.(r) == 1 end)
  end
end

# Lens-4 cycle 1: fresh degenerate-id shapes against the ledger identity
# fence (refuse_degenerate_ids/2) — whitespace-only and invisible-format-only
# ids now refuse typed on the malformed_ledger_identity axis.
defmodule Smalt.Projection.Admission.Lens4IdentityTest do
  use ExUnit.Case, async: false

  alias Smalt.Projection.Admission

  @dev %{
    "referenceTraceId" => "ref-1",
    "candidateTraceId" => "cand-1",
    "deviatingMove" => "move_x",
    "timestamp" => "2026-01-01T00:00:00Z"
  }

  defp write_ledger(id) do
    path =
      Path.join("tmp", "f16L4-adm-#{System.unique_integer([:positive])}.jsonl")

    File.write!(path, Jason.encode!(Map.put(@dev, "id", id)) <> "\n")
    path
  end

  test "whitespace-only deviation id refuses typed" do
    path = write_ledger("  \t")

    assert_raise ArgumentError, ~r/malformed_ledger_identity/, fn ->
      Admission.from_store(path)
    end

    File.rm!(path)
  end

  test "invisible-format-only (zero-width) deviation id refuses typed" do
    path = write_ledger("​")

    assert_raise ArgumentError, ~r/malformed_ledger_identity/, fn ->
      Admission.from_store(path)
    end

    File.rm!(path)
  end

  test "2-tuple id refuses typed (non-binary carries no identity bits)" do
    # A 2-tuple cannot come out of Jason.decode, but the fence contract is
    # exercised directly at the boundary of read_all/1 in unit terms via a
    # pre-shaped records list — the tuple shape is covered by the shared
    # fence unit tests; here: the list shape through the real file path.
    path = write_ledger(["x", "y"])

    assert_raise ArgumentError, ~r/malformed_ledger_identity/, fn ->
      Admission.from_store(path)
    end

    File.rm!(path)
  end
end
