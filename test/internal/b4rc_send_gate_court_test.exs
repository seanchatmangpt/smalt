# KD-COVERS: KD-86 — BK-B4R send-gate regression court (lane BK-B4RC,
# hardened by lane BK-B4VW per docs/jira/v26.10.22/receipts/bkb4rv-composed-verify.md §2).
#
# BK-B4R (docs/jira/v26.10.22/receipts/bkb4r-sender-link.md) found that the
# KD-86 entity gate — queue_store.ex ensure_entity/1 — consulted only
# :smalt_sb_queues (emulator-lazy rows): an entity created through the
# MANAGEMENT plane (ARM gateway / ATOM alias PUT) lives in :smalt_resources
# with no :smalt_sb_queues row, so every send to it was refused
# {:error, :messaging_entity_not_found} → sender-link DETACH
# MessagingEntityNotFound (the b4 bench face "0/2000 sends, CBS-at-200").
# Fix: ensure_entity admits the ARM resource record (arm_entity?/1's
# downcased-suffix scan over :smalt_resources) and materializes the
# :smalt_sb_queues row.
#
# Chicago discipline: real collaborators, no mocks, no sleeps.
#   - The ARM PUT face is the REAL flat ATOM dispatcher
#     (Smalt.Amqp.AtomBridge.handle_request/3) — the exact code the wire
#     request lands on (ArmGateway.Router sb_atom_alias → AtomBridge).
#   - The send face is the REAL QueueStore.enqueue/3 gate — the exact call
#     the AMQP sender link ingests (connection.ex ingest → QueueStore.enqueue).
#   - Delivery is proven by a real dequeue_matching claim.
#
# Falsifier (both shapes flip, witnessed BK-B4VW):
#   M1 — replace ensure_entity's ARM clause IN PLACE (`arm_entity?(name) ->`
#        becomes `false -> ensure_queue(name)`): the cond falls through to the
#        `true -> {:error, :messaging_entity_not_found}` arm and Leg A's send
#        is refused (pre-fix behavior). Witnessed flip: leg A fails on
#        `{:ok, _seq} = enqueue(...)` with {:error, :messaging_entity_not_found}.
#   M2 — insert an UNCONDITIONAL auto-create clause
#        (`true -> ensure_queue(name)`) anywhere ahead of the ARM clause:
#        every send auto-creates, KD-86's no-silent-creation semantics die.
#        Leg B is the flip: the never-created refused send returns
#        {:ok, 1} instead of {:error, :messaging_entity_not_found}.
#        Witnessed flip: leg B fails on enqueue result {:ok, 1}.
#   NOTE for falsifier runners: the literal first-clause insertion
#   `false -> ensure_queue(name)` is a DEAD clause — a `false` head never
#   selects in cond, so the mutation is behaviorally inert and NO behavioral
#   assertion can flip on it by construction (BK-B4VW witnessed the court
#   3/3 green with that shim compiled in, hash 121c37f6…dca8). The live form
#   of the same insertion is M2 above and flips Leg B. A green court under
#   that literal shim is not court vacuity; run M2's live form.
#
# KD-86 original intent stays pinned: flag off + never-created → typed
# refusal, no silent creation in EITHER store; flag on → emulator
# convenience restored.
defmodule InternalTier.B4rcSendGateCourtTest do
  use ExUnit.Case, async: false

  alias Smalt.Amqp.AtomBridge
  alias Smalt.Amqp.QueueStore
  alias Smalt.Store

  @atom_body """
  <?xml version="1.0" encoding="utf-8"?>
  <entry xmlns="http://www.w3.org/2005/Atom"><updated>2026-10-22T00:00:00.000Z</updated><content type="application/xml">
    <QueueDescription xmlns="http://schemas.microsoft.com/netservices/2010/01/servicebus"></QueueDescription></content></entry>
  """

  # Real store inventory of the two tables the gate touches. Chicago: assert
  # on final store state, never on call counts.
  defp sb_keys, do: MapSet.new(Store.keys(:smalt_sb_queues))
  defp arm_keys, do: MapSet.new(Store.keys(:smalt_resources))

  test "BK-B4RC leg A: send to an ARM/ATOM-created queue is admitted, resolves via the ARM record, and delivers" do
    Application.put_env(:smalt, :sb_auto_ensure, false)

    name = "b4rc-arm-#{System.system_time(:millisecond)}"

    # Real management-plane creation: the exact dispatcher the b4 harness's
    # HTTP PUT lands on (ArmGateway.Router sb_atom_alias → AtomBridge).
    assert {status, ct, body} =
             AtomBridge.handle_request("PUT", "/#{name}?api-version=2024-05", @atom_body)

    assert status in [200, 201]
    assert IO.iodata_to_binary(ct) =~ "atom"
    assert body =~ "QueueDescription"
    assert body =~ name

    # The BK-B4R hole: the record exists in :smalt_resources, the AMQP
    # entity row does NOT yet (management plane never materialized it).
    assert :error = QueueStore.queue_info(name)

    # Store witness: the ONLY :smalt_sb_queues row the send may create is the
    # gate's own materialization for this exact name, and the management
    # record must survive untouched. Any auto-create bypass that sweeps other
    # rows in, or consumes the ARM record, diverges here.
    sb_before = sb_keys()
    arm_before = arm_keys()

    # Real send through the KD-86 gate (connection.ex ingest face).
    assert {:ok, _seq} = QueueStore.enqueue(name, "b4rc-arm-payload")

    # Exactly one lazy row materialized — for this name, by the gate.
    sb_after = sb_keys()
    assert MapSet.size(sb_after) - MapSet.size(sb_before) == 1
    assert name in sb_after
    assert MapSet.equal?(MapSet.difference(sb_after, sb_before), MapSet.new([name]))

    # Delivered: a real receiver claim succeeds and the body survives.
    assert {:ok, msg, _lock} = QueueStore.dequeue_matching(name)
    assert msg.body == "b4rc-arm-payload"

    # The ARM record was consulted, not consumed: it survives the send and
    # the dequeue byte-for-byte, so a SECOND send still resolves via the
    # management record (no one-shot materialization hack).
    assert MapSet.equal?(arm_keys(), arm_before)
    assert {:ok, _seq2} = QueueStore.enqueue(name, "b4rc-arm-payload-2")
    assert {:ok, msg2, _lock2} = QueueStore.dequeue_matching(name)
    assert msg2.body == "b4rc-arm-payload-2"
  end

  test "BK-B4RC leg B: KD-86 pin holds — flag off refuses never-created queue, silent creation in neither store" do
    Application.put_env(:smalt, :sb_auto_ensure, false)

    name = "b4rc-never-#{System.system_time(:millisecond)}"

    # M2 flip point: any unconditional auto-create clause reachable ahead of
    # the ARM scan makes this send return {:ok, seq} — the KD-86 refusal
    # semantics die exactly here.
    assert {:error, :messaging_entity_not_found} = QueueStore.enqueue(name, "x")

    # Refused send must create NOTHING: no lazy entity row and no management
    # record — the refusal is not allowed to leak a row as a side effect.
    assert :error = QueueStore.queue_info(name)
    assert name not in sb_keys()
    assert name not in arm_keys()
  end

  test "BK-B4RC leg C: KD-86 pin holds — flag on restores auto-create-on-send" do
    Application.put_env(:smalt, :sb_auto_ensure, true)

    name = "b4rc-auto-#{System.system_time(:millisecond)}"
    assert {:ok, _} = QueueStore.enqueue(name, "x")
    assert {:ok, _info} = QueueStore.queue_info(name)
  after
    Application.put_env(:smalt, :sb_auto_ensure, false)
  end
end
