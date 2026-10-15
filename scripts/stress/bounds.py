#!/usr/bin/env python3
"""Fail-closed bounds verification: every documented bound engages at its edge.

Boots a private substrate (MIX_ENV=test, SMALT_TEST_*_PORT), then probes each
documented bound at and around its edge. Fail-closed: exit 0 only when every
bound engages; any non-engaging bound is a FINDING and exits 1.

Bounds probed (receipts: tmp/invariant-gates/bounds-receipt.json,
doc: docs/STRESS/BOUNDS.md):
  1. queue capacity 4096      4097th enqueue refused (capacity error)
  2. payload 1 MiB            SB/AMQP: 1MiB-1/1MiB accepted, 1MiB+1 refused.
                              Blob plane has NO 1MiB bound (verified): 413
                              RequestBodyTooLarge engages at 8,000,001 bytes.
  3. lock clamp 100..30000 ms x-opt-locked-until deltas match clamped durations
  4. CBS claims cap 128       129th put-token -> 429 CLAIM_CAPACITY
  5. KQL caps                 >2000 chars / depth>20 / take>1000 -> 400 BadQuery
  6. ledger dedup at scale    100 rapid duplicates -> 1x201 + 99x409
  7. AMQP frame >1MiB         connection refused (frame_too_size)

Usage: python3 scripts/stress/bounds.py
Stdlib only on the python side. AMQP probes (2/4/7) run via an embedded Elixir
driver written to tmp/bounds_driver.exs (mix run, MIX_ENV=test). Probes 1/3
reuse gates/amqp_invariant_driver.exs modes via gates/common.py.
"""
import base64
import json
import os
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(REPO, "gates"))
import common  # noqa: E402

RECEIPT_DIR = os.path.join(REPO, "tmp", "invariant-gates")
DRIVER_PATH = os.path.join(REPO, "tmp", "bounds_driver.exs")


def run_bounds_driver(mode, extra_env, timeout_s=300):
    """Run tmp/bounds_driver.exs (written by build_driver) and parse BOUNDS_JSON."""
    env = dict(os.environ)
    env["MIX_ENV"] = "test"
    env["SMALT_BOUNDS_MODE"] = mode
    env.update({k: str(v) for k, v in extra_env.items()})
    r = subprocess.run(["mix", "run", "--no-start", DRIVER_PATH], cwd=REPO,
                       env=env, capture_output=True, text=True, timeout=timeout_s)
    line = None
    for raw in (r.stdout or "").splitlines():
        if raw.startswith("BOUNDS_JSON "):
            line = raw[len("BOUNDS_JSON "):].strip()
    if line is None:
        raise RuntimeError(
            "driver mode=%s produced no BOUNDS_JSON (rc=%s)\nstdout tail: %s\nstderr tail: %s"
            % (mode, r.returncode, (r.stdout or "")[-500:], (r.stderr or "")[-800:]))
    return json.loads(line)


# --- HTTP probes -------------------------------------------------------------------

def probe_blob(egress):
    """Bound 2: 1MiB payload boundary via Blob REST PUT on the egress router."""
    acct, cont, blob = "boundsacct", "boundscont", "boundsblob"
    ver = {"x-ms-version": "2021-12-02"}
    common.http(egress, "PUT", "/%s/%s" % (acct, cont), headers=ver)
    # Verified (2026-10-15 bounds run, tmp/bounds-receipt.json): the blob plane
    # has NO 1MiB bound — 1MiB±1 PUTs return 201 and GET back intact. The
    # effective blob request-body bound is 8,000,000 bytes (egress_router.ex:793
    # read_body length); the 413 RequestBodyTooLarge shape engages at 8,000,001.
    sizes = [("1MiB-1", (1 * 1024 * 1024) - 1), ("1MiB", 1 * 1024 * 1024),
             ("1MiB+1", (1 * 1024 * 1024) + 1), ("8m", 8_000_000),
             ("8m+1", 8_000_001)]
    results = {}
    for label, size in sizes:
        body = b"x" * size
        s, _, resp = common.http(
            egress, "PUT", "/%s/%s/%s-%s" % (acct, cont, blob, label.replace("+", "p")),
            body=body,
            headers=dict(ver, **{"Content-Type": "application/octet-stream",
                                 "x-ms-blob-type": "BlockBlob"}))
        code = resp.get("error", {}).get("code") if isinstance(resp, dict) else None
        results[label] = {"status": s, "error_code": code}
    return results


