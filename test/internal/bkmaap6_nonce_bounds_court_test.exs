# BK-MAAP6 nonce-registry bounds court (v26.10.22).
#
# Contract: bound the MAA nonce replay registry (P6 = unbounded ETS growth,
# no TTL/sweep, attacker-sized keys) and owner-ref the reservation (P5 =
# cross-process release window), per
# docs/jira/v26.10.22/receipts/bkmaaskep-maa-audit.md.
#
# Court legs (Chicago: real attest/3 calls, real ETS, real spawned processes,
# zero mocks, zero sleeps):
#   1. P6 TTL: 200+ real attests with distinct nonces -> every row counted;
#      a sweep past the nonce TTL releases exactly the expired rows (real
#      count assertion, no fixed sleeps — the sweep is called with a real
#      future timestamp).
#   2. P6 key-size cap: a > nonce_max_key_bytes nonce refuses typed
#      (invalidparameter) BEFORE any ETS write (table size unchanged).
#   3. P6 entry cap: filling the table to nonce_max_entries and attesting
#      once more keeps the table bounded (oldest consumed row evicted; size
#      never exceeds the cap).
#   4. P5 owner-ref: a nonceReplay-refused process cannot delete another
#      live process's :pending reservation (real spawned owner process).
#   5. P5 concurrency: 50 concurrent attests on one nonce -> single burn
#      (exactly one :consumed row, 49 typed nonceReplay), no cross-delete.

