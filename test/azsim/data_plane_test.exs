defmodule Smalt.Azsim.DataPlaneTest do
  @moduledoc """
  AZB-06 — Data plane profile (Cosmos SQL + Blob hot tier) acceptance courts.

  Covers the ticket Accept list at the engine and wire surfaces:

    * If-Match contention: 6 concurrent replaces on one ETag ⇒ exactly
      `1×200 + 5×412`, across 100 iterations (Store CAS, no TOCTOU).
    * Range GET: 206 + exact `Content-Range` over the wire.
    * Conditional HEAD/GET with `If-None-Match` and `If-Modified-Since`.
    * `sync_interval_ms: 0` durability: acknowledged write → SIGKILL of the
      writing VM → reboot on the mirror ⇒ object present (real child OS beam,
      event-driven ack, zero `Process.sleep`).
    * Profile read sites: `:cosmos max_ru_limit` (incl. `:unbounded`) mapping
      onto the flat `:cosmos_ru_limit` key; `:blob_storage` persistence /
      `sync_interval_ms` gating `DetsMirror.sync_write/2`.
  """

  use ExUnit.Case, async: false
  use Plug.Test

  alias Smalt.DataPlane.BlobStorage
  alias Smalt.DataPlane.Cosmos
  alias Smalt.EgressRouter
  alias Smalt.Store
  alias Smalt.Store.DetsMirror

  setup do
    SmaltTest.Lifecycle.ensure_store_up()
    BlobStorage.ensure_policy_table()
    :ok
  end

  # ---------------------------------------------------------------------------
  # If-Match contention: exactly 1 winner per 6-way race × 100 iterations
  # ---------------------------------------------------------------------------

  describe "if-match 6-way replace race" do
    test "100 iterations of {200:1, 412:5}" do
      account = "azb06race"
      container = "r"
      blob = "stadium"
      blob_key = "#{account}/#{container}/#{blob}"

      {:ok, _} = BlobStorage.create_container(account, container, %{"immutable" => false})
      {:ok, _} = BlobStorage.put_blob(account, container, blob, "seed")

      tally =
        Enum.reduce(1..100, 0, fn i, acc ->
          {:ok, current} = Store.get(:smalt_blobs, blob_key)
          etag = current["etag"]

          results =
            1..6
            |> Enum.map(fn n ->
              Task.async(fn ->
                case BlobStorage.put_blob(account, container, blob, "winner-#{i}-#{n}", %{
                       "if-match" => etag
                     }) do
                  {:ok, _blob} -> 200
                  {:error, :precondition_failed, _} -> 412
                  other -> {:other, other}
                end
              end)
            end)
            |> Task.await_many(30_000)

          counts = Enum.frequencies(results)
          assert counts == %{200 => 1, 412 => 5}, "iteration #{i}: #{inspect(results)}"

          # The iteration's winner moved the etag off the raced value.
          {:ok, after} = Store.get(:smalt_blobs, blob_key)
          assert after["etag"] != etag

          acc + 1
        end)

      assert tally == 100
    end
  end

  # ---------------------------------------------------------------------------
  # Range GET over the wire: 206 + Content-Range
  # ---------------------------------------------------------------------------

  describe "range GET (wire)" do
    @content "abcdefghijklmnopqrstuvwxyz"

    test "mid-slice returns 206 + exact Content-Range" do
      account = "azb06range"
      container = "r"
      {:ok, _} = BlobStorage.create_container(account, container, %{"immutable" => false})
      {:ok, _} = BlobStorage.put_blob(account, container, "r.bin", @content)

      conn =
        :get
        |> conn("/#{account}/#{container}/r.bin")
        |> put_req_header("range", "bytes=10-15")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert conn.status == 206
      assert get_resp_header(conn, "content-range") == ["bytes 10-15/26"]
      assert conn.resp_body == "klmnop"
    end

    test "suffix range bytes=-5 returns 206 + Content-Range" do
      account = "azb06range"
      {:ok, _} = BlobStorage.put_blob(account, "r", "s.bin", @content)

      conn =
        :get
        |> conn("/azb06range/r/s.bin")
        |> put_req_header("range", "bytes=-5")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert conn.status == 206
      assert get_resp_header(conn, "content-range") == ["bytes 21-25/26"]
      assert conn.resp_body == "vwxyz"
    end
  end

  # ---------------------------------------------------------------------------
  # Conditional HEAD/GET: If-None-Match + If-Modified-Since
  # ---------------------------------------------------------------------------

  describe "conditional HEAD/GET" do
    test "If-None-Match match -> 304 over the wire; mismatch serves 200" do
      account = "azb06cond"
      {:ok, _} = BlobStorage.create_container(account, "c", %{"immutable" => false})
      {:ok, blob} = BlobStorage.put_blob(account, "c", "k", "payload")

      conn =
        :get
        |> conn("/#{account}/c/k")
        |> put_req_header("if-none-match", blob["etag"])
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert conn.status == 304
      assert get_resp_header(conn, "etag") == [blob["etag"]]

      conn =
        :get
        |> conn("/#{account}/c/k")
        |> put_req_header("if-none-match", "\"deadbeef\"")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert conn.status == 200
      assert conn.resp_body == "payload"
    end

    test "If-Modified-Since: unmodified -> 304, modified-after -> 200, engine shapes" do
      account = "azb06ims"
      {:ok, _} = BlobStorage.create_container(account, "c", %{"immutable" => false})
      {:ok, blob} = BlobStorage.put_blob(account, "c", "k", "ims-payload")
      {:ok, lm, _off} = DateTime.from_iso8601(blob["last_modified"])

      past = lm |> DateTime.add(-3_600) |> http_date()
      future = lm |> DateTime.add(3_600) |> http_date()

      # Engine surface: modified after `past` ⇒ serve; not modified after
      # `future` ⇒ {:not_modified, etag}.
      assert {:ok, _} =
               BlobStorage.get_blob_conditional(account, "c", "k", %{
                 "if-modified-since" => past
               })

      assert {:not_modified, blob["etag"]} =
               BlobStorage.get_blob_conditional(account, "c", "k", %{
                 "if-modified-since" => future
               })

      # Wire surface: same verdicts ride the router (HEAD uses the same
      # conditional engine).
      head =
        :head
        |> conn("/#{account}/c/k")
        |> put_req_header("if-modified-since", future)
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert head.status == 304

      get =
        :get
        |> conn("/#{account}/c/k")
        |> put_req_header("if-modified-since", past)
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert get.status == 200
      assert get.resp_body == "ims-payload"
    end
  end

  # ---------------------------------------------------------------------------
  # Profile read sites: cosmos max_ru_limit / blob_storage persistence
  # ---------------------------------------------------------------------------

  describe "profile read sites" do
    test "cosmos max_ru_limit: integer profile throttles, :unbounded does not" do
      Application.put_env(:smalt, :cosmos, max_ru_limit: 1)
      Application.put_env(:smalt, :cosmos_ru_limit, 1)

      on_exit(fn ->
        Application.delete_env(:smalt, :cosmos)
        Application.delete_env(:smalt, :cosmos_ru_limit)
      end)

      Cosmos.define_container("azb06ru", "c", ["id"])

      verdicts =
        for _ <- 1..30 do
          case Cosmos.create_doc("azb06ru", "c", %{"id" => "d#{System.unique_integer()}"}, %{}) do
            {:ok, 201, _, _} -> :created
            {:ok, 429, _, _} -> :throttled
            other -> {:other, other}
          end
        end

      assert :throttled in verdicts, "expected at least one 429 under max_ru_limit: 1"

      # :unbounded (the az_prod_data.exs profile value) lifts the throttle
      # even with a restrictive flat key set.
      Application.put_env(:smalt, :cosmos, max_ru_limit: :unbounded)

      verdicts =
        for _ <- 1..30 do
          case Cosmos.create_doc("azb06ru", "c", %{"id" => "d#{System.unique_integer()}"}, %{}) do
            {:ok, 201, _, _} -> :created
            {:ok, 429, _, _} -> :throttled
            other -> {:other, other}
          end
        end

      refute :throttled in verdicts
    end

    test "blob_storage sync_write gate: profile-gated, no mirror => :ok, no crash" do
      Application.put_env(:smalt, :blob_storage, persistence: :dets_mirrored, sync_interval_ms: 0)

      on_exit(fn -> Application.delete_env(:smalt, :blob_storage) end)

      # Gate armed but no mirror process running (whereis undefined) — the
      # write path must degrade to :ok, never crash the caller.
      assert :ok = DetsMirror.sync_write(:smalt_blobs)

      # Any other profile state is a no-op by construction.
      Application.put_env(:smalt, :blob_storage, persistence: :dets_mirrored, sync_interval_ms: 5_000)
      assert :ok = DetsMirror.sync_write(:smalt_blobs)

      Application.put_env(:smalt, :blob_storage, persistence: :local, sync_interval_ms: 0)
      assert :ok = DetsMirror.sync_write(:smalt_blobs)
    end
  end

  # ---------------------------------------------------------------------------
  # Durability: acknowledged write -> SIGKILL -> reboot on mirror => present
  # ---------------------------------------------------------------------------

  describe "sync_interval_ms: 0 durability (SIGKILL)" do
    @tag :azb06_sigkill
    test "acknowledged write survives kill -9 of the writing VM" do
      unique = System.unique_integer([:positive])
      dir = Path.join(System.tmp_dir(), "azb06-durab-#{unique}")
      marker = Path.join(dir, "MARKER")
      File.mkdir_p!(dir)

      elixir = System.find_executable("elixir") || raise("elixir not on PATH")
      pa_args = Enum.flat_map(:code.get_path(), &["-pa", to_string(&1)])

      script = """
      dir = System.get_env("AZB06_DIR")
      marker = System.get_env("AZB06_MARKER")

      Application.put_env(:smalt, :blob_storage, persistence: :dets_mirrored, sync_interval_ms: 0)

      {:ok, _} = Smalt.Store.start_link([])
      {:ok, _} =
        Smalt.Store.DetsMirror.start_link(dir: dir, tables: [:smalt_blobs], repair: true)

      {:ok, _} =
        Smalt.DataPlane.BlobStorage.create_container("durab", "c", %{"immutable" => false})

      {:ok, _} =
        Smalt.DataPlane.BlobStorage.put_blob("durab", "c", "k", "survivor-payload")

      # Ack marker AFTER put_blob returned: with sync_interval_ms: 0 the
      # mirror fsync has ALREADY happened inside the write path. The ack is
      # delivered to the parent EVENT-DRIVEN via the port pipe.
      File.write!(marker, "acked")
      IO.puts("ACKED")
      receive do after :infinity -> :ok end
      """

      port =
        Port.open(
          {:spawn_executable, elixir},
          [
            {:args, pa_args ++ ["--no-halt", "-e", script]},
            {:env, [
              {~c"AZB06_DIR", to_charlist(dir)},
              {~c"AZB06_MARKER", to_charlist(marker)}
            ]},
            :binary,
            :exit_status
          ]
        )

      # Event-driven ack (no sleep, no polling): the child writes the marker
      # file, then prints ACKED on the port pipe; the parent blocks in a
      # deadline receive.
      ack =
        receive do
          {^port, {:data, "ACKED" <> _}} -> :acked
        after
          120_000 -> raise "child never acknowledged the write"
        end

      assert ack == :acked

      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> to_string(pid)
          :undefined -> raise "child already exited before SIGKILL"
        end

      {_, 0} = System.cmd("kill", ["-9", os_pid])

      receive do
        {^port, :closed} -> :ok
      after
        30_000 -> raise "child port never closed after SIGKILL"
      end

      # Reboot leg: fresh mirror over the SIGKILLed dir (repair: true — the
      # child never got to close its :dets files), restore into this VM's
      # Store, assert the acknowledged object is present.
      {:ok, mirror} =
        DetsMirror.start_link(
          dir: dir,
          tables: [:smalt_blobs],
          repair: true,
          name: Azb06RebootMirror
        )

      on_exit(fn ->
        File.rm_rf(dir)

        if Process.whereis(Azb06RebootMirror) do
          GenServer.stop(Azb06RebootMirror)
        end
      end)

      assert {:ok, counts} = DetsMirror.restore(Azb06RebootMirror)
      assert counts[:smalt_blobs] >= 1

      assert {:ok, blob} = Store.get(:smalt_blobs, "durab/c/k")
      assert blob["content"] == "survivor-payload"

      GenServer.stop(mirror)
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp router_call(conn) do
    SmaltTest.Lifecycle.ensure_store_up()
    EgressRouter.call(conn, EgressRouter.init([]))
  end

  defp http_date(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
  end
end
