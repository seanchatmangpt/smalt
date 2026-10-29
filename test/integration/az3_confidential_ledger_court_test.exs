# AZ-3 — Azure Confidential Ledger REST face over the journal substrate.
# Real-HTTP court: real Bandit listener, real JournalSink on real disk, real
# Service certification (seal ladder + sha256-chain), real curl wire calls.
# No mocks. Asserts on wire status codes + on-disk bytes + recomputed chain.
#
# Run: MIX_BUILD_ROOT=_build-az3 mix test test/integration/az3_confidential_ledger_court_test.exs

Code.require_file("poll_helper.exs", Path.join(__DIR__, "../internal"))

defmodule Az3.Court do
  use ExUnit.Case, async: false

  alias Smalt.ConfidentialLedger.Service
  alias Smalt.Storage.JournalReader
  alias Smalt.Storage.JournalSink
  alias SmaltTest.Internal.Poll
  alias Smalt.Sync.Receipt

  setup ctx do
    # AZ-3b: the Service name is now owned by the supervised mount
    # (Smalt.ConfidentialLedger.Supervisor under the data plane). The
    # private-instance legs below (tamper/crash/degraded) need to own that
    # name, so the mount subtree is lawfully terminated for the test's
    # duration and restarted on exit — never a name fight with the
    # supervisor (which one_for_one would otherwise win).
    mount_restart =
      case Supervisor.terminate_child(Smalt.Plane.DataSupervisor, Smalt.ConfidentialLedger.Supervisor) do
        :ok ->
          :restart

        {:error, _} ->
          :noop
      end

    # one fixed-name Service per VM: stop any prior instance, fresh tmp dir
    stop_service()

    root = Path.join(System.tmp_dir!(), "journal-az3-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    dir = Path.join(root, "journal")
    sink_name = Module.concat([Az3.Sink, Integer.to_string(:erlang.unique_integer([:positive]))])

    {:ok, _sink} =
      # the sink stays alive under its registered name for the whole test

      JournalSink.start_link(dir: dir, name: sink_name, segment_ceiling: 4_000, sync_interval_ms: 3_600_000)

    {:ok, _svc} =
      case Service.start_link(dir: dir, sink: sink_name, certify_interval_ms: 40) do
        {:ok, _} = ok ->
          ok

        # on_exit cleanup runs concurrently with the next setup: retire the
        # leftover instance and boot ours (fixed process name)
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

      # AZ-3b: restore the supervised mount after the private-instance legs
      if mount_restart == :restart do
        Supervisor.restart_child(Smalt.Plane.DataSupervisor, Smalt.ConfidentialLedger.Supervisor)
      end

      File.rm_rf!(root)
    end)

    %{base: base, dir: dir, sink: sink_name}
  end

  ## -- legs -------------------------------------------------------------------

  @tag :az3
  test "ACL face: append 5, poll Committed, receipts verify against the recomputed chain, range + pagination", %{
    base: base,
    dir: dir
  } do
    ids =
      for i <- 1..5 do
        {201, body} = post(base, "/app/transactions", %{"contents" => %{"n" => i}})
        decoded = Jason.decode!(body)

        # D7 envelope parity: the documented ACL append 201 carries the full
        # {transactionId, contents, subLedgerId, timestamp} envelope.
        %{"transactionId" => id, "contents" => contents_echo, "subLedgerId" => sub, "timestamp" => ts} =
          decoded

        assert contents_echo == %{"n" => i}
        assert is_binary(sub) and sub != ""
        assert match?({:ok, _, _}, DateTime.from_iso8601(ts))
        assert Regex.match?(~r/^\d+\.1$/, id)
        id
      end

    assert ids == Enum.uniq(ids)

    # certification = the existing seal ladder + chain; convergence is polled
    # through the ONE audited bounded poll (no-sleep doctrine)
    for id <- ids do
      assert {:ok, body} = poll_committed(base, id)

      %{"state" => "Committed", "entry" => %{"contents" => contents, "transactionId" => ^id}} =
        Jason.decode!(body)

      assert contents["n"] in 1..5
    end

    # receipts verify against the recomputed chain from the on-disk sealed
    # segments (FRE-902(14)-class root verification)
    expected = recompute(dir)

    for id <- ids do
      {200, body} = get(base, "/app/transactions/#{id}/receipt?api-version=2022-05-17")
      assert %{"receipt" => %{"leaf" => leaf, "root" => root_hex, "proof" => proof} = r} = Jason.decode!(body)

      seg = Enum.find(expected, fn rec -> id_seq(id) in rec.range end)
      assert root_hex == seg.root
      assert leaf == seg.leaves[id_seq(id)]
      # refold the full-witness proof: chain over the proof leaves == root
      assert refold(proof) == root_hex
      assert r["receiptToken"] == Receipt.mint(%{root: seg.root_bin, count: length(proof)})
    end

    # range query over the wire
    {200, body} = get(base, "/app/transactions?api-version=2022-05-17&rangeBegin=2.1&rangeEnd=4.1")
    %{"transactions" => txs, "nextRangeLink" => nil} = Jason.decode!(body)
    assert Enum.map(txs, & &1["transactionId"]) == ["2.1", "3.1", "4.1"]

    # pagination at the service face
    assert {:ok, %{"transactions" => page1, "nextRangeLink" => next}} = Service.transactions(nil, nil, 2)
    assert length(page1) == 2
    assert next =~ "rangeBegin="

    assert {:ok, page2} = Service.transactions(next_range(next), nil, 2)
    assert page2["transactions"] != []
  end

  @tag :az3
  test "warm-replay leg: two identical appends both commit with distinct transaction ids (real-Azure law)", %{
    base: base,
    dir: dir
  } do
    contents = %{"n" => 1, "leg" => "replay"}

    ids =
      for _ <- 1..2 do
        {201, body} = post(base, "/app/transactions", %{"contents" => contents})
        Jason.decode!(body)["transactionId"]
      end

    # real Azure returns a NEW transactionId per append — no identical-
    # contents dedupe, no 409 LedgerItemAlreadyExists on warm reruns.
    assert length(ids) == 2
    assert ids == Enum.uniq(ids)

    # chain audit still intact: both entries poll Committed, both receipts
    # verify against the recomputed on-disk chain (2 journal frames).
    for id <- ids do
      assert {:ok, body} = poll_committed(base, id)

      %{"state" => "Committed", "entry" => %{"contents" => ^contents}} = Jason.decode!(body)
    end

    expected = recompute(dir)

    # every receipt leaf must be a real journal frame leaf of the on-disk
    # chain (both entries present, distinct), and every proof must refold
    # to its segment root — the chain audit is intact.
    all_leaves = expected |> Enum.flat_map(&Map.values(&1.leaves)) |> MapSet.new()
    all_roots = MapSet.new(expected, & &1.root)

    leaves =
      for id <- ids do
        {200, body} = get(base, "/app/transactions/#{id}/receipt?api-version=2022-05-17")
        assert %{"receipt" => %{"leaf" => leaf, "root" => root_hex, "proof" => proof}} = Jason.decode!(body)

        assert MapSet.member?(all_roots, root_hex)
        assert MapSet.member?(all_leaves, leaf)
        assert refold(proof) == root_hex
        leaf
      end

    assert leaves == Enum.uniq(leaves)
  end

  @tag :az3
  test "tamper leg: flipping a byte in a sealed segment typed-refuses (SJ-2 law)", %{base: base, dir: dir} do
    {201, body} = post(base, "/app/transactions", %{"contents" => %{"n" => 1, "leg" => "tamper"}})
    %{"transactionId" => id} = Jason.decode!(body)
    assert {:ok, _} = poll_committed(base, id)

    {200, ok_body} = get(base, "/app/transactions/#{id}/receipt")
    assert %{"receipt" => %{"leaf" => _}} = Jason.decode!(ok_body)

    # tamper: flip one byte in the sealed segment on disk
    [seg] = Path.wildcard(Path.join(dir, "sealed/*.journal"))
    bin = File.read!(seg)
    <<pre::binary-size(10), b::size(8), post::binary>> = bin
    File.write!(seg, <<pre::binary, Bitwise.bxor(b, 1)::size(8), post::binary>>)

    {409, body} = get(base, "/app/transactions/#{id}/receipt")
    assert %{"error" => %{"code" => "LedgerIntegrityFailure"}} = Jason.decode!(body)

    {409, body2} = get(base, "/app/transactions/#{id}")
    assert %{"error" => %{"code" => "LedgerIntegrityFailure"}} = Jason.decode!(body2)
  end

  @tag :az3
  test "crash leg: sentinel withheld (BK-54 class) -> tx stays Pending, never silently committed", %{
    base: base,
    dir: dir,
    sink: sink
  } do
    # tick off: build the crash state deterministically
    restart_for_crash_leg(dir, sink)

    {201, body} = post(base, "/app/transactions", %{"contents" => %{"n" => 1, "crash" => true}})
    %{"transactionId" => id} = Jason.decode!(body)

    # seal through the real ladder, then withhold the sentinel (the exact
    # SPOF-A3 crash state: a sealed/ segment missing its .seal)
    assert is_map(JournalSink.seal(sink))
    Enum.each(Path.wildcard(Path.join(dir, "sealed/*.journal.seal")), &File.rm!/1)

    # certification pass: discovery quarantines the incomplete triple
    :ok = Service.certify()
    assert Path.wildcard(Path.join(dir, "quarantine/*.journal")) != []

    # the tx is NOT committed: state Pending, receipt typed-refused
    {200, body} = get(base, "/app/transactions/#{id}")
    assert %{"state" => "Pending"} = Jason.decode!(body)

    {409, body} = get(base, "/app/transactions/#{id}/receipt")
    assert %{"error" => %{"code" => "TransactionNotCertified"}} = Jason.decode!(body)
  end

  @tag :az3
  test "degraded sink: append answers 503 LedgerDegraded and records NO transaction (A-1 law)", %{
    base: base,
    dir: dir,
    sink: sink
  } do
    GenServer.stop(Service)
    GenServer.stop(sink)
    await_gone(Service)
    await_gone(sink)

    # real disk-error injection: regular file where active/ must be a dir —
    # injected BEFORE the fresh sink boots, or the old fd keeps serving
    File.rm_rf!(Path.join(dir, "active"))
    File.write!(Path.join(dir, "active"), "not-a-dir")

    {:ok, _sink3} =
      JournalSink.start_link(dir: dir, name: sink, segment_ceiling: 4_000, sync_interval_ms: 3_600_000)

    {:ok, _} =
      case Service.start_link(dir: dir, sink: sink, certify_interval_ms: 0) do
        {:ok, _} = ok -> ok
        {:error, {:already_started, stale}} -> GenServer.stop(stale) && Service.start_link(dir: dir, sink: sink, certify_interval_ms: 0)
      end

    {503, body} = post(base, "/app/transactions", %{"contents" => %{"n" => 1}})
    assert %{"error" => %{"code" => "LedgerDegraded"}} = Jason.decode!(body)
    assert {:ok, %{"transactions" => []}} = Service.transactions(nil, nil, 100)
  end

  @tag :az3
  test "certificate leg: VC 2.0 export verifies round-trip", %{base: base} do
    {201, body} = post(base, "/app/transactions", %{"contents" => %{"n" => 1, "leg" => "vc"}})
    %{"transactionId" => id} = Jason.decode!(body)
    assert {:ok, _} = poll_committed(base, id)

    {200, body} = get(base, "/app/transactions/#{id}/certificate")
    vc = Jason.decode!(body)
    assert "https://www.w3.org/ns/credentials/v2" in List.wrap(vc["@context"])
    assert "MerkleReceiptCredential" in vc["type"]
    assert vc["proof"]["cryptosuite"] == "smalt-rs256-jws"
    assert {:ok, _subject} = Smalt.Receipt.VcExport.verify_vc(vc)
  end

  @tag :az3
  test "404 unknown transaction", %{base: base} do
    {404, body} = get(base, "/app/transactions/9999.1")
    assert %{"error" => %{"code" => "TransactionNotFound"}} = Jason.decode!(body)
  end

  ## -- helpers ----------------------------------------------------------------

  # retire the setup pair and boot a fresh one on the same names/dir
  defp restart_for_crash_leg(dir, sink) do
    GenServer.stop(Service)
    GenServer.stop(sink)
    await_gone(Service)
    await_gone(sink)

    {:ok, _sink2} =
      JournalSink.start_link(dir: dir, name: sink, segment_ceiling: 4_000, sync_interval_ms: 3_600_000)

    {:ok, _} =
      case Service.start_link(dir: dir, sink: sink, certify_interval_ms: 0) do
        {:ok, _} = ok -> ok
        {:error, {:already_started, stale}} -> GenServer.stop(stale) && Service.start_link(dir: dir, sink: sink, certify_interval_ms: 0)
      end
  end

  defp await_gone(name) do
    Poll.eventually(fn ->
      if Process.whereis(name), do: :pending, else: {:ok, :gone}
    end)
  end

  defp stop_service do
    case Process.whereis(Service) do
      nil ->
        :ok

      pid ->
        GenServer.stop(pid)
        :ok
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

  defp poll_committed(base, id) do
    Poll.eventually(fn ->
      case get(base, "/app/transactions/#{id}?api-version=2022-05-17") do
        {200, b} ->
          case Jason.decode(b) do
            {:ok, %{"state" => "Committed"}} -> {:ok, b}
            _ -> :pending
          end

        _ ->
          :pending
      end
    end)
  end

  # recompute the chain from the on-disk sealed segments
  defp recompute(dir) do
    {:ok, segs} = JournalReader.discover_sealed_segments(dir)

    Enum.map(segs, fn seg ->
      {:ok, frames} = JournalReader.read_sealed_segment(seg)

      {chain, leaves} =
        Enum.reduce(frames, {Receipt.empty_chain(), %{}}, fn f, {chain, leaves} ->
          wire =
            elem(
              JournalSink.encode_frame(f.seq_id, f.ts, f.event_type, f.table_id, f.key, f.payload),
              0
            )

          leaf = :crypto.hash(:sha256, wire)
          {Receipt.absorb(chain, wire), Map.put(leaves, f.seq_id, Base.encode16(leaf, case: :lower))}
        end)

      meta = Jason.decode!(File.read!(seg <> ".meta.json"))

      %{
        range: Range.new(meta["first_seq"], meta["last_seq"]),
        root: Base.encode16(chain.root, case: :lower),
        root_bin: chain.root,
        leaves: leaves
      }
    end)
  end

  defp refold(proof) do
    Enum.reduce(proof, nil, fn %{"leaf" => leaf_hex}, root_bin ->
      leaf = Base.decode16!(leaf_hex, case: :lower)

      if is_nil(root_bin) do
        :crypto.hash(:sha256, leaf)
      else
        :crypto.hash(:sha256, root_bin <> leaf)
      end
    end)
    |> case do
      nil -> nil
      root -> Base.encode16(root, case: :lower)
    end
  end

  defp id_seq(id) do
    [seq | _] = String.split(id, ".")
    String.to_integer(seq)
  end

  defp next_range(next) do
    ["rangeBegin=" <> rb | _] = String.split(next, "&") |> Enum.filter(&String.starts_with?(&1, "rangeBegin="))
    rb
  end

  # -- curl wire helpers (real HTTP, no client mocks) ---------------------------

  defp post(base, path, obj) do
    curl(base, path, [
      "-X",
      "POST",
      "-H",
      "Content-Type: application/json",
      "--data-binary",
      Jason.encode!(obj)
    ])
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