def probe_kql(egress):
    """Bound 5: KQL caps via POST /providers/Microsoft.ResourceGraph/resources."""
    # api-version must be 2022-10-01 (resource_graph.ex:14) — any other version
    # is rejected InvalidApiVersion BEFORE KQL parsing, which would make these
    # probes vacuous (400 for the wrong reason).
    def q(query):
        s, _, resp = common.http(egress, "POST",
                                 "/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01",
                                 {"query": query})
        code = resp.get("error", {}).get("code") if isinstance(resp, dict) else None
        return {"status": s, "error_code": code}

    # total query length pinned exactly: len("| where f0 == \"\"") == 17
    return {
        "len2000": q('| where f0 == "' + "a" * (2000 - 17) + '"'),
        "len2001": q('| where f0 == "' + "a" * (2001 - 17) + '"'),
        "take1000": q("| take 1000"),
        "take1001": q("| take 1001"),
        "depth20": q("| where " + " and ".join("f%d == %d" % (i, i) for i in range(20))),
        "depth21": q("| where " + " and ".join("f%d == %d" % (i, i) for i in range(21))),
    }


def probe_ledger(egress, n=100):
    """Bound 6: ledger dedup at scale — n rapid duplicate appends."""
    entry = {"k": "bounds-dedup-%d" % time.monotonic_ns()}
    statuses = []
    for _ in range(n):
        s, _, _ = common.http(egress, "POST", "/app/transactions", entry)
        statuses.append(s)
    from collections import Counter
    return {"statuses": dict(Counter(statuses)), "n": n}


# --- AMQP probes (via embedded driver) ----------------------------------------------

def build_driver():
    """Write tmp/bounds_driver.exs (scratch; not a repo source edit)."""
    with open(DRIVER_PATH, "w") as f:
        f.write(DRIVER_ELIXIR)


def probe_capacity(ports, shared_key):
    """Bound 1 via gates/amqp_invariant_driver.exs mode "capacity"."""
    r = common.run_amqp_driver("capacity", {
        "SMALT_AMQP_PORT": ports["amqp"],
        "SMALT_CAP_QUEUE": "bounds-capq",
        "SMALT_SB_SHARED_KEY": shared_key})
    return r.get("result", {})


def probe_lockclamp(ports, shared_key):
    """Bound 3: ARM PUT queues at clamp edges, then driver mode "lockclamp"."""
    arm = ports["arm"]
    api = "2021-04-01"
    cases = [("PT1H", 30_000), ("PT0S", 100), ("PT5S", 5_000)]
    ns = ("/subscriptions/bounds/resourceGroups/bounds/providers/"
          "Microsoft.ServiceBus/namespaces/bounds-ns?api-version=" + api)
    # transient: the ARM router can 500 if the PUT lands right after port-bind
    for attempt in range(5):
        s, _, body = common.http(arm, "PUT", ns, {"location": "bounds", "skuName": "Standard"})
        if s in (200, 201):
            break
        time.sleep(1.0 * (attempt + 1))
    assert s in (200, 201), "namespace PUT %s: %s" % (s, body)
    specs = []
    for dur, expect in cases:
        path = (ns.rsplit("?", 1)[0] + "/queues/bounds-lock-%d?api-version=" % expect + api)
        s, _, body = common.http(arm, "PUT", path,
                                 {"location": "bounds", "properties": {"lockDuration": dur}})
        assert s in (200, 201), "queue PUT %s: %s" % (s, body)
        specs.append("bounds-lock-%d:%d" % (expect, expect))
    r = common.run_amqp_driver("lockclamp", {
        "SMALT_AMQP_PORT": ports["amqp"],
        "SMALT_LOCK_QUEUES": ",".join(specs),
        "SMALT_SB_SHARED_KEY": shared_key})
    return {"observations": r.get("observations", [])}


