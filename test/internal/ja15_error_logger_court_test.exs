defmodule Smalt.Ja15.SiteLogHandler do
  @moduledoc false
  # JA-15 raw-site-log capture handler (elixir-domain events only; SASL
  # reports are dropped by the primary translator filter, per IMPL-6).
  @behaviour :logger_handler

  def log(event, config) do
    line =
      case event.msg do
        {:string, s} -> IO.iodata_to_binary(s)
        {f, a} -> IO.iodata_to_binary(:io_lib.format(f, a))
        other -> inspect(other)
      end

    :ets.insert(config.config.name, {:events, line})
  end
end

defmodule Smalt.Ja15.HostileFormatter do
  @moduledoc false
  # JA-15 hostile formatter: crashes ONLY on the court's own probe events.
  #
  # BK-SEAL6 smear fix: an always-crash formatter installed on the shared
  # :default handler can leak past this court's restore via a concurrent
  # async test's ExUnit capture_log window (a racer that opens mid-hostile
  # captures the hostile config as its "original" and reinstalls it after
  # this court restores correctly). Witnessed as a 150+ test smear
  # (econnrefused / RouteNotReady mass-failure class, BK-SEAL6 full-suite
  # attempts 1 and 3; attempt 2 escaped by ExUnit seed order). Crashing only
  # on the probe event keeps the court's non-vacuity — the default handler
  # still observes a real formatter crash on the probe — while making any
  # leaked window harmless to unrelated tests.
  @probe "ja15 hostile probe 1"

  def format(%{msg: {:string, s}} = event, config) do
    if IO.iodata_to_binary(s) =~ @probe do
      raise("ja15 hostile formatter always crashes")
    else
      :logger_formatter.format(event, config)
    end
  end

  def format(event, config), do: :logger_formatter.format(event, config)
end

defmodule Smalt.Ja15.RefusalTelemetryHandler do
  @moduledoc false
  # JA-15 G2 court handler: module-qualified (no anonymous-fn attach penalty)
  # and forwards every fired [:smalt, :wire, :refusal] event to the test pid.
  def handle_event([:smalt, :wire, :refusal], measurements, metadata, {pid, ref}) do
    send(pid, {:ja15_g2_refusal, measurements, metadata, ref})
  end
end

