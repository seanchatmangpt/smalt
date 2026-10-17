defmodule Mix.Tasks.Smalt.Doctor do
  @shortdoc "Operator diagnostic engine: 4 real checks -> JSON receipt (always exit 0)."

  @moduledoc """
  Runs Smalt.Enclave.Doctor and emits a JSON receipt to stdout and, when
  `--json-receipt <path>` is given, to that path.

  Aggregate: FAIL on structural check FAIL, DEGRADED on WARN, else PASS.
  Exit contract: ALWAYS 0 unless the engine itself crashes — a doctor that
  exits nonzero on a WARN is a doctor CI learns to ignore.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {parsed, _argv, _invalid} = OptionParser.parse(args, strict: [json_receipt: :string])

    # Doctor self-boots on ephemeral ports (port 0): the task must never
    # collide with a live substrate holding 9443/8443/9545, and never depend
    # on one either — the checks below are in-process.
    Application.put_env(:smalt, :arm_port, 0)
    Application.put_env(:smalt, :arm_tls_port, 0)
    Application.put_env(:smalt, :egress_port, 0)
    Application.put_env(:smalt, :mcp_port, 0)
    Application.put_env(:smalt, :amqp_port, 0)
    Application.put_env(:smalt, :event_hubs_port, 0)
    Application.put_env(:smalt, :auth_mode, :anonymous)

    Mix.Task.run("app.start")

    receipt = Smalt.Enclave.Doctor.run([])
    json = Jason.encode!(receipt, pretty: true)

    IO.puts(json)

    receipt_path =
      case Keyword.fetch(parsed, :json_receipt) do
        {:ok, path} ->
          path = Path.expand(path)
          path |> Path.dirname() |> File.mkdir_p!()
          File.write!(path, json <> "\n")
          File.write!(Path.expand(path), json <> "\n")
          path

        :error ->
          ""
      end

    # OCEL emission (fail-safe): one doctor.receipt event per completed
    # doctor run; a telemetry failure never fails the doctor.
    case Smalt.Telemetry.CourtOcel.doctor_receipt(receipt, receipt_path) do
      {:ok, :dropped} -> IO.puts("[doctor] ocel: doctor.receipt dropped (registry gate)")
      {:ok, _} -> IO.puts("[doctor] ocel: doctor.receipt emitted")
      {:error, reason} -> IO.puts("[doctor] ocel: emission failed, dropped (fail-safe): #{inspect(reason)}")
    end

    :ok
  end
end
