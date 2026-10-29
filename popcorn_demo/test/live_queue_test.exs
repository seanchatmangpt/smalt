defmodule PopcornDemo.LiveQueueTest do
  @moduledoc """
  Chicago-school test for the ERRC-R4 queue walk: the only collaborator is
  the REAL substrate (data plane 8443 + STS 9443) over real `:gen_tcp`
  sockets. No mocks. Skips loudly only when the substrate is actually down.
  """

  use ExUnit.Case, async: false

  @skip_reason "substrate down — run 9>&- just substrate-up"

  # :httpc is broken under the popcorn_demo mix env (witnessed 2026-10-20,
  # see LiveBlob moduledoc) — the down-probe rides :gen_tcp like the walk.
  substrate_down? =
    with {:ok, sock} <-
           :gen_tcp.connect(~c"127.0.0.1", 9443, [:binary, active: false], 2_000) do
      :gen_tcp.close(sock)
      false
    else
      _ -> true
    end

  @substrate_skip if(substrate_down?, do: @skip_reason, else: false)

  if substrate_down? do
    IO.puts(:stderr, "[popcorn_demo] SKIP: " <> @skip_reason)
  end

  @tag skip: @substrate_skip
  test "queue walk round-trips one real message byte-for-byte and deletes it by popreceipt" do
    assert {:ok, "queue=OK(" <> rest} = PopcornDemo.LiveQueue.run()

    # run/0 rides a RUN-UNIQUE queue (popcorn-q-<ms>-<rand>) — parallel full
    # suite runs must never share a queue (W13-P isolation law).
    assert [queue, count] = String.split(rest, ":", parts: 2)
    assert String.starts_with?(queue, "popcorn-q-"), "not a run-unique queue: \#{queue}"
    assert {n, "-bytes-roundtrip)"} = Integer.parse(count)
    assert n > 0
  end

  @tag skip: @substrate_skip
  test "walk is repeatable (second run also OK — queue reuse path)" do
    assert {:ok, "queue=OK(" <> _} = PopcornDemo.LiveQueue.run()
    assert {:ok, "queue=OK(" <> _} = PopcornDemo.LiveQueue.run()
  end
  @tag skip: @substrate_skip
  test "outcomes are typed: run/0 never returns an untagged value" do
    outcome = PopcornDemo.LiveQueue.run()

    assert match?({:ok, _}, outcome) or match?({:skip, _}, outcome) or
             match?({:error, _}, outcome)
  end
  @tag skip: @substrate_skip
  test "peek/1 returns N messages in FIFO order and they stay visible (vt=0)" do
    assert {:ok, "peek=OK(popcorn-q-" <> rest} = PopcornDemo.LiveQueue.peek(3)
    assert String.contains?(rest, "3-messages-still-visible)")
  end

  @tag skip: @substrate_skip
  test "peek/0 defaults to 2 and is repeatable" do
    assert {:ok, "peek=OK(" <> _} = PopcornDemo.LiveQueue.peek()
    assert {:ok, "peek=OK(" <> _} = PopcornDemo.LiveQueue.peek()
  end

  @tag skip: @substrate_skip
  test "update_message/0 rotates the popreceipt and replaces the body" do
    assert {:ok, "update=OK(popcorn-q-" <> rest} = PopcornDemo.LiveQueue.update_message()
    assert String.contains?(rest, "receipt-rotated+body-replaced)")
  end

  @tag skip: @substrate_skip
  test "receive_delete/0 FIFO-asserts two messages and deletes the second by its own popreceipt" do
    assert {:ok, "recv-del=OK(popcorn-q-" <> rest} = PopcornDemo.LiveQueue.receive_delete()
    assert String.contains?(rest, "2-fifo-deleted)")
  end
end
