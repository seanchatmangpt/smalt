defmodule Smalt.Enclave.Lifecycle do
  @moduledoc """
  The external-Go-free enclave lifecycle ladder: one entry point that runs
  parse -> in-process engine apply -> plan-equivalent zero-drift assert ->
  tfstate synthesis -> in-process destroy -> zero-residue assert, with
  per-stage timing (NFR-1). No sockets, no TLS, no terraform binary, no
  external Go processes — every hop is a plain function call dispatched
  through the real ARM gateway router.

  ## Stages

    1. `:parse`      — `Smalt.Enclave.Hcl.parse/1` on the fixture
    2. `:apply`      — `Enclave.Engine.apply/2` (in-process dispatch)
    3. `:plan`       — `Enclave.State.plan/1` MUST return `[]` (zero drift
                       between the applied terms and the live store)
    4. `:synthesize` — `Enclave.State.write/2` (tfstate-shaped JSON)
    5. `:destroy`    — `Enclave.State.destroy/1` (reverse-topological
                       DELETE walk + 404 verification per id)
    6. `:residue`    — every resource-bearing Store table must be empty

  Returns `{:ok, report}`; the report carries per-stage elapsed-ms, the
  engine outcomes, the state path, the empty plan diff, the deleted list,
  and the final residue map. Failures return
  `{:error, {:stage_failed, stage, reason}}`; raises from
  `plan`/`residue` asserts are rescued into the same shape. A stage that
  cannot flip the result is not a stage.
  """

  alias Smalt.Enclave.{Engine, Hcl, State}

  @type report :: %{
          timings_ms: %{atom() => non_neg_integer()},
          outcomes: [map()],
          state_path: String.t(),
          plan_diff: list(),
          deleted: [map()],
          residue: %{atom() => [term()]}
        }

  @doc """
  Runs the full lifecycle against the HCL fixture at `fixture_path`.

  Opts:

    * `:state_path` — where to write the tfstate JSON (default
      `tmp/enclave-native-<unix_ms>.tfstate`)
    * :subscription_id — forwarded to the engine
    * :assert_residue — default `true`; fail-closed zero-residue check
      over every resource-bearing Store table
  """
  @spec run(String.t() | Path.t(), keyword()) ::
          {:ok, report()} | {:error, {:stage_failed, atom(), term()}}
  def run(fixture_path, opts \\ []) do
    state_path = Keyword.get(opts, :state_path, default_state_path())
    ocel = Smalt.Telemetry.EnclaveOcel.ctx(fixture_path, opts)

    try do
      with {:ok, {ms_parse, parse_res}} <- timed_stage(:parse, fn -> Hcl.parse(fixture_path) end),
           {:ok, doc} <- ok_stage(:parse, parse_res),
           :ok <- emit_stage(:parse, ms_parse, ocel),
           terms = to_terms(doc),
           {:ok, {ms_apply, apply_res}} <-
             timed_stage(:apply, fn -> Engine.apply(terms, opts) end),
           {:ok, outcomes} <- ok_stage(:apply, apply_res),
           ocel = Smalt.Telemetry.EnclaveOcel.put_resource_ids(ocel, outcomes),
           :ok <- emit_stage(:apply, ms_apply, ocel),
           {:ok, {ms_plan, plan_diff}} <-
             timed_stage(:plan, fn -> outcomes |> outcome_map() |> State.plan() end),
           :ok <- check_plan(plan_diff),
           :ok <- emit_stage(:plan, ms_plan, ocel),
           {:ok, {ms_syn, :ok}} <-
             timed_stage(:synthesize, fn ->
               outcomes |> outcome_map() |> State.write(state_path)
             end),
           :ok <- emit_stage(:synthesize, ms_syn, ocel),
           {:ok, {ms_destroy, %{deleted: deleted, residue: residue}}} <-
             timed_stage(:destroy, fn -> outcomes |> outcome_map() |> State.destroy() end),
           :ok <- emit_stage(:destroy, ms_destroy, ocel),
           {:ok, {ms_res, :ok}} <- timed_stage(:residue, fn -> assert_residue(residue) end),
           :ok <- emit_stage(:residue, ms_res, ocel) do
        {:ok,
         %{
           timings_ms: %{
             parse: ms_parse,
             apply: ms_apply,
             plan: ms_plan,
             synthesize: ms_syn,
             destroy: ms_destroy,
             residue: ms_res
           },
           outcomes: outcomes,
           state_path: state_path,
           plan_diff: plan_diff,
           deleted: deleted,
           residue: residue
         }}
      end
    rescue
      e ->
        _ = emit_failed(ocel)
        {:error, {:stage_failed, :lifecycle, Exception.format(:error, e, __STACKTRACE__)}}
    end
  end

  # -- OCEL emission ---------------------------------------------------------

  # Fail-safe: telemetry never raises into the lifecycle caller.
  defp emit_stage(stage, ms, ocel) do
    _ = Smalt.Telemetry.EnclaveOcel.stage(stage, ms, "ok", ocel)
    :ok
  end

  defp emit_failed(ocel) do
    Smalt.Telemetry.EnclaveOcel.stage(:lifecycle, 0, "failed", ocel)
  end

  # ---------------------------------------------------------------------------
  # HCL doc -> engine terms
  # ---------------------------------------------------------------------------

  # TF fixture local names are per-type (three resources named
  # "smalt_fixture"), so the engine label is the type-qualified
  # "type.name" — exactly the shape `Hcl` emits for dotted refs
  # ({:ref, "type.name", attr}), so refs pass through untouched.
  defp to_terms(doc) do
    for r <- doc.resources do
      %{
        type: r.type,
        label: r.type <> "." <> r.name,
        attrs: r.attrs
      }
    end
  end

  # ---------------------------------------------------------------------------
  # stage plumbing
  # ---------------------------------------------------------------------------

  # State.* terms carry the ARM type (lookup/type-diff/destroy all route on
  # it); the azurerm type stays only in the engine outcomes for reporting.
  defp outcome_map(outcomes),
    do: Map.new(outcomes, &{&1.label, %{id: &1.id, type: &1.arm_type}})

  defp timed_stage(_stage, fun) do
    t0 = System.monotonic_time(:millisecond)
    result = fun.()
    ms = System.monotonic_time(:millisecond) - t0
    {:ok, {ms, result}}
  end

  defp ok_stage(_stage, {:ok, value}), do: {:ok, value}
  defp ok_stage(stage, other), do: raise("stage #{stage} failed: #{inspect(other, limit: 20)}")

  defp check_plan([]), do: :ok

  defp check_plan(diff),
    do: raise("zero-drift plan assert failed: #{inspect(diff, limit: 20)}")

  defp assert_residue(residue) do
    nonempty = for {t, keys} <- residue, keys != [], do: {t, keys}

    nonempty == [] ||
      raise(
        "code=ORPHANED_DATA_PLANE_ROWS_DETECTED severity=BLOCKING_GATE " <>
          "remediation=\"mix smalt.audit_residue --strict\" " <>
          "non-zero residue after destroy: #{inspect(nonempty, limit: 20)}"
      )

    :ok
  end

  defp default_state_path do
    # Anchor to absolute cwd (tf_enclave_loop.sh consumers may run with a
    # shifted cwd) and guarantee tmp/ exists before terraform writes state.
    path =
      Path.join(File.cwd!(), "tmp/enclave-native-#{System.system_time(:millisecond)}.tfstate")

    File.mkdir_p!(Path.dirname(path))
    path
  end
end
