defmodule Smalt.Posh.PoshEngineTest do
  use ExUnit.Case, async: false

  alias Smalt.Posh.{Supervisor, Turnstile}
  alias Smalt.Posh.Egress.{EventLog, Settlement}
  alias Smalt.Posh.Ingress.{Admission, RingBuffer}

  @policy %{
    "arm/read" => %{required: [:path], types: %{path: :string}},
    "arm/write" => %{required: [:path, :body], types: %{path: :string, body: :map}}
  }

  setup do
    dir = Path.join(System.tmp_dir!(), "posh-test-#{:erlang.unique_integer([:positive])}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    log = :"event_log_#{:erlang.unique_integer([:positive])}"
    ring = :"ring_#{:erlang.unique_integer([:positive])}"

    {:ok, sup} =
      Supervisor.start_link(
        dir: dir,
        capacity: 4,
        name: :"posh_sup_#{:erlang.unique_integer([:positive])}",
        log_name: log,
        ring_name: ring
      )

    {:ok, sup: sup, dir: dir, log: log, ring: ring}
  end

  test "unknown route is refused fail-closed with :no_admission_policy" do
    policy = Admission.compile(@policy)

    assert {:refused, :no_admission_policy} =
             Turnstile.admit(policy, "no/such/route", %{"path" => "x"}, "st0")
  end

  test "shape violation is refused with details" do
    policy = Admission.compile(@policy)

    assert {:refused, {:shape_violation, %{violations: vs}}} =
             Turnstile.admit(policy, "arm/read", %{"wrong" => 1}, "st0")

    assert Enum.any?(vs, &(&1.issue == "missing_required_key"))
  end

  test "valid admission settles into a 32-byte receipt and lands in the event log", %{
    dir: dir,
    log: log
  } do
    policy = Admission.compile(@policy)

    {:ok, result} =
      Turnstile.admit(policy, "arm/read", %{"path" => "/subscriptions/s"}, "st-root",
        node_id: "n1",
        log_name: log
      )

    assert %{} = result.delta
    assert byte_size(result.receipt) == 32
    assert is_integer(result.timestamp_ns)

    assert [%{"receipt" => hex, "kind" => "settlement"}] = EventLog.read_all(dir)
    assert hex == Base.encode16(result.receipt, case: :lower)
  end

  test "receipt digest is BLAKE3(op || u64BE(ts) || payload_body): fixed cross-language vector", %{
    log: log
  } do
    delta = %{"route" => "arm/read", "payload" => %{"path" => "/x"}}
    ts = 1_730_000_000_000_000_000
    op = "arm.request"
    payload_body = ~s({"k":"v"})

    # Determinism: same inputs (incl. same timestamp) => same receipt.
    {:ok, a} =
      Settlement.settle(delta, "node-a", "root-1",
        timestamp_ns: ts,
        op: op,
        payload_body: payload_body,
        log_name: log
      )

    {:ok, b} =
      Settlement.settle(delta, "node-a", "root-1",
        timestamp_ns: ts,
        op: op,
        payload_body: payload_body,
        log_name: log
      )

    assert a.receipt == b.receipt

    # Sensitivity: any contract field changing flips the digest.
    {:ok, c} =
      Settlement.settle(delta, "node-a", "root-1",
        timestamp_ns: ts + 1,
        op: op,
        payload_body: payload_body,
        log_name: log
      )

    {:ok, d} =
      Settlement.settle(delta, "node-a", "root-1",
        timestamp_ns: ts,
        op: op,
        payload_body: payload_body <> " ",
        log_name: log
      )

    {:ok, e} =
      Settlement.settle(delta, "node-a", "root-1",
        timestamp_ns: ts,
        op: "other.op",
        payload_body: payload_body,
        log_name: log
      )

    assert a.receipt != c.receipt
    assert a.receipt != d.receipt
    assert a.receipt != e.receipt

    # Fixed vector: pins the exact cross-language byte string
    # BLAKE3("arm.request" <> <<1730000000000000000::unsigned-big-integer-size(64)>> <> ~s({"k":"v"}))
    # — byte-identical with the Go lane's pinned digest (no length prefixes,
    # no separators).
    expected =
      Settlement.digest(
        "arm.request",
        1_730_000_000_000_000_000,
        ~s({"k":"v"})
      )

    assert byte_size(expected) == 32
    assert Base.encode16(a.receipt, case: :lower) == Base.encode16(expected, case: :lower)
    assert Base.encode16(expected, case: :lower) ==
             "0c39d201b2fc87a2171046f1e76f8afc5398263d888381ee9f24cae4cabdb834"
  end

  test "event log chain verification: prev-hash links hold, and a mutated entry breaks it", %{
    dir: dir,
    log: log
  } do
    {:ok, _} = Settlement.settle(%{"route" => "r"}, "n", "r0", timestamp_ns: 1, log_name: log)
    {:ok, _} = Settlement.settle(%{"route" => "r"}, "n", "r1", timestamp_ns: 2, log_name: log)
    {:ok, _} = Settlement.settle(%{"route" => "r"}, "n", "r2", timestamp_ns: 3, log_name: log)

    assert {:ok, 3} = EventLog.verify_chain(dir)

    entries = EventLog.read_all(dir)
    mutated = put_in(entries, [Access.at(1), "hash"], String.duplicate("f", 64))
    rewrite(dir, mutated)

    assert {:error, :chain_break} = EventLog.verify_chain(dir)
  end

  test "ring buffer overflow drops oldest and counts drops", %{ring: ring} do
    Enum.each(1..6, &RingBuffer.push(ring, &1))

    assert 2 = RingBuffer.drops(ring)
    assert {:ok, 3} = RingBuffer.pop(ring)
    assert {:ok, 4} = RingBuffer.pop(ring)
    assert {:ok, 5} = RingBuffer.pop(ring)
    assert {:ok, 6} = RingBuffer.pop(ring)
    assert :empty = RingBuffer.pop(ring)
  end

  test "ring buffer emits drop telemetry", %{ring: ring} do
    test_pid = self()
    ref = make_ref()

    :telemetry.attach(
      ref,
      [:smalt, :posh, :ingress, :drop],
      fn _e, _m, _m2, ^ref -> send(test_pid, :dropped) end,
      ref
    )

    Enum.each(1..6, &RingBuffer.push(ring, &1))

    assert 2 = RingBuffer.drops(ring)
    assert_received :dropped
    :telemetry.detach(ref)
  end

  defp rewrite(dir, entries) do
    File.write!(
      Path.join(dir, "events.ndjson"),
      Enum.map_join(entries, "\n", &Jason.encode!/1) <> "\n"
    )
  end
end
