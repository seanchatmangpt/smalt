defmodule Smalt.Enclave.Remediations do
  @moduledoc """
  Single source of truth for typed diagnostic exit contracts (v26.10.16
  lane 430): every machine receipt finding carries an explicit
  `{code, severity}` pair, and every code maps to one remediation command
  in this table. Doctor (`Smalt.Enclave.Doctor`), the lifecycle residue
  stage, and the gate scripts share this one mapping — a code minted in a
  receipt without a row here is a defect, not an extension point.

  Severity vocabulary (closed): `BLOCKING_GATE` (flips the aggregate
  verdict / exit code) and `ADVISORY` (reported, never blocks).
  """

  @typedoc "Closed severity vocabulary."
  @type severity :: :BLOCKING_GATE | :ADVISORY

  @typedoc "Diagnostic code with a remediation row (see `table/0`)."
  @type code :: String.t()

  @doc """
  The remediation table: `code => command`. Commands are real, runnable
  repo entries — a row that names a command the repo does not have is a
  defect (fail-closed at `command!/1`).
  """
  @spec table() :: %{String.t() => String.t()}
  def table do
    %{
      # HCL term failed the pre-hydration shape contract (engine stage).
      "SHAPE_REJECTED_BEFORE_DEFAULT_HYDRATION" => "bash scripts/tf_plan_check.sh",
      # Strict residue audit over the live Store tables.
      "ETS_IDENTITY_RESIDUE" => "mix smalt.audit_residue --strict",
      # macOS trust evaluator rejects the dev CA: fall back to native mode.
      "DARWIN_TRUST_MISSING" => "just test-native",
      # Post-destroy orphaned rows in resource-bearing Store tables.
      "ORPHANED_DATA_PLANE_ROWS_DETECTED" => "mix smalt.audit_residue --strict",
      # Telemetry drift beyond 3 sigma (wave_telemetry).
      "SPC_3SIG_BREACH" => "bash scripts/wave_telemetry.sh",
      # Surface divergence with no KD-nn register row.
      "KD_ROW_CANDIDATE" => "python3 scripts/kd_flip.py --check",
      # Legacy doctor-emitted codes: table stays total over every code the
      # doctor can put in a receipt (fail-closed command!/1 never starves).
      "CHECK_ENGINE_CRASH" => "mix smalt.doctor",
      "HCL_PARSE_FAULTS" => "bash scripts/tf_cleanroom.sh",
      "API_VERSION_LATTICE_FAULT" => "mix smalt.gen",
      "DARWIN_TRUST_UNREACHABLE" => "just test-native",
      # NFR3 BEAM memory-budget fence (scripts/nfr3_rss_gate.py).
      "NFR3_RSS_BUDGET_BREACH" => "python3 scripts/nfr3_rss_gate.py --keep",
      # Affidavit-wasm artifact missing / sha256 mismatch / engine load failure.
      "AFFIDAVIT_WASM_DEGRADED" => "bash scripts/affidavit_wasm_build.sh",
      # Affidavit engine check itself crashed (W17/D2): the doctor refused
      # typed instead of crashing — rebuild + re-run the doctor.
      "AFFIDAVIT_ENGINE_UNAVAILABLE" => "bash scripts/affidavit_wasm_build.sh && mix smalt.doctor"
    }
  end

  @doc "Severity for a status: FAIL -> BLOCKING_GATE, WARN -> ADVISORY."
  @spec severity_for(String.t()) :: severity() | nil
  def severity_for("FAIL"), do: :BLOCKING_GATE
  def severity_for("WARN"), do: :ADVISORY
  def severity_for(_), do: nil

  @doc "Remediation command for a code; raises fail-closed on an unmapped code."
  @spec command!(String.t()) :: String.t()
  def command!(code) do
    case Map.fetch(table(), code) do
      {:ok, cmd} -> cmd
      :error -> raise "remediation table has no row for code #{inspect(code)}"
    end
  end

  @doc "Non-raising lookup."
  @spec fetch(String.t()) :: {:ok, String.t()} | :error
  def fetch(code), do: Map.fetch(table(), code)
end