defmodule Smalt.Ja15.ErrorLoggerCourtTest do
  @moduledoc false

  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  require Logger

  {:ok, _} = Application.ensure_all_started(:inets)

  # ---- 1. AMQP-10 face: labeled actor crash — 4-field crash report ----

  test "amqp10 face: crashed labeled connection report carries label + exception + stacktrace" do
    # Test-owned listener (conn_sup: nil -> spawns no connections), the real
    # labeled actor: %{service: :amqp, role: :listener, correlation_id: :sb}.
    {:ok, pid} = Smalt.Amqp.Listener.start_link({:sb, 0, name: :ja15_crash_listener, conn_sup: nil})
    # Unlink: the crash must be witnessed via its crash REPORT, not the link.
    true = Process.unlink(pid)
    ref = Process.monitor(pid)

    log =
      capture_log(fn ->
        catch_exit(GenServer.call(pid, :ja15_crash_probe))
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
        Logger.flush()

        # Order fence: proves the capture buffer was live in this window.
        Logger.error("ja15 crash-capture fence")
        Logger.flush()
      end)

    # Field-wise (map key order in inspect output is not pinned): every
    # IMPL-6 field must render in the crash report's Process Label line.
    label_line =
      log |> String.split("\n") |> Enum.find("", &String.contains?(&1, "Process Label:"))

    assert label_line != "", "Process Label line missing from crash report"

    assert label_line =~ "service: :amqp" and label_line =~ "role: :listener" and
             label_line =~ "correlation_id: :sb",
           "label line missing IMPL-6 fields; got: #{label_line} | log head: " <>
             String.slice(log, 0, 600)

    assert log =~ "** (FunctionClauseError)",
           "exception missing from crash report"

    assert log =~ "Smalt.Amqp.Listener.handle_call/3",
           "stacktrace missing from crash report"

    assert log =~ "listener.ex:",
           "stacktrace source-file line missing from crash report; got: " <>
             String.slice(log, 0, 600)
  end

  # ---- 2. Correlation id rides the crash report via the process label ----

  test "label correlation id rides a proc_lib crash report" do
    log =
      capture_log(fn ->
        {:ok, sup} = Task.Supervisor.start_link()

        {:ok, pid} =
          Task.Supervisor.start_child(sup, fn ->
            Process.set_label(%{service: :ja15, role: :probe, correlation_id: :ja15_request_42})
            exit({:ja15_boom, __MODULE__})
          end)

        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, {:ja15_boom, _}}, 5_000
        Logger.flush()
      end)

    assert log =~ "ja15_boom"
    assert log =~ "correlation_id: :ja15_request_42"
  end
  # ---- 3. AMQP face: contained pump fault is logged where it happens ----

  test "amqp face: garbage on the wire is contained and logged at the site" do
    Code.require_file("poll_helper.exs", __DIR__)

    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(lsock)
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    {:ok, accepted} = :gen_tcp.accept(lsock)

    {:ok, _pid} = Smalt.Amqp.Connection.start_link(socket: sock, mode: :sb)

    site_log = :ets.new(:ja15_site_log, [:bag, :public, :named_table])

    :ok = :logger.add_handler(:ja15_site, Smalt.Ja15.SiteLogHandler, %{
      config: %{name: site_log}
    })

    # Wrong protocol header bytes: the typed close path. Contained at the
    # site, logged there — never silent, never a naked crash.
    :ok = :gen_tcp.send(accepted, <<"JUNK", 0, 1, 2, 3>>)

    {:ok, _line} =
      SmaltTest.Internal.Poll.eventually(fn ->
        case :ets.lookup(:ja15_site_log, :events) do
          [] -> :error
          events ->
            case Enum.filter(events, fn {_, line} ->
                   String.contains?(line, "bad_protocol_header")
                 end) do
              [] -> :error
              hits -> {:ok, Enum.map_join(hits, "\n", fn {_, l} -> l end)}
            end
        end
      end)

    :logger.remove_handler(:ja15_site)
    :gen_tcp.close(lsock)
  end

  # ---- 4. Hostile formatter does not take the system down ----

  test "hostile: a crashing default-handler formatter does not take the system down" do
    bad_formatter = {Smalt.Ja15.HostileFormatter, :format}
    default_present? = match?({:ok, _}, :logger.get_handler_config(:default))

    # Install the hostile formatter (on :default when present, else on a
    # dedicated hostile handler). The ORIGINAL formatter is captured BEFORE
    # the overwrite — BK-70 fix: the previous restore path re-read the config
    # after the hostile window (still hostile) and "restored" HostileFormatter
    # onto itself, leaving the default handler crashing on every log event for
    # the rest of the suite (simple_handler_process_dead + RouteNotReady 503
    # smear across unrelated tests).
    original_formatter =
      case :logger.get_handler_config(:default) do
        {:ok, original} ->
          :ok = :logger.set_handler_config(:default, :formatter, bad_formatter)
          original.formatter

        {:error, {:not_found, :default}} ->
          :ok =
            :logger.add_handler(:ja15_hostile, :logger_std_h, %{
              formatter: bad_formatter,
              config: %{type: :standard_io},
              level: :all
            })

          nil
      end

    # Hostile window: real log events and a real crash path flow while the
    # formatter is hostile.
    Logger.error("ja15 hostile probe 1")
    spawn(fn -> exit(:ja15_hostile_boom) end)
    Logger.flush()

    # The system survives: logger alive, substrate supervisor alive and
    # responsive.
    assert is_pid(Process.whereis(:logger))
    assert is_pid(Process.whereis(Smalt.Supervisor))
    :sys.get_state(Process.whereis(Smalt.Supervisor))

    # Restore the formatter captured BEFORE the overwrite.
    if default_present? do
      :ok = :logger.set_handler_config(:default, :formatter, original_formatter)
    else
      :ok = :logger.remove_handler(:ja15_hostile)
    end

    restored =
      capture_log(fn -> Logger.error("ja15 hostile probe 2 (post-restore)") end)

    assert restored =~ "ja15 hostile probe 2 (post-restore)",
           "Logger did not recover after the hostile formatter was removed"
  end

  # ---- 5 (JA-15b G1): ledger owner label matches the IMPL-6 map schema ----

  test "ja15b G1: amqp10 settled-ledger owner label matches the IMPL-6 map schema" do
    :ok = Smalt.Amqp10.Ledger.ensure()
    pid = Smalt.Amqp10.Ledger.owner()

    {:label, label} = :erlang.process_info(pid, :label)

    assert is_map(label), "ledger label is not the IMPL-6 map schema: #{inspect(label)}"

    assert label.service == :amqp
    assert label.role == :settled_ledger_owner
    assert label.correlation_id == :amqp10_settled

    # The owner is real: the ETS table it owns exists and is public.
    assert :ets.info(:amqp10_settled, :named_table) == true
    assert :ets.info(:amqp10_settled, :protection) == :public
  end

  # ---- 6 (JA-15b G4): a cosmos wire refusal logs at the site ----

  test "ja15b G4: cosmos wire refusal emits a site log carrying label + correlation id" do
    db = "ja15b"
    coll = "c1"
    {:ok, _, _, _} = Smalt.DataPlane.Cosmos.create_db(db)

    # A doc id containing "/" is the audited silent-refusal witness (G4):
    # typed 400 on the wire, previously nothing at the site.
    log =
      capture_log(fn ->
        assert {:ok, 400, headers, %{"code" => "BadRequest"} = body} =
                 Smalt.DataPlane.Cosmos.create_doc(db, coll, %{"id" => "bad/id"}, %{})

        assert body["message"] =~ "Invalid document id"
        assert Map.has_key?(headers, "x-ms-request-charge")
        Logger.flush()
      end)

    assert log =~ ~s([cosmos] wire refusal status=400 code=BadRequest db=ja15b),
           "site refusal log line missing; got: " <> String.slice(log, 0, 800)

    assert log =~ "correlation_id=cos-",
           "correlation id missing from the refusal log line; got: " <>
             String.slice(log, 0, 800)
  end

  # ---- 7 (JA-15b G5): metadata correlation ids render under the formatter ----

  test "ja15b G5: Logger.metadata correlation id renders in the formatted log line" do
    # No capture-time overrides: the formatter must come from the config
    # :logger, :default_formatter block (G5 fix) for this witness to bind.
    log =
      capture_log(fn ->
        Logger.metadata(correlation_id: "ja15b-meta-42")
        Logger.error("ja15b metadata rendering probe")
        Logger.flush()
      end)

    assert log =~ "ja15b metadata rendering probe"

    # Formatter renders metadata as key=value (Elixir 1.15+ formatter).
    assert log =~ ~r/correlation_id="?ja15b-meta-42/,
           "metadata correlation id did not render from config defaults; got: " <>
             String.slice(log, 0, 600)
  end

  # ---- 8 (JA-15 G2): cosmos wire refusal fires [:smalt, :wire, :refusal] ----

  test "ja15 G2: cosmos wire refusal fires telemetry with status/code/correlation_id" do
    db = "ja15g2"
    coll = "c1"
    {:ok, _, _, _} = Smalt.DataPlane.Cosmos.create_db(db)

    test_pid = self()
    ref = make_ref()

    handler_id = :ja15_g2_cosmos_telemetry

    :ok =
      :telemetry.attach(
        handler_id,
        [:smalt, :wire, :refusal],
        &Smalt.Ja15.RefusalTelemetryHandler.handle_event/4,
        {test_pid, ref}
      )

    try do
      # Real refusal: doc id containing "/" -> typed 400 BadRequest (G4 site).
      assert {:ok, 400, _headers, %{"code" => "BadRequest"} = body} =
               Smalt.DataPlane.Cosmos.create_doc(db, coll, %{"id" => "bad/id"}, %{})

      assert body["message"] =~ "Invalid document id"

      assert_receive {:ja15_g2_refusal, %{count: 1},
                      %{face: :cosmos, status: 400, code: "BadRequest"} = metadata, ^ref},
                     5_000

      assert metadata.correlation_id =~ ~r/^cos-\d+$/,
             "correlation_id missing/malformed in telemetry metadata: #{inspect(metadata)}"
    after
      :ok = :telemetry.detach(handler_id)
    end
  end

  # ---- 9 (JA-15 G2): blob wire refusal fires the same event ----

  test "ja15 G2: blob wire refusal fires telemetry with status/code/correlation_id" do
    test_pid = self()
    ref = make_ref()
    handler_id = :ja15_g2_blob_telemetry

    :ok =
      :telemetry.attach(
        handler_id,
        [:smalt, :wire, :refusal],
        &Smalt.Ja15.RefusalTelemetryHandler.handle_event/4,
        {test_pid, ref}
      )

    try do
      # Real refusal through the real funnel: a Plug.Conn through a throwaway
      # in-process adapter socket is heavy; send_error is the funnel itself,
      # driven with a real conn built by Plug.Adapters.Test.Conn.
      conn =
        Plug.Adapters.Test.Conn.conn(%Plug.Conn{}, :get, "/ja15/blob-missing", nil)

      assert %Plug.Conn{status: 404, resp_body: body, state: :sent} =
               Smalt.DataPlane.BlobError.send_error(
                 conn,
                 404,
                 "BlobNotFound",
                 "The specified blob does not exist.",
                 "ja15-g2-req-1"
               )

      assert body =~ "<Code>BlobNotFound</Code>"

      assert_receive {:ja15_g2_refusal, %{count: 1},
                      %{face: :blob, status: 404, code: "BlobNotFound"} = metadata, ^ref},
                     5_000

      assert metadata.correlation_id == "blob-ja15-g2-req-1"
    after
      :ok = :telemetry.detach(handler_id)
    end
  end

  # ---- 10 (JA-15 G2 non-vacuity): no handler -> refusal still works ----

  test "ja15 G2 non-vacuity: telemetry handler absent, refusal still typed on the wire" do
    # Deliberately NO attach: the execute is observability, not control flow.
    db = "ja15g2nv"
    coll = "c1"
    {:ok, _, _, _} = Smalt.DataPlane.Cosmos.create_db(db)

    assert {:ok, 400, _headers, %{"code" => "BadRequest"} = body} =
             Smalt.DataPlane.Cosmos.create_doc(db, coll, %{"id" => "bad/id"}, %{})

    assert body["message"] =~ "Invalid document id"

    conn = Plug.Adapters.Test.Conn.conn(%Plug.Conn{}, :get, "/ja15/blob-nv", nil)

    assert %Plug.Conn{status: 409, resp_body: body2, state: :sent} =
             Smalt.DataPlane.BlobError.send_error(
               conn,
               409,
               "LeaseIdMismatchWithBlobOperation",
               "There is currently a lease on the blob.",
               "ja15-g2-nv-1"
             )

    assert body2 =~ "<Code>LeaseIdMismatchWithBlobOperation</Code>"
  end
end