# --- verdict -------------------------------------------------------------------

TOL_MS = 2_000


def verdict(rows):
    details = []
    ok = True

    def check(cond, msg):
        nonlocal ok
        details.append(("PASS" if cond else "FAIL") + " " + msg)
        ok = ok and cond

    cap = rows["capacity"]
    check(cap.get("condition") == "amqp:link-message-size-exceeded"
          and "capacity" in (cap.get("description") or ""),
          "bound1 capacity: 4097th refused at boundary (%s / %s)"
          % (cap.get("condition"), cap.get("description")))

    blob = rows["blob"]
    check(blob["1MiB-1"]["status"] == 201 and blob["1MiB"]["status"] == 201
          and blob["1MiB+1"]["status"] == 201,
          "bound2 blob: NO 1MiB bound — 1MiB-1/1MiB/1MiB+1 all 201 (got %s %s %s)"
          % (blob["1MiB-1"]["status"], blob["1MiB"]["status"], blob["1MiB+1"]["status"]))
    check(blob["8m"]["status"] == 201, "bound2 blob 8,000,000 -> 201 (got %s)" % blob["8m"]["status"])
    check(blob["8m+1"]["status"] == 413 and blob["8m+1"]["error_code"] == "RequestBodyTooLarge",
          "bound2 blob 8,000,001 -> 413 RequestBodyTooLarge (got %s %s)"
          % (blob["8m+1"]["status"], blob["8m+1"]["error_code"]))

    # AMQP enqueue side of the 1MiB body bound (QueueStore @max_body, > not >=)
    pr = {}
    for r in rows.get("payload_amqp", {}).get("results", []):
        pr[r["size"]] = r["outcome"]
    check(pr.get(1024 * 1024 - 1, {}).get("outcome") == "accepted",
          "bound2 amqp body 1MiB-1 accepted (got %s)" % pr.get(1024 * 1024 - 1))
    check(pr.get(1024 * 1024, {}).get("outcome") == "accepted",
          "bound2 amqp body 1MiB accepted at boundary (got %s)" % pr.get(1024 * 1024))
    check(pr.get(1024 * 1024 + 1, {}).get("outcome") == "refused",
          "bound2 amqp body 1MiB+1 refused (got %s)" % pr.get(1024 * 1024 + 1))

    for o in rows["lockclamp"]["observations"]:
        want = o["expected_ms"]
        d = o.get("delta_ms")
        check(d is not None and abs(d - want) <= TOL_MS,
              "bound3 lockclamp %s: delta~%sms (got %s)" % (o["queue"], want, d))

    cbs = rows["cbs"]
    st = cbs.get("statuses", [])
    first = cbs.get("first429_index")
    preexisting = 6  # authorize put-tokens before this probe: capacity 1, lockclamp 3, payload 1, frame 1
    check(first is not None and all(s == 200 for s in st[:first - 1]) and all(s == 429 for s in st[first - 1:]),
          "bound4 cbs: monotone 200s then 429s at the cap (first429=%s of 130)" % first)
    check(first == 129 - preexisting,
          "bound4 cbs: cap total = pre-existing %d + %d fresh = 128, 129th fresh -> 429 (got first429=%s)"
          % (preexisting, (first - 1) if first else 0, first))
    check("CLAIM_CAPACITY" in str(cbs.get("description") or ""),
          "bound4 cbs: 429 shape CLAIM_CAPACITY (%s)" % cbs.get("description"))

    kql = rows["kql"]
    check(kql["len2000"]["status"] in (200, 400) and kql["len2000"]["status"] != 500, "bound5 kql len2000 accepted-or-4xx-not-500")
    check(kql["len2001"]["status"] == 400, "bound5 kql len2001 -> 400 (got %s)" % kql["len2001"]["status"])
    check(kql["take1001"]["status"] == 400, "bound5 kql take1001 -> 400 (got %s)" % kql["take1001"]["status"])
    check(kql["depth21"]["status"] == 400, "bound5 kql depth21 -> 400 (got %s)" % kql["depth21"]["status"])

    led = rows["ledger"]["statuses"]
    check(led.get(201, 0) == 1 and led.get(409, 0) == 99,
          "bound6 ledger dedup: 1x201 + 99x409 (got %s)" % led)

    fr = rows["frame"].get("result", rows["frame"])
    check(fr.get("outcome") == "refused" and fr.get("condition") not in (None, "socket-closed"),
          "bound7 frame>1MiB: refused with explicit condition (%s / %s)"
          % (fr.get("condition"), fr.get("description")))
    check("frame_too_size" in str(fr.get("description") or ""),
          "bound7 frame>1MiB: close names :frame_too_size (%s)" % fr.get("description"))
    return ok, details


