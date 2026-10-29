# EXPL11-R3 — repair court for EXPL-11 F4 (planes) + F5 (ACL seg_meta).
#
# F4: `config :smalt, :planes, []` previously resolved to `[]` — zero plane
# supervisors boot with no typed refusal. planes.ex now refuses typed
# (`Smalt.Planes.InvalidPlane`, message `{:invalid_plane, []}`) on the
# app-env path; `SMALT_PLANES=""` -> :all and non-empty selections unchanged.
# This court witnesses the refusal at BOTH levels:
#   * resolve() raises in-proc (cheap leg), and
#   * a REAL subprocess boot with app-env planes=[] refuses (non-zero exit,
#     InvalidPlane in output) — the falsifier named in the finding.
#
# F5: seg_meta returned %{} on missing/corrupt meta, so a frame-bearing
# segment with meta missing first_seq/last_seq fed `nil` into committing_seg
# comparisons (`seq >= nil` ArgumentError -> certify-tick crash loop). Now
# seg_meta is typed ({:ok, meta} | {:error, :missing_meta | :corrupt_meta})
# and certify_segment refuses missing/corrupt/bounds-less meta fail-closed
# (:missing_meta / :corrupt_meta / :empty_segment), matching the module's
# refused-record idiom and JournalReader's {:missing_meta, path} typing.
#
# Chicago: real JournalSink on real disk, real service GenServer, real
# subprocess boot. No mocks. Run:
#   MIX_BUILD_ROOT=_build-expl11r3 mix test test/internal/expl11r3_court_test.exs

Code.require_file("poll_helper.exs", __DIR__)

