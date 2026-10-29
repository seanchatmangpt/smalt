# EXPL11-R1 — repair court for EXPL-11 F1 (ConfidentialLedger range parser).
#
# F1 witnessed two opposite failures from one root cause (seq_of/1 + in_range?/3):
#   * dot-less malformed transactionId ("zzz") silently coerced to seq 0 ->
#     GET /app/transactions?rangeBegin=zzz returned 200 with ALL transactions;
#   * dotful non-numeric ("notanumber.9") raised ArgumentError inside
#     handle_call -> ledger GenServer crash -> 500, loopable unauthenticated DoS.
#
# Fix: valid_range/2 validates rangeBegin/rangeEnd as "N.M" transactionId
# strings at the router boundary (pure function, no GenServer touched) ->
# 400 InvalidRange. Valid ranges keep exact semantics.
#
# Real-HTTP court: real Bandit listener, real JournalSink on real disk, real
# curl wire calls, no mocks. Run:
#   MIX_BUILD_ROOT=_build-expl11r1 mix test test/internal/expl11r1_ledger_range_court_test.exs

Code.require_file("poll_helper.exs", __DIR__)

defmodule Internal.Expl11r1.LedgerRangeCourt do
  use ExUnit.Case, async: false

  alias Smalt.ConfidentialLedger.Service
  alias Smalt.Storage.JournalSink
  alias SmaltTest.Internal.Poll

  setup ctx do
    # AZ-3b: the Service name is owned by the supervised mount
    # (Smalt.ConfidentialLedger.Supervisor under the data plane); lawfully
    # terminate the mount subtree for the test's duration, restart on exit.
    mount_restart =
      case Supervisor.terminate_child(Smalt.Plane.DataSupervisor, Smalt.ConfidentialLedger.Supervisor) do
        :ok -> :restart
        {:error, _} -> :noop
      end

    stop_service()

    root = Path.join(System.tmp_dir!(), "journal-expl11r1-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    dir = Path.join(root, "journal")
    sink_name = Module.concat([Expl11r1.Sink, Integer.to_string(:erlang.unique_integer([:positive]))])

    {:ok, _sink} =
      JournalSink.start_link(dir: dir, name: sink_name, segment_ceiling: 4_000, sync_interval_ms: 3_600_000)

    {:ok, _svc} =
      case Service.start_link(dir: dir, sink: sink_name, certify_interval_ms: 40) do
        {:ok, _} = ok ->
          ok

        {:error, {:already_started, stale}} ->
          GenServer.stop(stale)
          Service.start_link(dir: dir, sink: sink_name, certify_interval_ms: 40)
      end

    port = free_port()

    {:ok, _bandit} =
      Bandit.start_link(plug: Smalt.ConfidentialLedger.Router, scheme: :http, port: port)

    base = "http://127.0.0.1:#{port}"

    on_exit(fn ->
      stop_service()

      if mount_restart == :restart do
        Supervisor.restart_child(Smalt.Plane.DataSupervisor, Smalt.ConfidentialLedger.Supervisor)
      end

      File.rm_rf!(root)
    end)

    %{base: base, dir: dir, sink: sink_name}
  end

  ## -- legs -------------------------------------------------------------------

  @tag :expl11r1
  test "falsifier 1: rangeBegin=zzz -> 400 InvalidRange, never 200-with-all", %{base: base} do
    for i <- 1..3, do: append(base, i)

    {400, body} = get(base, "/app/transactions?rangeBegin=zzz")
    assert %{"error" => %{"code" => "InvalidRange"}} = Jason.decode!(body)
  end

  @tag :expl11r1
  test "falsifier 2: rangeEnd=notanumber.9 -> 400 InvalidRange, service alive after", %{base: base} do
    for i <- 1..3, do: append(base, i)

    {400, body} = get(base, "/app/transactions?rangeEnd=notanumber.9")
    assert %{"error" => %{"code" => "InvalidRange"}} = Jason.decode!(body)

    # the GenServer must be alive and answering (no crash / restart churn)
    Poll.eventually(fn ->
      case Service.transactions(nil, nil, 100) do
        {:ok, _} -> {:ok, :alive}
        _ -> :pending
      end
    end)

    assert Process.alive?(Process.whereis(Service))
  end

  @tag :expl11r1
  test "malformed variants all 400 at the boundary", %{base: base} do
    for i <- 1..2, do: append(base, i)

    for bad <- ["7", "7.x", "x.1", "7.", ".1", "-1.1", "%20", "notanumber.9"] do
      {code, body} = get(base, "/app/transactions?rangeBegin=#{URI.encode_www_form(bad)}")
      assert code == 400, "rangeBegin=#{inspect(bad)} -> #{code}"
      assert %{"error" => %{"code" => "InvalidRange"}} = Jason.decode!(body)

      {code2, _} = get(base, "/app/transactions?rangeEnd=#{URI.encode_www_form(bad)}")
      assert code2 == 400, "rangeEnd=#{inspect(bad)} -> #{code2}"
    end
  end

  @tag :expl11r1
  test "valid range semantics unchanged", %{base: base} do
    ids = for i <- 1..4, do: append(base, i)
    poll_committed_count(base, 4)
    [id1, id2, id3, id4] = ids

    {200, body} = get(base, "/app/transactions?rangeBegin=#{id2}&rangeEnd=#{id3}")
    %{"transactions" => txs} = Jason.decode!(body)
    assert Enum.map(txs, & &1["transactionId"]) == [id2, id3]

    {200, body2} = get(base, "/app/transactions")
    %{"transactions" => all} = Jason.decode!(body2)
    assert length(all) == 4

    # half-open ranges still valid (polled: a tx flips Pending->Committed on
    # the certify tick and its segment re-verify can transiently omit it for
    # one pass — pre-existing certification timing, not range semantics)
    tail_ids =
      case Poll.eventually(fn ->
        case get(base, "/app/transactions?rangeBegin=#{id3}") do
          {200, b} ->
            case Jason.decode(b) do
              {:ok, %{"transactions" => tail}} ->
                got = Enum.map(tail, & &1["transactionId"])

                if got == [id3, id4], do: {:ok, got}, else: :pending

              _ ->
                :pending
            end

          _ ->
            :pending
        end
      end) do
      {:ok, ids} -> ids
      other -> other
    end

    assert tail_ids == [id3, id4]
  end

  @tag :expl11r1
  test "service-level typed refusal mirrors the wire 400", %{base: base} do
    for i <- 1..2, do: append(base, i)

    assert {:error, :invalid_range} = Service.transactions("zzz", nil)
    assert {:error, :invalid_range} = Service.transactions(nil, "notanumber.9")
    assert :ok = Service.valid_range("2.1", nil)
    assert {:error, :invalid_range} = Service.valid_range("7", nil)
  end

  ## -- helpers ----------------------------------------------------------------

  defp append(base, n) do
    {201, body} =
      curl(base, "/app/transactions", ["-X", "POST", "-H", "Content-Type: application/json",
                                       "--data-binary", Jason.encode!(%{"contents" => %{"n" => n}})])

    %{"transactionId" => id} = Jason.decode!(body)
    id
  end

  defp poll_committed_count(base, n) do
    Poll.eventually(fn ->
      case get(base, "/app/transactions") do
        {200, b} ->
          case Jason.decode(b) do
            {:ok, %{"transactions" => txs}} when length(txs) >= n -> {:ok, txs}
            _ -> :pending
          end

        _ ->
          :pending
      end
    end)
  end

  defp stop_service do
    case Process.whereis(Service) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defp get(base, path), do: curl(base, path, [])

  defp curl(base, path, extra) do
    {out, 0} =
      System.cmd("curl", ["-s", "-w", "\n%{http_code}", "#{base}#{path}" | extra],
        stderr_to_stdout: true
      )

    parts = String.split(String.trim_trailing(out), "\n")
    code = String.to_integer(List.last(parts))
    {code, Enum.join(Enum.drop(parts, -1), "\n")}
  end
end