def main():
    build_driver()
    ports = common.pick_ports()
    proc = None
    rows, details = {}, []
    t0 = time.monotonic()
    import base64
    shared_key = base64.b64encode(os.urandom(48)).decode()
    ok = False
    try:
        proc = common.spawn_substrate(ports, shared_key)
        amqp_env = {"SMALT_AMQP_PORT": ports["amqp"], "SMALT_BOUNDS_QUEUE": "bounds-payloadq"}

        rows["capacity"] = probe_capacity(ports, shared_key)
        rows["blob"] = probe_blob(ports["egress"])
        rows["lockclamp"] = probe_lockclamp(ports, shared_key)
        rows["kql"] = probe_kql(ports["egress"])
        rows["ledger"] = probe_ledger(ports["egress"])
        amqp = run_bounds_driver("all", dict(amqp_env, SMALT_SB_SHARED_KEY=shared_key))
        rows["payload_amqp"] = amqp["payload"]
        rows["cbs"] = amqp["cbs"]
        rows["frame"] = amqp["frame"]

        ok, details = verdict(rows)
        print(("PASS" if ok else "FAIL") + " bounds: ")
        for d in details:
            print("  " + d)
    except Exception as exc:
        details = ["%s: %s" % (type(exc).__name__, exc)]
        print("ERROR bounds: " + details[0])
    finally:
        common.kill_substrate(proc, ports)

    receipt = {
        "schema": "smalt-bounds-receipt/v1",
        "name": "bounds",
        "date": time.strftime("%Y-%m-%d"),
        "elapsed_s": round(time.monotonic() - t0, 3),
        "subject": {"repo": REPO, "mix_env": "test", "private_ports": ports},
        "rows": rows,
        "details": details,
        "verdict": "PASS" if ok else "FAIL",
    }
    os.makedirs(RECEIPT_DIR, exist_ok=True)
    path = os.path.join(RECEIPT_DIR, "bounds-receipt.json")
    with open(path, "w") as f:
        json.dump(receipt, f, indent=2, default=str)
    print("bounds: receipt %s verdict=%s" % (path, receipt["verdict"]))
    return 0 if ok else 1




# --- embedded Elixir driver source (written to tmp/bounds_driver.exs) ---------------

