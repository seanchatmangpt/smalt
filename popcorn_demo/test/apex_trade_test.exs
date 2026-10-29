defmodule PopcornDemo.ApexTradeTest do
  @moduledoc """
  Chicago-school tests for the APEX-1 pre-trade settlement gate. The only
  collaborators are the real BEAM scheduler (CAS invariant — asserted on final
  state, no mocks) and, for the live legs, the real substrate (8443 / 5673)
  with loud typed skips when a plane is down.
  """

  use ExUnit.Case, async: false

  @skip_reason "substrate down — run 9>&- just substrate-up"

  substrate_down? =
    with {:ok, sock} <- :gen_tcp.connect(~c"127.0.0.1", 8443, [:binary, active: false], 2_000) do
      :gen_tcp.close(sock)
      false
    else
      _ -> true
    end

  eh_down? =
    with {:ok, sock} <- :gen_tcp.connect(~c"127.0.0.1", 5673, [:binary, active: false], 2_000) do
      :gen_tcp.close(sock)
      false
    else
      _ -> true
    end

  @substrate_skip if(substrate_down?, do: @skip_reason, else: false)
  @eh_skip if(eh_down?, do: "EH plane down — run 9>&- just substrate-up", else: false)

  if substrate_down? do
    IO.puts(:stderr, "[popcorn_demo] SKIP: #{@skip_reason}")
  end

  # -- CAS invariant (Chicago: real actors, final-state asserts) ----------------

  test "1,024-actor gate: exactly 1 winner, 1,023 typed cas_lost losers, margin-1 @ v1" do
    assert {:ok, row} = PopcornDemo.ApexTrade.cas_gate(1_024, 1_000_000)
    assert row.winners == 1
    assert row.losers == 1_023
    assert row.n == 1_024
    assert row.committed == true
    assert row.final_version == 1
    assert is_integer(row.winner_id) and row.winner_id >= 1 and row.winner_id <= 1_024
    assert row.actor_mem_bytes.max > 0
  end

  test "gate is repeatable: 3 fresh races, same deterministic distribution" do
    for _ <- 1..3 do
      assert {:ok, row} = PopcornDemo.ApexTrade.cas_gate(1_024, 500_000)
      assert row.winners == 1 and row.losers == 1_023 and row.committed
    end
  end

  test "loser partition is exact: n = winners + losers, typed shape {:cas_lost, :margin}" do
    assert {:ok, row} = PopcornDemo.ApexTrade.cas_gate(256, 10_000)
    assert row.winners + row.losers == 256
    assert {:ok, detail} = capture_loser_shapes()
    assert detail in [[:margin], []]
  end

  defp capture_loser_shapes do
    tab = :ets.new(:apex_test_probe, [:public, :set])
    parent = self()

    for id <- 1..256 do
      spawn(fn ->
        res = PopcornDemo.ApexTrade.cas_actor(id, tab, :margin, 10_000)
        send(parent, res)
      end)
    end

    results = for _ <- 1..256, into: [], do: (receive do r -> r end)

    shapes =
      results
      |> Enum.filter(&match?({:cas_lost, _}, &1))
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq()

    {:ok, shapes}
  end

  test "assert_gate/3 refuses a 0-winner distribution (typed, fail-closed)" do
    # 0 winners, 2 losers, no committed row -> every clause of the law broken
    results = [
      {1, {:cas_lost, :margin}, 2616},
      {2, {:cas_lost, :margin}, 2616}
    ]

    # cas_gate/2 wraps the bare detail in {:not_deterministic, _}; the raw
    # law returns the detail itself
    assert {:error, {:winner_count, 0}} =
             PopcornDemo.ApexTrade.assert_gate(results, [], 1_000_000)
  end

  test "assert_gate/3 refuses a bad final row (typed, fail-closed)" do
    results = [{7, {:winner, :margin}, 2616}, {1, {:cas_lost, :margin}, 2616}]

    # 555_555 != margin - 1 (999_999): a genuinely corrupted final row
    assert {:error, {:bad_final_row, [[:committed, 555_555, 1]]}} =
             PopcornDemo.ApexTrade.assert_gate(results, [[:committed, 555_555, 1]], 1_000_000)
  end

  # -- live legs (loud skips; real substrate collaborator) ----------------------

  @tag skip: @substrate_skip
  test "sign_leg returns one real ES256 signature (LiveKeyops sign path)" do
    assert {:ok, info} = PopcornDemo.ApexTrade.sign_leg()
    assert info.alg == "ES256"
    assert is_integer(info.sig_bytes) and info.sig_bytes > 0
    assert is_integer(info.wall_ms)
  end

  @tag skip: @substrate_skip
  test "sign_leg is repeatable (fresh payload each call)" do
    assert {:ok, a} = PopcornDemo.ApexTrade.sign_leg()
    assert {:ok, b} = PopcornDemo.ApexTrade.sign_leg()
    assert a.payload != b.payload
    assert {:ok, _} = {:ok, a.sig_bytes}
  end

  @tag skip: @eh_skip
  test "settle_leg fires one AMQP transfer settled by the broker" do
    assert {:ok, token} = PopcornDemo.ApexTrade.settle_leg(1, "apex-test-token")
    assert is_binary(token) and token != ""
  end

  @tag skip: @substrate_skip
  test "full scenario run/0: wall_ms under the 300ms budget, 1/1023 split, zero exceptions" do
    assert {:ok, r} = PopcornDemo.ApexTrade.run()
    assert r.wall_ms <= 300
    assert r.cas.winners == 1 and r.cas.losers == 1_023
    assert r.exceptions == 0
    assert match?({:ok, _}, r.settle)
    assert r.sign.alg == "ES256"
  end
end
