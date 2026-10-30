# G26 turnstile fence court (lane 39, option (a)).
#
# Chicago discipline: real in-process dispatch through Smalt.ArmGateway.Router,
# real parsed body (Plug.Parsers + BodyCache), real Admission, real
# Smalt.Posh.Turnstile.admit/5, real append-only EventLog file. No mocks.
#
# Falsifier (G26): BEFORE this landing, a mutating unreceipted delta on 9443
# was admitted (stamp-only plug, dead pipeline layer) — step 1 below FAILED on
# the pre-landing tree and PASSES only because the fence landed. Post-landing
# non-vacuity (shim-court): removing the router's `plug(..., :fence)` mount or
# the plug's admission branch re-fails step 1 (and the :disabled branch of
# `fence gate flip` below proves the config gate actually gates).
defmodule Smalt.Posh.TurnstileFenceCourtTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  # v26.10.31 inversion (WO-06): the fence SEMANTICS are pinned here, not
  # the gateway module location. `@router_module` is the dialect gateway
  # seam — the strip wave re-points it (one attribute edit) if the ARM
  # gateway relocates; the admission/stamp/settle assertions below are
  # location-agnostic.
  @router_module Smalt.ArmGateway.Router

  alias Smalt.Posh.Egress.{EventLog, Settlement}

  @sub "sub-fence-lane39"
  @av "api-version=2021-04-01"

  setup do
    dir = Path.join(System.tmp_dir!(), "fence-court-#{:erlang.unique_integer([:positive])}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    log = :"fence_log_#{:erlang.unique_integer([:positive])}"

    Application.put_env(:smalt, :turnstile_fence,
      enabled: true,
      log_name: log,
      dir: dir
    )

    on_exit(fn ->
      Application.delete_env(:smalt, :turnstile_fence)
      File.rm_rf!(dir)
    end)

    %{dir: dir, log: log}
  end

  test "unreceipted mutating delta (non-object JSON body) is REFUSED 400 AdmissionRefused, still stamped, and settled into the event log",
       %{dir: dir} do
    raw = "[]"

    conn =
      :post
      |> conn("/subscriptions/#{@sub}/resourcegroups/rg-x?#{@av}", raw)
      |> put_req_header("content-type", "application/json")
      |> @router_module.call([])

    # 1. Refusal: typed ARM 400, not 2xx.
    assert conn.status == 400,
           "expected fence refusal, got #{conn.status}: #{conn.resp_body}"
    assert %{"error" => %{"code" => "AdmissionRefused"}} = Jason.decode!(conn.resp_body)

    # ... and the refusal response still carries the stamped header, whose
    # digest binds op || u64BE(ts) || raw body.
    ts = String.to_integer(get_resp_header(conn, "x-smalt-receipt-timestamp") |> List.first())
    header_hex = get_resp_header(conn, "x-smalt-receipt-turnstile") |> List.first()

    assert header_hex ==
             Base.encode16(Settlement.digest("arm.request", ts, raw), case: :lower)

    # 2. Settlement: the refusal receipt is IN the event log, not just on the
    # wire — same digest as the header, chained into the append-only file.
    entries = EventLog.read_all(dir)

    assert Enum.any?(entries, fn e ->
             e["kind"] == "refusal" and e["receipt"] == header_hex and
               e["timestamp_ns"] == ts
           end)
  end

  test "admitted mutating delta passes the fence (object body proceeds to the router, no AdmissionRefused)" do
    conn =
      :put
      |> conn("/subscriptions/#{@sub}/resourcegroups/rg-ok?#{@av}", Jason.encode!(%{}))
      |> put_req_header("content-type", "application/json")
      |> @router_module.call([])

    assert get_resp_header(conn, "x-smalt-receipt-turnstile") != []
    code = Jason.decode!(conn.resp_body)["error"]["code"]

    assert conn.status != 400 or code != "AdmissionRefused",
           "fence refused an object-body delta: status=#{conn.status} code=#{code} body=#{conn.resp_body}"

    # The fence's admitted path settles a real receipt for the delta into the
    # log (Turnstile.admit -> Settlement.settle).
  end

  test "fence gate flip: with the fence DISABLED the same unreceipted delta is NOT refused by the turnstile" do
    Application.put_env(:smalt, :turnstile_fence,
      enabled: false,
      log_name: :"fence_log_off_#{:erlang.unique_integer([:positive])}",
      dir: Path.join(System.tmp_dir!(), "fence-off-#{:erlang.unique_integer([:positive])}")
    )

    conn =
      :post
      |> conn("/subscriptions/#{@sub}/resourcegroups/rg-x?#{@av}", "[]")
      |> put_req_header("content-type", "application/json")
      |> @router_module.call([])

    # The fence never ran: no AdmissionRefused (whatever the router itself
    # answers, the turnstile did not halt this conn).
    code =
      case Jason.decode(conn.resp_body) do
        {:ok, %{"error" => %{"code" => c}}} -> c
        _ -> nil
      end

    assert code != "AdmissionRefused"
  end

  test "GET stays stamp-only: exempt from admission, header still present" do
    conn =
      :get
      |> conn("/subscriptions/#{@sub}/resourcegroups?#{@av}")
      |> @router_module.call([])

    assert conn.status == 200

    ts = String.to_integer(get_resp_header(conn, "x-smalt-receipt-timestamp") |> List.first())
    header_hex = get_resp_header(conn, "x-smalt-receipt-turnstile") |> List.first()

    assert header_hex == Base.encode16(Settlement.digest("arm.request", ts, ""), case: :lower)
  end
end