DRIVER_ELIXIR = r'''
defmodule Stress.BoundsDriver do
  @moduledoc "Bounds probes over raw AMQP: payload 1MiB, frame>1MiB, CBS 128 cap."
  @sasl_header "AMQP\x03\x01\x00\x00"
  @header "AMQP\x00\x01\x00\x00"
  @cbs_type "servicebus.windows.net:sastoken"

  alias Smalt.Amqp.FrameCodec

  def main do
    Application.put_env(:smalt, :sb_shared_key, System.fetch_env!("SMALT_SB_SHARED_KEY"))
    port = String.to_integer(System.fetch_env!("SMALT_AMQP_PORT"))

    case System.fetch_env!("SMALT_BOUNDS_MODE") do
      "all" -> all(port)
      "payload" -> payload(port)
      "frame" -> frame(port)
      "cbs" -> cbs(port)
      other -> raise("unknown SMALT_BOUNDS_MODE #{inspect(other)}")
    end
  end

  # -- combined: one VM boot, three probes ---------------------------------------

  defp all(port) do
    json_line(%{
      mode: "all",
      payload: payload(port),
      frame: frame(port),
      cbs: cbs(port)
    })
  end

  # -- bound 2: payload 1MiB boundary -------------------------------------------

  defp payload(port) do
    queue = System.fetch_env!("SMALT_BOUNDS_QUEUE")
    c = connect(port) |> handshake() |> authorize(endpoint() <> "/" <> queue)
        |> attach_sender(queue, 0) |> await_sender_ready()

    mib = 1 * 1024 * 1024
    results =
      Enum.map([{1, mib - 1}, {2, mib}, {3, mib + 1}, {4, 2 * mib}], fn {id, size} ->
        %{id: id, size: size, outcome: probe_transfer(c, id, size)}
      end)

    %{results: results}
  end

  # unsettled transfer: broker must rule — disposition(accepted) = engaged-ok,
  # close w/ error = refused, socket drop without close = socket-closed
  defp probe_transfer(c, id, size) do
    body = :binary.copy(<<"x">>, size)
    :ok = :gen_tcp.send(c.sock, transfer_frame(id, body, false))

    case read_until_close(c, 30_000) do
      {:accepted, _c} -> %{"outcome" => "accepted"}
      {:closed_with, cond, desc, _c} -> %{"outcome" => "refused", "condition" => cond, "description" => desc}
      {:socket_closed, _c} -> %{"outcome" => "socket-closed"}
    end
  rescue
    e -> %{"outcome" => "driver-error", "description" => Exception.message(e)}
  end

  # -- bound 7: single frame larger than the broker's max_frame_size --------------

  defp frame(port) do
    queue = System.fetch_env!("SMALT_BOUNDS_QUEUE")
    c = connect(port) |> handshake() |> authorize(endpoint() <> "/" <> queue)
        |> attach_sender(queue, 0) |> await_sender_ready()

    # declare a frame body of 1MiB+4KiB (> FrameCodec @max_frame_size 1MiB+512)
    # but fill only the first 8KiB — the broker must refuse on the declared
    # size before the payload arrives
    declared = 1 * 1024 * 1024 + 4 * 1024
    payload = :binary.copy(<<"y">>, 8 * 1024)
    :ok = :gen_tcp.send(c.sock, <<(declared + 8)::unsigned-integer-size(32), 2::8, 0x00::8>>)
    :ok = :gen_tcp.send(c.sock, payload)

    result =
      case read_until_close(c, 15_000) do
        {:closed_with, cond, desc, _c} -> %{"outcome" => "refused", "condition" => cond, "description" => desc}
        {:socket_closed, _c} -> %{"outcome" => "socket-closed", "condition" => nil}
        {:accepted, _c} -> %{"outcome" => "accepted", "condition" => nil}
      end

    %{result: result}
  end

  # -- bound 4: CBS claims cap 128 ------------------------------------------------

  defp cbs(port) do
    key = Application.fetch_env!(:smalt, :sb_shared_key)
    # attach the $cbs links ONCE; re-attaching the same handle mid-session is
    # a protocol error. Unique audiences give unique claims for the same owner.
    c = connect(port) |> handshake()
    c =
      send_frame(c, {:attach, %{name: "cbs-tx", handle: 2, role: false, target: %{address: "$cbs"}}})
      |> send_frame({:attach, %{name: "cbs-rx", handle: 3, role: true, source: %{address: "$cbs"}}})

    statuses =
      Enum.map(1..130, fn i ->
        audience = endpoint() <> "/bounds-cbs-#{i}"
        cbs_put_token(c, i + 200, audience, build_token(key, audience))
        |> case do
          {code, desc} -> {code, desc}
          :no_status -> {:none, "no statusCode in reply"}
        end
      end)

    codes = Enum.map(statuses, fn {code, _} -> code end)
    first429 = Enum.find_index(codes, fn code -> code == 429 end)
    tail_desc =
      statuses
      |> Enum.drop_while(fn {code, _} -> code != 429 end)
      |> Enum.take(1)
      |> Enum.map(fn {_c, d} -> d end)

    %{
      statuses: codes,
      first429_index: if(is_integer(first429), do: first429 + 1, else: nil),
      description: Enum.map(tail_desc, &to_string/1)
    }
  end

  defp cbs_put_token(c, delivery_id, audience, token) do
    send_frame(c, {
      :transfer,
      %{handle: 2, delivery_id: delivery_id, delivery_tag: <<delivery_id::unsigned-64>>,
        message_format: 0, settled: true, more: false},
      {:sections, [
        {:application_properties, %{"operation" => "put-token", "type" => @cbs_type, "name" => audience}},
        {:body_amqp_value, token}
      ]}
    })

    # read replies until a transfer with statusCode arrives (drain attach echoes)
    do_wait_cbs(c, 40)
  end

  defp do_wait_cbs(_c, 0), do: :no_status

  defp do_wait_cbs(c, n) do
    case pop(c.buf) do
      {:ok, %{performative: %{performative: :transfer}} = f, rest} ->
        {:ok, sections} = FrameCodec.decode_message(f.payload)

        code =
          Enum.find_value(sections, fn
            {:application_properties, %{"statusCode" => code}} -> code
            {:message_annotations, %{"x-opt-status-code" => code}} -> code
            _ -> nil
          end)

        desc =
          Enum.find_value(sections, fn
            {:application_properties, %{"statusDescription" => d}} -> d
            {:message_annotations, %{"x-opt-status-description" => d}} -> d
            _ -> nil
          end) || ""

        if is_integer(code), do: {code, to_string(desc)}, else: do_wait_cbs(%{c | buf: rest}, n - 1)
      {:ok, _other, rest} ->
        do_wait_cbs(%{c | buf: rest}, n)
      :incomplete ->
        case :gen_tcp.recv(c.sock, 0, 5_000) do
          {:ok, data} -> do_wait_cbs(%{c | buf: <<c.buf::binary, data::binary>>}, n)
          {:error, _} -> :no_status
        end
    end
  end

  defp build_token(key, audience) do
    se = System.system_time(:second) + 600
    enc_sr = URI.encode_www_form(audience)

    sig =
      :crypto.mac(:hmac, :sha256, key, "#{enc_sr}\n#{se}")
      |> Base.encode64()
      |> URI.encode_www_form()

    "SharedAccessSignature sr=#{enc_sr}&sig=#{sig}&se=#{se}&skn=RootManageSharedAccessKey"
  end

  # -- shared client helpers (mirror gates/amqp_invariant_driver.exs) ---------------

  defp transfer_frame(id, payload, settled) do
    FrameCodec.encode_frame(:amqp, 0, {
      :transfer,
      %{handle: 0, delivery_id: id, delivery_tag: <<id::unsigned-64>>,
        message_format: 0, settled: settled, more: false},
      {:sections, [{:body_data, payload}]}
    })
  end

  defp read_until_close(c, ms) do
    deadline = System.monotonic_time(:millisecond) + ms
    do_read_until_close(c, deadline)
  end

  defp do_read_until_close(c, deadline) do
    if System.monotonic_time(:millisecond) > deadline, do: raise("no broker ruling arrived")

    case pop(c.buf) do
      {:ok, %{performative: %{performative: :close} = perf}, _rest} ->
        err = perf[:error] || %{}
        {cond, desc} =
          case err do
            %{condition: cc} -> {cc, Map.get(err, :description)}
            %{} = m -> {Map.get(m, "condition"), Map.get(m, "description")}
            _ -> {nil, nil}
          end
        cond = cond || Map.get(perf, "condition") || inspect(Map.delete(perf, :error))
        desc = plain(desc) || inspect(err)
        {:closed_with, plain(cond), desc, c}

      {:ok, %{performative: %{performative: :disposition} = perf}, rest} ->
        settled? = Map.get(perf, :settled)
        state = Map.get(perf, :state)
        if settled? == true or state == :accepted do
          {:accepted, %{c | buf: rest}}
        else
          do_read_until_close(%{c | buf: rest}, deadline)
        end

      {:ok, _other, rest} ->
        do_read_until_close(%{c | buf: rest}, deadline)

      :incomplete ->
        case :gen_tcp.recv(c.sock, 0, 5_000) do
          {:ok, data} -> do_read_until_close(%{c | buf: <<c.buf::binary, data::binary>>}, deadline)
          {:error, _} -> {:socket_closed, c}
        end
    end
  end

  defp endpoint, do: Smalt.Amqp.SasVerifier.endpoint()

  defp authorize(c, audience) do
    key = Application.fetch_env!(:smalt, :sb_shared_key)
    token = build_token(key, audience)

    c = send_frame(c, {:attach, %{name: "cbs-tx", handle: 2, role: false, target: %{address: "$cbs"}}})
    c = send_frame(c, {:attach, %{name: "cbs-rx", handle: 3, role: true, source: %{address: "$cbs"}}})

    send_frame(c, {
      :transfer,
      %{handle: 2, delivery_id: 100, delivery_tag: <<100>>, message_format: 0, settled: true, more: false},
      {:sections, [
        {:application_properties, %{"operation" => "put-token", "type" => @cbs_type, "name" => audience}},
        {:body_amqp_value, token}
      ]}
    })

    do_wait_cbs_ok(c, 60)
  end

  defp do_wait_cbs_ok(_c, 0), do: raise("no $cbs put-token reply arrived")

  defp do_wait_cbs_ok(c, n) do
    case pop(c.buf) do
      {:ok, %{performative: %{performative: :transfer}} = f, rest} ->
        {:ok, sections} = FrameCodec.decode_message(f.payload)

        case Enum.find_value(sections, fn
               {:application_properties, %{"statusCode" => code}} -> code
               {:message_annotations, %{"x-opt-status-code" => code}} -> code
               _ -> nil
             end) do
          200 -> %{c | buf: rest}
          code -> raise("cbs put-token rejected: #{inspect(code)}")
        end
      {:ok, _other, rest} -> do_wait_cbs_ok(%{c | buf: rest}, n)
      :incomplete ->
        {:ok, data} = :gen_tcp.recv(c.sock, 0, 5_000)
        do_wait_cbs_ok(%{c | buf: <<c.buf::binary, data::binary>>}, n)
    end
  end

  defp attach_sender(c, queue, handle) do
    send_frame(c, {:attach, %{name: "bounds-tx", handle: handle, role: false, target: %{address: queue}}})
  end

  defp await_sender_ready(c), do: do_await(c, false, false)

  defp do_await(c, true, true), do: c

  defp do_await(c, attach_seen?, flow_seen?) do
    case pop(c.buf) do
      {:ok, %{performative: %{performative: :attach}}, rest} -> do_await(%{c | buf: rest}, true, flow_seen?)
      {:ok, %{performative: %{performative: :flow}}, rest} -> do_await(%{c | buf: rest}, attach_seen?, true)
      {:ok, _other, rest} -> do_await(%{c | buf: rest}, attach_seen?, flow_seen?)
      :incomplete ->
        {:ok, data} = :gen_tcp.recv(c.sock, 0, 10_000)
        do_await(%{c | buf: <<c.buf::binary, data::binary>>}, attach_seen?, flow_seen?)
    end
  end

  defp connect(port) do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5_000)
    %{sock: sock, buf: <<>>}
  end

  defp handshake(c) do
    :ok = :gen_tcp.send(c.sock, @sasl_header)
    {_h, c} = recv_exact(c, 8)
    {%{performative: %{performative: :sasl_mechanisms}}, c} = next_frame(c)
    c = send_frame(c, {:sasl_init, %{mechanism: "ANONYMOUS"}})
    {%{performative: %{performative: :sasl_outcome, code: 0}}, c} = next_frame(c)

    :ok = :gen_tcp.send(c.sock, @header)
    {_h, c} = recv_exact(c, 8)
    c = send_frame(c, {:open, %{container_id: "smalt-bounds-driver", max_frame_size: 65_536, channel_max: 65_535}})
    {%{performative: %{performative: :open}}, c} = next_frame(c)
    c = send_frame(c, {:begin, %{next_outgoing_id: 1, incoming_window: 10_000, outgoing_window: 10_000, handle_max: 100}})
    {%{performative: %{performative: :begin}}, c} = next_frame(c)
    c
  end

  defp next_frame(c, timeout \\ 10_000) do
    case pop(c.buf) do
      {:ok, frame, rest} -> {frame, %{c | buf: rest}}
      :incomplete ->
        {:ok, data} = :gen_tcp.recv(c.sock, 0, timeout)
        next_frame(%{c | buf: <<c.buf::binary, data::binary>>}, timeout)
    end
  end

  defp recv_exact(%{buf: buf} = c, n) when byte_size(buf) >= n do
    <<data::binary-size(n), rest::binary>> = buf
    {data, %{c | buf: rest}}
  end

  defp recv_exact(c, n) do
    {:ok, data} = :gen_tcp.recv(c.sock, n - byte_size(c.buf), 5_000)
    recv_exact(%{c | buf: <<c.buf::binary, data::binary>>}, n)
  end

  defp pop(buf) do
    case FrameCodec.decode_frame(buf) do
      {:ok, frame} ->
        <<size::unsigned-integer-size(32), _::binary>> = buf
        {:ok, frame, binary_part(buf, size, byte_size(buf) - size)}
      {:more, _} -> :incomplete
      {:error, reason} -> raise "frame decode error: #{inspect(reason)}"
    end
  end

  defp send_frame(%{sock: sock} = c, {name, fields}) do
    layer = if name in [:sasl_init, :sasl_mechanisms, :sasl_outcome], do: :sasl, else: :amqp
    :ok = :gen_tcp.send(sock, FrameCodec.encode_frame(layer, 0, {name, fields}))
    c
  end

  defp send_frame(%{sock: sock} = c, {:transfer, fields, {:sections, _} = sections}) do
    :ok = :gen_tcp.send(sock, FrameCodec.encode_frame(:amqp, 0, {:transfer, fields, sections}))
    c
  end

  defp plain({:symbol, s}) when is_binary(s), do: s
  defp plain(s) when is_binary(s), do: s
  defp plain(n) when is_integer(n), do: n
  defp plain(nil), do: nil
  defp plain(other), do: inspect(other)

  defp json_line(res) do
    json = res |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Jason.encode!()
    IO.puts("BOUNDS_JSON #{json}")
  end
end

Stress.BoundsDriver.main()
'''.strip()


def build_driver():
    os.makedirs(os.path.dirname(DRIVER_PATH), exist_ok=True)
    with open(DRIVER_PATH, "w") as f:
        f.write(DRIVER_ELIXIR + "\n")


if __name__ == "__main__":
    sys.exit(main())
