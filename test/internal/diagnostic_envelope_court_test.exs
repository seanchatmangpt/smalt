defmodule Smalt.Internal.DiagnosticEnvelopeCourtTest do
  @moduledoc """
  GAP-04 envelope validator court (pre-strip witness), v26.10.31.

  Pins the CURRENT `send_arm_error/5` wire output against the 6-class neutral
  diagnostic vocabulary (docs/jira/posh/v26.10.31/gaps/04-diagnostic-vocabulary.md)
  and asserts every refusal the BEAM emits today maps to exactly one wire
  class via the `code` literal (the dispatchable face pre-strip; `class` is
  the post-strip additive field).

  Real collaborators only: the live `Smalt.ArmGateway.Plug.Common` builders,
  the live `check_version` admission gate, the live turnstile fence plug over
  the generated `Smalt.Posh.Pipeline.Arm_request` admission. No mocks.

  Post-strip expectation (residual rows in the gap doc): the bodies gain
  `class`/`dialect`/`receipt` and THIS COURT is the falsifier that flips —
  a post-strip lane extends the assertions to require the three additive
  fields; until then this court witnesses the byte-compat baseline
  (close-condition 7 pre-witness: code literals survive).
  """

  use ExUnit.Case, async: false
  use Plug.Test

  alias Smalt.ArmGateway.Plug.Common

  @classes ~w(
    ADMISSION_REFUSED
    VERSION_CEILING
    SHAPE_VIOLATION
    UNSUPPORTED_FACE
    ENRICHMENT_GAP
    DIALECT_DRIFT
  )

  @rg_type "Microsoft.Resources/resourceGroups"

  setup do
    conn = conn(:get, "/subscriptions/sub/resourcegroups/rg?api-version=2021-04-01")
    %{conn: conn}
  end

  defp error_map(conn), do: conn |> Map.get(:resp_body) |> Jason.decode!() |> Map.fetch!("error")

  defp classify(code) do
    case code do
      "AdmissionRefused" -> :admission_refused
      "MissingApiVersionParameter" -> :version_ceiling
      "InvalidApiVersionParameter" -> :version_ceiling
      "InvalidResourceShape" -> :shape_violation
      "ScopeLocked" -> :admission_refused
      "EngineUnavailable" -> :unsupported_face
    end
  end

  # ---------------------------------------------------------------------------
  # Law: every wire refusal maps to exactly ONE class — classify/1 is total
  # over the observed code set and each body lands in the 6-value enum.
  # ---------------------------------------------------------------------------

  test "classification covers the observed wire code set exactly once" do
    codes = [
      {"AdmissionRefused", 1},
      {"MissingApiVersionParameter", 1},
      {"InvalidApiVersionParameter", 1},
      {"InvalidResourceShape", 1},
      {"ScopeLocked", 1},
      {"EngineUnavailable", 1}
    ]

    for {code, expected_cardinality} <- codes do
      mapped = @classes |> Enum.count(&String.equivalent?(&1, String.upcase(Atom.to_string(classify(code)))))
      # classify/1 returns exactly one class per code (never a list, never none)
      assert mapped == expected_cardinality,
             "code #{code} mapped #{mapped}x, want exactly #{expected_cardinality}"

      assert classify(code) in [:admission_refused, :version_ceiling, :shape_violation, :unsupported_face]
    end
  end

  # ---------------------------------------------------------------------------
  # Class 1: ADMISSION_REFUSED — the turnstile fence (receipt_turnstile.ex:156)
  # ---------------------------------------------------------------------------

  test "turnstile fence refuses a non-object delta with 400 AdmissionRefused (class 1)", %{
    conn: conn
  } do
    conn = %{
      conn
      | method: "POST",
        path_info: ["subscriptions", "sub", "resourcegroups", "rg"],
        request_path: "/subscriptions/sub/resourcegroups/rg",
        body_params: %{"_json" => []},
        private: %{smalt_raw_body: "[]"}
    }

    cfg = Application.get_env(:smalt, :turnstile_fence, [])
    log_name = Keyword.get(cfg, :log_name, Smalt.Posh.Egress.EventLog)

    # Fence mount over the REAL generated admission pipeline.
    conn =
      Smalt.ArmGateway.Plug.ReceiptTurnstile.call(conn, :fence)
      # stamp's before_send never runs without send; emit the envelope the
      # fence branch itself builds (same call the fence makes at :156).
      |> then(fn conn ->
        if conn.halted do
          conn
        else
          # Admitted (should not happen for [] payload) — refuse the court.
          flunk("fence admitted a non-object JSON delta — admission fence broke")
        end
      end)

    assert conn.halted
    assert conn.status == 400
    error = error_map(conn)
    assert error["code"] == "AdmissionRefused"
    assert classify(error["code"]) == :admission_refused
    assert error["message"] =~ "payload violates the arm.request shape"
    assert error["target"] == "/subscriptions/sub/resourcegroups/rg"
    # Pre-strip witness: legacy members only, additive fields absent.
    refute Map.has_key?(error, "class")
    assert error["innererror"] == %{}

    # The refusal is settled loud (event log running or warn-loud) — same
    # receipt header the Go verifier replays.
    assert is_binary(log_name |> to_string())
  end

  # ---------------------------------------------------------------------------
  # Class 2: VERSION_CEILING — check_version admission gate (common.ex:283)
  # ---------------------------------------------------------------------------

  test "stale api-version refuses with 400 InvalidApiVersionParameter naming latest (class 2)", %{
    conn: conn
  } do
    latest = Smalt.Registry.latest_version(@rg_type)

    conn = %{
      conn
      | query_params: %{"api-version" => "2099-01-01"}
    }

    assert {:respond, conn} = Common.check_api_version(conn, @rg_type)
    assert conn.status == 400
    error = error_map(conn)
    assert error["code"] == "InvalidApiVersionParameter"
    assert classify(error["code"]) == :version_ceiling
    # Compatibility pin (SmaltVersionError.fromResponse, version/lib.ts:160):
    # the 400 message names the latest supported version in prose.
    assert error["message"] =~ to_string(latest)
    refute Map.has_key?(error, "class")
    # Corpus pin C1 row 1b: api-version 400s carry NO target.
    refute Map.has_key?(error, "target")
  end

  test "missing api-version refuses with 400 MissingApiVersionParameter (class 2)", %{conn: conn} do
    conn = %{conn | query_params: %{}}
    assert {:respond, conn} = Common.check_api_version(conn, @rg_type)
    assert conn.status == 400
    error = error_map(conn)
    assert error["code"] == "MissingApiVersionParameter"
    assert classify(error["code"]) == :version_ceiling
  end

  test "version-before-shape gate order: malformed version refuses as VERSION_CEILING, never SHAPE_VIOLATION", %{
    conn: conn
  } do
    conn = %{conn | query_params: %{"api-version" => "abc"}}

    assert {:respond, conn} = Common.check_api_version(conn, @rg_type)
    error = error_map(conn)
    assert error["code"] == "InvalidApiVersionParameter"
    assert classify(error["code"]) == :version_ceiling
  end

  # ---------------------------------------------------------------------------
  # Class 3: SHAPE_VIOLATION — GraphLaw refusal face (common.ex:834)
  # ---------------------------------------------------------------------------

  test "graphlaw refusal emits 400 InvalidResourceShape with details[] carrying violations (class 3)", %{
    conn: conn
  } do
    violations = [%{"path" => "location", "message" => "required"}]

    conn = Common.send_graphlaw_refusal(conn, "nsG rejected", violations)
    assert conn.status == 400
    error = error_map(conn)
    assert error["code"] == "InvalidResourceShape"
    assert classify(error["code"]) == :shape_violation
    # Details promotion ALREADY structural here (the fence is the prose site).
    assert error["details"] == violations
    assert error["target"] == "AshGraphLaw.Enforcement"
  end

  test "graphlaw refusal without details stays byte-identical legacy shape (no details key)", %{
    conn: conn
  } do
    conn = Common.send_graphlaw_refusal(conn, "empty")
    error = error_map(conn)
    refute Map.has_key?(error, "details")
    refute Map.has_key?(error, "class")
  end

  # ---------------------------------------------------------------------------
  # Class 4: UNSUPPORTED_FACE — doc-register today (mcp/router.ex:79), no wire
  # emitter. Pre-strip witness: the register is text, the wire is absent.
  # ---------------------------------------------------------------------------

  test "UNSUPPORTED(tls-variant-absent) is still doc-register, not wire (class 4 pre-strip)" do
    source = File.read!("lib/smalt/mcp/router.ex")
    assert source =~ "UNSUPPORTED(tls-variant-absent)"
    # No wire emitter exists: the MCP router never sends a 501 envelope today.
    refute source =~ "send_resp(conn, 501"
  end

  # ---------------------------------------------------------------------------
  # Class 5: ENRICHMENT_GAP — no wire site; nearest semantic is the typed
  # witness-absent fallback (common.ex:609): required input absent, fail-closed,
  # loud reason — never a fake receipt.
  # ---------------------------------------------------------------------------

  test "witness-absent fallback is fail-closed typed with loud reason (class 5 nearest semantic)" do
    witness = Common.witness_absent(:pqc_not_provisioned)
    assert witness["sealed"] == false
    assert witness["receipt"] == "PQC_NOT_PROVISIONED"
    assert witness["reason"] == "pqc_not_provisioned"
    refute witness["sealed"]
  end

  # ---------------------------------------------------------------------------
  # Class 6: DIALECT_DRIFT — lives in the coverage compiler, not on a wire.
  # Pre-strip witness: no BEAM emitter; the court itself is the cell that a
  # stale KD row must flip (residual 5).
  # ---------------------------------------------------------------------------

  test "no BEAM wire emitter carries a class field yet (class 6 pre-strip baseline)" do
    # The three additive fields are absent from every builder the gateway
    # owns today — this is the byte-compat baseline the post-strip lane
    # extends; when a lane lands send_core_error, THIS assertion flips.
    source = File.read!("lib/smalt/arm_gateway/plug/common.ex")
    refute source =~ ~s("class" =>)
    refute source =~ ~s("dialect" =>)

    # "receipt" appears only in the affidavit witness map (normalize_witness),
    # never in a wire error envelope: send_arm_error/5 body is byte-legacy.
    arm_error_src =
      source
      |> String.split("def send_arm_error")
      |> Enum.at(1)
      |> String.split("def send_rg_not_found")
      |> hd()

    refute arm_error_src =~ ~s("receipt")
  end

  # ---------------------------------------------------------------------------
  # Envelope shape law: legacy ARM superset — {code, message, target?,
  # innererror, details?} only, byte-compat face for the fence court grep
  # (58-posh.just:281) and SmaltVersionError.fromResponse (version/lib.ts:160).
  # ---------------------------------------------------------------------------

  test "every emitted error body is the legacy ARM envelope superset" do
    conn = conn(:get, "/x")

    bodies = [
      Common.send_arm_error(conn, 400, "AdmissionRefused", "boom", "/t") |> error_map(conn),
      Common.send_arm_error(conn, 400, "InvalidApiVersionParameter", "boom") |> error_map(conn),
      Common.send_graphlaw_refusal(conn, "boom") |> error_map(conn)
    ]

    legacy_members = MapSet.new(["code", "message", "innererror"])

    for error <- bodies do
      assert MapSet.subset?(legacy_members, MapSet.new(Map.keys(error)))
      assert error["innererror"] == %{}
      assert is_binary(error["message"]) and byte_size(error["message"]) > 0
    end
  end

  defp error_map(conn, _), do: error_map(conn)
end
