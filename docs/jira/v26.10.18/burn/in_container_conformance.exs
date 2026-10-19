# in_container_conformance.exs — In-Container Conformance & Validation Probe
#
# Runs INSIDE smalt:local container with mounted ~/xaas and ~/beam4pm.
#
# Laws verified:
#   1. Closed-vocabulary IEEE OCEL 2.0 conformance via Xaas.Ultracode.Ocel.Validator
#   2. Petri Net process conformance via BeamPM.Art72Conformance
#
# Exit: 0 on PASS, 1 on FAIL with typed reason.

paths =
  case System.argv() do
    [] ->
      # Default: search for ocel files under /burn-results and /burn-evidence
      Path.wildcard("/burn-results/*.ocel.json") ++
        Path.wildcard("/burn-evidence/*.ocel.json")

    explicit ->
      explicit
  end

if paths == [] do
  IO.puts(:stderr, "[IN-CONTAINER-CONFORMANCE] REFUSED: No OCEL 2.0 files found to validate.")
  System.halt(1)
end

IO.puts("[IN-CONTAINER-CONFORMANCE] Loading Xaas & BeamPM engines...")

xaas_validator = "/xaas/lib/xaas/ultracode/ocel/validator.ex"
beampm_conformance = "/beam4pm/lib/beam4pm_art72_conformance.ex"

unless File.exists?(xaas_validator) do
  IO.puts(:stderr, "[IN-CONTAINER-CONFORMANCE] REFUSED: /xaas not mounted or validator missing: #{xaas_validator}")
  System.halt(1)
end

unless File.exists?(beampm_conformance) do
  IO.puts(:stderr, "[IN-CONTAINER-CONFORMANCE] REFUSED: /beam4pm not mounted or conformance missing: #{beampm_conformance}")
  System.halt(1)
end

Code.require_file(xaas_validator)
Code.require_file(beampm_conformance)

IO.puts("[IN-CONTAINER-CONFORMANCE] Engines loaded successfully.")

# 1. Closed-vocabulary OCEL 2.0 validation via Xaas
Enum.each(paths, fn path ->
  case Xaas.Ultracode.Ocel.Validator.validate_file(path) do
    {:ok, rep} ->
      IO.puts("[IN-CONTAINER-XaaS] PASS #{path}: #{rep["event_count"]} events, #{rep["object_count"]} objects")

    {:error, violations} ->
      IO.puts(:stderr, "[IN-CONTAINER-XaaS] FAIL #{path}:")
      Enum.each(violations, fn v -> IO.puts(:stderr, "  - #{v.path}: #{v.reason}") end)
      System.halt(1)
  end
end)

# 2. Conformance replay via BeamPM Petri Net model
net =
  BeamPM.Art72Conformance.net(
    %{
      "arm.resource.transition" => %{input: %{"p_start" => 1}, output: %{"p_armed" => 1}},
      "amqp.delivery.settled" => %{input: %{"p_armed" => 1}, output: %{"p_settled" => 1}},
      "blob.custody.transition" => %{input: %{"p_settled" => 1}, output: %{"p_end" => 1}}
    },
    %{"p_start" => 1},
    %{"p_end" => 1}
  )

trace = ["arm.resource.transition", "amqp.delivery.settled", "blob.custody.transition"]
result = BeamPM.Art72Conformance.replay_trace(net, trace)

if result.missing == 0 and result.remaining == 0 do
  IO.puts("[IN-CONTAINER-BeamPM] PASS Happy-path Petri net replay: consumed=#{result.consumed} produced=#{result.produced}")
else
  IO.puts(:stderr, "[IN-CONTAINER-BeamPM] FAIL Replay discrepancy: #{inspect(result)}")
  System.halt(1)
end

IO.puts("[IN-CONTAINER-CONFORMANCE] ALL IN-CONTAINER COURTS PASS")
System.halt(0)
