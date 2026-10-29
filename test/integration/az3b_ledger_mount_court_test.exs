# AZ-3b — Confidential Ledger REST face MOUNTED under the data-plane
# supervision tree (Smalt.Plane.DataSupervisor ->
# Smalt.ConfidentialLedger.Supervisor: dedicated JournalSink + Service +
# Bandit router on :confidential_ledger_port).
#
# Real-HTTP court against the MOUNTED listener — not a standalone Bandit
# plug spun up by the test. Asserts the supervision shape, the pinned-port
# listener, and the wire behavior (append -> Committed poll -> receipt root
# matches the recomputed on-disk chain -> VC certificate verifies).
#
# Run: MIX_BUILD_ROOT=_build-az3 mix test test/integration/az3b_ledger_mount_court_test.exs

Code.require_file("poll_helper.exs", Path.join(__DIR__, "../internal"))

defmodule Az3b.MountCourt do
  use ExUnit.Case, async: false

  alias Smalt.ConfidentialLedger.Service
  alias Smalt.Storage.JournalReader
  alias SmaltTest.Internal.Poll
  alias Smalt.Sync.Receipt

  @tag :az3
  test "mount shape: sink + service + Bandit listener supervised under the data plane" do
    assert Enum.find(Supervisor.which_children(Smalt.Plane.DataSupervisor), fn {id, pid, _, _} ->
             id == Smalt.ConfidentialLedger.Supervisor and is_pid(pid)
           end)

    ids =
      Supervisor.which_children(Smalt.ConfidentialLedger.Supervisor)
      |> Enum.map(fn {id, _, _, _} -> id end)

    for expected <- [
          Smalt.ConfidentialLedger.Sink,
          Smalt.ConfidentialLedger.Service,
          Bandit
        ] do
      assert expected in ids, "missing child #{inspect(expected)} in #{inspect(ids)}"
    end

    # the supervised Service is the named one the router calls
    assert Process.whereis(Service) |> is_pid()
  end

  test "wire leg: append -> Committed -> receipt root matches on-disk chain, via the mounted listener" do
    port = Application.get_env(:smalt, :confidential_ledger_port)
    assert is_integer(port)
    base = "http://127.0.0.1:#{port}"

    {201, body} = post(base, "/app/transactions", %{"contents" => %{"n" => 1, "mount" => true}})
    assert %{"transactionId" => id} = Jason.decode!(body)
    assert Regex.match?(~r/^\d+\.1$/, id)

    # mounted Service uses the default 2s certify tick — poll until the
    # state actually reads Committed (no-sleep doctrine: bounded observable poll)
    assert {:ok, body} =
             Poll.eventually(fn ->
               case get(base, "/app/transactions/#{id}?api-version=2022-05-17") do
                 {200, b} ->
                   case Jason.decode!(b) do
                     %{"state" => "Committed"} -> {:ok, b}
                     _ -> :pending
                   end

                 _ ->
                   :pending
               end
             end)

    assert %{"state" => "Committed", "entry" => %{"contents" => %{"mount" => true}}} =
             Jason.decode!(body)

    {200, rbody} = get(base, "/app/transactions/#{id}/receipt")
    assert %{"receipt" => %{"root" => root_hex}} = Jason.decode!(rbody)

    # root re-computed from the on-disk sealed segments of the MOUNTED sink's dir
    dir = Application.get_env(:smalt, :acl_journal_dir)
    assert is_binary(dir)

    {:ok, segs} = JournalReader.discover_sealed_segments(dir)

    roots =
      Enum.flat_map(segs, fn seg ->
        {:ok, frames} = JournalReader.read_sealed_segment(seg)

        root =
          Enum.reduce(frames, Receipt.empty_chain(), fn f, chain ->
            wire =
              elem(
                Smalt.Storage.JournalSink.encode_frame(
                  f.seq_id,
                  f.ts,
                  f.event_type,
                  f.table_id,
                  f.key,
                  f.payload
                ),
                0
              )

            Receipt.absorb(chain, wire)
          end).root

        [Base.encode16(root, case: :lower)]
      end)

    assert root_hex in roots

    {200, cbody} = get(base, "/app/transactions/#{id}/certificate")
    vc = Jason.decode!(cbody)
    assert {:ok, _} = Smalt.Receipt.VcExport.verify_vc(vc)

    {404, body} = get(base, "/app/transactions/999999.1")
    assert %{"error" => %{"code" => "TransactionNotFound"}} = Jason.decode!(body)
  end

  ## -- helpers ----------------------------------------------------------------

  defp post(base, path, obj) do
    curl(base, path, ["-X", "POST", "-H", "Content-Type: application/json", "--data-binary", Jason.encode!(obj)])
  end

  defp get(base, path), do: curl(base, path, [])

  defp curl(base, path, extra) do
    {out, 0} =
      System.cmd("curl", ["-s", "-w", "\n%{http_code}", "#{base}#{path}" | extra],
        stderr_to_stdout: true
      )

    parts = String.split(String.trim_trailing(out), "\n")
    {String.to_integer(List.last(parts)), Enum.join(Enum.drop(parts, -1), "\n")}
  end
end
