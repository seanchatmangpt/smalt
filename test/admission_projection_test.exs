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

  test "verdict counter-aggregation matches Telemetry.dump() where overlapping" do
    Telemetry.admit(:ok, route: "/arm/shapes")
    Telemetry.admit(:ok, route: "/arm/shapes")
    Telemetry.refuse(:SHAPE_INVALID, code: :SHAPE_INVALID, route: "/egress/x")
    Telemetry.refuse(:UNAUTHORIZED_ROUTE, code: :UNAUTHORIZED_ROUTE, route: "/egress/y")

    counts = Admission.counts()

    # Every telemetry event produced exactly one matrix row.
    assert counts[{:smalt_event, :admit}] == 2
    assert counts[{:smalt_event, :refuse}] == 2

    dump = Telemetry.dump()

    telemetry_admits =
      dump
      |> Enum.filter(fn {{name, _meta}, _n} -> name == [:smalt, :admit] end)
      |> Enum.map(fn {_k, n} -> n end)
      |> Enum.sum()

    telemetry_refuses =
      dump
      |> Enum.filter(fn {{name, _meta}, _n} -> name == [:smalt, :refuse] end)
      |> Enum.map(fn {_k, n} -> n end)
      |> Enum.sum()

    assert counts[{:smalt_event, :admit}] == telemetry_admits
    assert counts[{:smalt_event, :refuse}] == telemetry_refuses
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
end