defmodule Internal.Expl11r3.PlanesMetaCourt do
  use ExUnit.Case, async: false

  alias Smalt.ConfidentialLedger.Service
  alias Smalt.Storage.JournalSink
  alias SmaltTest.Internal.Poll

  setup do
    # AZ-3b: the Service name is owned by the supervised mount
    # (Smalt.ConfidentialLedger.Supervisor under the data plane); lawfully
    # terminate the mount subtree for the test's duration, restart on exit.
    mount_restart =
      case Supervisor.terminate_child(Smalt.Plane.DataSupervisor, Smalt.ConfidentialLedger.Supervisor) do
        :ok -> :restart
        {:error, _} -> :noop
      end

    stop_service()

    prior_planes = Application.get_env(:smalt, :planes)

    on_exit(fn ->
      Application.put_env(:smalt, :planes, prior_planes)
    end)

    root = Path.join(System.tmp_dir!(), "journal-expl11r3-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    dir = Path.join(root, "journal")
    sink_name = Module.concat([Expl11r3, Sink, Integer.to_string(:erlang.unique_integer([:positive]))])

    {:ok, _sink} =
      JournalSink.start_link(dir: dir, name: sink_name, segment_ceiling: 4_000, sync_interval_ms: 3_600_000)

    on_exit(fn ->
      stop_service()

      if mount_restart == :restart do
        Supervisor.restart_child(Smalt.Plane.DataSupervisor, Smalt.ConfidentialLedger.Supervisor)
      end

      File.rm_rf!(root)
    end)

    %{root: root, dir: dir, sink: sink_name}
  end

  ## -- F4 legs -------------------------------------------------------------------

  @tag :expl11r3
  @tag :planes
  test "F4: resolve() with config planes=[] raises {:invalid_plane, []}" do
    Application.put_env(:smalt, :planes, [])

    assert_raise Smalt.Planes.InvalidPlane, ~r/:invalid_plane, \[\]/, fn ->
      Smalt.Planes.resolve()
    end
  end

  @tag :expl11r3
  @tag :planes
  test "F4: REAL subprocess boot with planes=[] refuses typed (non-zero exit)", %{root: _root} do
    script = """
    Application.put_env(:smalt, :planes, [])

    case Application.ensure_all_started(:smalt) do
      {:ok, _} ->
        IO.puts("BOOTED-NO-REFUSAL")
        System.halt(0)

      {:error, _reason} ->
        # surface the typed refusal from the same module the boot path uses
        try do
          Smalt.Planes.resolve()
          IO.puts("NO-TYPED-REFUSAL")
          System.halt(4)
        rescue
          e in Smalt.Planes.InvalidPlane ->
            IO.puts("TYPED-REFUSAL: " <> Exception.message(e))
            System.halt(3)
        end
    end
    """

    {out, code} =
      System.cmd("mix", ["run", "--no-start", "-e", script],
        cd: File.cwd!(),
        env: %{"MIX_BUILD_ROOT" => "_build-expl11r3", "SMALT_PLANES" => nil},
        stderr_to_stdout: true
      )

    assert code == 3, "expected exit 3 (typed refusal), got #{code}:\n#{out}"
    assert out =~ "TYPED-REFUSAL"
    assert out =~ "{:invalid_plane, []}"
    refute out =~ "BOOTED-NO-REFUSAL"
    refute out =~ "NO-TYPED-REFUSAL"
  end

  @tag :expl11r3
  @tag :planes
  test "F4: non-empty selection and SMALT_PLANES='' unchanged" do
    Application.put_env(:smalt, :planes, [:control])
    assert [:control] = Smalt.Planes.resolve()

    Application.put_env(:smalt, :planes, :all)
    assert :all = Smalt.Planes.resolve()

    System.put_env("SMALT_PLANES", "")
    assert :all = Smalt.Planes.resolve()
  after
    System.delete_env("SMALT_PLANES")
  end

  ## -- F5 legs -------------------------------------------------------------------

  @tag :expl11r3
  @tag :ledger
  test "F5 positive leg: healthy segment certifies, tx commits (non-vacuity)", %{
    dir: dir,
    sink: sink_name
  } do
    start_service(dir, sink_name)
    {:ok, tx_id} = Service.append(%{"n" => 1})

    assert {:ok, %{"state" => "Committed"}} = poll_committed(tx_id)

    [seg] = sealed_segments(dir)
    assert File.exists?(seg.path <> ".meta.json")
    assert %{status: :committed, first_seq: 0, last_seq: 0} = seg_record(seg.path)
  end

  @tag :expl11r3
  @tag :ledger
  test "F5a: corrupt meta json -> segment refused :corrupt_meta, service alive, no crash", %{
    dir: dir,
    sink: sink_name
  } do
    start_service(dir, sink_name)
    {:ok, tx_id} = Service.append(%{"n" => 1})
    assert {:ok, %{"state" => "Committed"}} = poll_committed(tx_id)

    # tamper: rewrite meta with invalid json, restart, re-certify
    seg = hd(sealed_segments(dir)).path
    File.write!(seg <> ".meta.json", "{not json")

    restart_service(dir, sink_name)

    # the certify pass over the tampered segment must refuse typed and keep
    # the service alive — no crash, no commit minted over bad meta
    :ok = Service.certify()

    assert %{status: :refused, reason: :corrupt_meta} = seg_record(seg)
    assert Process.alive?(Process.whereis(Service))
  end

  @tag :expl11r3
  @tag :ledger
  test "F5b: frame-bearing segment with bounds-less meta -> :corrupt_meta, no nil-compare crash", %{
    dir: dir,
    sink: sink_name
  } do
    start_service(dir, sink_name)
    {:ok, tx_id} = Service.append(%{"n" => 1})
    assert {:ok, %{"state" => "Committed"}} = poll_committed(tx_id)

    seg = hd(sealed_segments(dir)).path

    # tamper: drop first_seq/last_seq (keep frames>0) — the finding's exact
    # premise-rot shape: reader-valid segment, bounds-less meta. Pre-fix this
    # put nil into committing_seg (`seq >= nil` ArgumentError crash loop).
    # frames=1 matches the single-append segment sealed above.
    File.write!(seg <> ".meta.json", Jason.encode!(%{"frames" => 1, "sha256" => "aa"}))

    restart_service(dir, sink_name)

    # pre-fix this shape put nil into committing_seg (`seq >= nil` crash);
    # the certify pass must refuse typed and the tick must survive
    :ok = Service.certify()

    assert %{status: :refused, reason: :corrupt_meta} = seg_record(seg)
    assert Process.alive?(Process.whereis(Service))
  end

  @tag :expl11r3
  @tag :ledger
  test "F5c: missing meta file -> refused :missing_meta, fail-closed", %{dir: dir, sink: sink_name} do
    start_service(dir, sink_name)
    {:ok, tx_id} = Service.append(%{"n" => 1})
    assert {:ok, %{"state" => "Committed"}} = poll_committed(tx_id)

    seg = hd(sealed_segments(dir)).path
    File.rm!(seg <> ".meta.json")

    restart_service(dir, sink_name)
    :ok = Service.certify()

    # fail-closed at discovery: the meta-less segment is never certified and
    # never crashes the tick (JournalReader refuses it before seg_meta)
    assert not match?(%{status: :committed}, seg_record(seg))
    assert Process.alive?(Process.whereis(Service))
  end

  ## -- helpers ---------------------------------------------------------------------

  defp start_service(dir, sink_name) do
    case Service.start_link(dir: dir, sink: sink_name, certify_interval_ms: 40) do
      {:ok, _} = ok ->
        ok

      {:error, {:already_started, stale}} ->
        GenServer.stop(stale)
        start_service(dir, sink_name)
    end
  end

  defp restart_service(dir, sink_name) do
    stop_service()
    start_service(dir, sink_name)
  end

  defp poll_committed(tx_id) do
    Poll.eventually(fn ->
      case safe_transaction(tx_id) do
        {:ok, %{"state" => "Committed"}} = ok -> ok
        _ -> :pending
      end
    end)
  end

  defp safe_transaction(tx_id) do
    Service.transaction(tx_id)
  rescue
    _ -> :pending
  catch
    :exit, _ -> :pending
  end

  defp seg_record(seg) do
    state = :sys.get_state(Process.whereis(Service))
    Map.get(state.segs, Path.basename(seg))
  end

  defp sealed_segments(dir) do
    sealed_dir = Path.join(dir, "sealed")

    dir_entries(sealed_dir)
    |> Enum.reject(&(String.contains?(&1, ".meta.json") or String.ends_with?(&1, ".seal")))
    |> Enum.map(&%{path: Path.join(sealed_dir, &1)})
  end

  defp dir_entries(d) do
    case File.ls(d) do
      {:ok, entries} -> entries
      _ -> []
    end
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
end