defmodule InternalTier.BkMaap6NonceBoundsCourtTest do
  use ExUnit.Case, async: false

  alias Smalt.Attestation.Maa

  @measurement :crypto.strong_rand_bytes(32)
  @measurement_hex Base.encode16(@measurement, case: :lower)
  @nonce_table :smalt_maa_nonces

  setup do
    Maa.reset_nonces!()

    # Guarantee the registry exists for legs that stage rows directly: one
    # real attest creates the table (same path production uses).
    assert {:ok, _t, _c} =
             Maa.attest("SevSnpVM", runtime_data(%{"x-ms-measurement" => @measurement_hex, "nonce" => "setup-seed"}))

    Maa.reset_nonces!()
    :ok
  end

  defp quote_bytes(measurement, runtime_json) do
    <<"SMQ1", measurement::binary-size(32), byte_size(runtime_json)::unsigned-integer-size(32),
      runtime_json::binary>>
  end

  defp runtime_data(claims) do
    json = Jason.encode!(claims)

    %{
      "report" => Base.url_encode64(quote_bytes(@measurement, json), padding: false),
      "runtimeData" => %{"data" => Base.encode64(json), "dataType" => "JSON"}
    }
  end

  defp table_size do
    if :ets.whereis(@nonce_table) == :undefined, do: 0, else: :ets.info(@nonce_table, :size)
  end

  @tag :smalt_internal
  test "P6 TTL: 200 distinct-nonce attests -> 200 rows; sweep past TTL releases them (real counts)" do
    now = System.system_time(:second)

    for i <- 1..220 do
      assert {:ok, _token, _claims} =
               Maa.attest(
                 "SevSnpVM",
                 runtime_data(%{"x-ms-measurement" => @measurement_hex, "nonce" => "p6-ttl-#{i}"}),
                 ts: now
               )
    end

    assert table_size() == 220, "expected exactly 220 consumed rows, got #{table_size()}"

    # Replay of one consumed nonce is still refused inside the TTL window.
    assert {:error, 400, %{"error" => %{"code" => "nonceReplay"}}, _} =
             Maa.attest("SevSnpVM",
               runtime_data(%{"x-ms-measurement" => @measurement_hex, "nonce" => "p6-ttl-1"}),
               ts: now
             )

    # Real future timestamp past the nonce TTL (== token TTL): the sweep
    # releases ALL expired rows. Rows are stamped at second granularity, so a
    # second-boundary rollover during the loop can leave a few rows one second
    # younger than the rest — a second sweep further in the future clears them
    # (both sweeps are real select_delete passes over the real table).
    deleted_1 = Maa.sweep_expired_nonces(now + Maa.nonce_ttl_seconds() + 1)

    deleted_2 = Maa.sweep_expired_nonces(now + Maa.nonce_ttl_seconds() + 5)

    assert deleted_1 + deleted_2 >= 220,
           "sweeps freed only #{deleted_1}+#{deleted_2} of 220 expired rows"

    assert table_size() == 0,
           "expired rows survived both sweeps: #{table_size()} remain (deleted #{deleted_1}+#{deleted_2})"
  end

  @tag :smalt_internal
  test "P6 key-size cap: oversized nonce refuses typed before any ETS write" do
    oversized = String.duplicate("a", Maa.nonce_max_key_bytes() + 1)

    assert {:error, 400, %{"error" => %{"code" => "invalidparameter"}}, andon} =
             Maa.attest("SevSnpVM", runtime_data(%{"x-ms-measurement" => @measurement_hex, "nonce" => oversized}))

    assert :ok = Smalt.Powl2.Andon.verify_ntriples(Smalt.Powl2.Andon.ntriples(andon))
    assert table_size() == 0, "oversized nonce wrote a row anyway"

    # Boundary: a nonce exactly at the cap is accepted and consumed normally.
    at_cap = String.duplicate("b", Maa.nonce_max_key_bytes())

    assert {:ok, _token, _claims} =
             Maa.attest("SevSnpVM", runtime_data(%{"x-ms-measurement" => @measurement_hex, "nonce" => at_cap}))

    assert table_size() == 1
  end

  @tag :smalt_internal
  test "P6 entry cap: attest under a full table stays bounded (oldest consumed evicted)" do
    cap = Maa.nonce_max_entries()
    now = System.system_time(:second)

    # Fill the table to the cap with consumed rows in the module's real shape,
    # strictly ordered by age ("1" is the oldest).
    rows =
      for i <- 1..cap do
        {Integer.to_string(i), self(), :consumed, now - 4000 + i}
      end

    :ets.insert(@nonce_table, rows)
    assert table_size() == cap

    # One more real attest: the intake path must evict the oldest consumed
    # row to make room — the table never exceeds the cap.
    assert {:ok, _token, _claims} =
             Maa.attest("SevSnpVM",
               runtime_data(%{"x-ms-measurement" => @measurement_hex, "nonce" => "p6-cap-probe"}),
               ts: now
             )

    assert table_size() <= cap, "table exceeded the entry cap: #{table_size()}"
    assert :ets.member(@nonce_table, "p6-cap-probe")

    # The evicted row is the OLDEST consumed one (ts now - 4000, key "1");
    # newer consumed rows survive.
    refute :ets.member(@nonce_table, "1")
    assert :ets.member(@nonce_table, Integer.to_string(cap))
  end

  @tag :smalt_internal
  test "P5 owner-ref: a nonceReplay-refused process cannot delete a live owner's :pending reservation" do
    nonce = "p5-owner-ref"

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    # Stage the owner's real in-flight reservation (module row shape): an
    # attest mid-flight holds exactly this row between reservation and flip.
    :ets.insert(@nonce_table, {nonce, owner, :pending, System.system_time(:second)})

    # A second process attests with the same nonce -> refused as replay, and
    # its failure path calls release_nonce/1.
    me = self()

    refused =
      spawn(fn ->
        send(
          me,
          {:refused,
           Maa.attest("SevSnpVM",
             runtime_data(%{"x-ms-measurement" => @measurement_hex, "nonce" => nonce})
           )}
        )

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:refused, {:error, 400, %{"error" => %{"code" => "nonceReplay"}}, _}}, 5_000

    # The refused process's release must NOT have deleted the owner's row.
    assert [{^nonce, ^owner, :pending, _}] = :ets.lookup(@nonce_table, nonce),
           "owner's :pending reservation was deleted by a foreign (refused) process"

    # The reservation is still the replay gate for a third process.
    assert {:error, 400, %{"error" => %{"code" => "nonceReplay"}}, _} =
             Maa.attest("SevSnpVM",
               runtime_data(%{"x-ms-measurement" => @measurement_hex, "nonce" => nonce})
             )

    send(refused, :stop)
    send(owner, :stop)
  end

  @tag :smalt_internal
  test "P5 concurrency: 50 concurrent same-nonce attests -> single burn, no cross-delete" do
    nonce = "p5-concurrent"
    me = self()

    results =
      1..50
      |> Enum.map(fn _ ->
        Task.async(fn ->
          Maa.attest("SevSnpVM",
            runtime_data(%{"x-ms-measurement" => @measurement_hex, "nonce" => nonce})
          )
        end)
      end)
      |> Enum.map(&Task.await(&1, 30_000))

    oks = Enum.count(results, &match?({:ok, _, _}, &1))
    replays = Enum.count(results, &match?({:error, 400, %{"error" => %{"code" => "nonceReplay"}}, _}, &1))

    assert oks == 1, "expected exactly 1 issue, got #{oks}"
    assert replays == 49, "expected 49 nonceReplay refusals, got #{replays}"

    # Single burn: exactly one row, flipped to :consumed (owner preserved).
    assert [{^nonce, _owner, :consumed, _ts}] = :ets.lookup(@nonce_table, nonce)
    assert table_size() == 1
  end
end
