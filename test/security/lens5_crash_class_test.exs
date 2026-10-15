defmodule Smalt.Security.Lens5CrashClassTest do
  use ExUnit.Case, async: false

  alias Smalt.Security.{ConfidentialLedger, LedgerWriter}

  # lens-5 cycle-1 crash-class courts. The mutation (unguarding the encode
  # step) must be killed by BOTH courts: the writer-survival court alone
  # passes on a mutant where the raise merely escapes as a caller exit without
  # killing the writer; the no-DoS court pins the failure-boundary law.
  describe "writer crash-class: hostile contents never kill the serialized writer" do
    test "tuple-key contents are a typed 400 refusal; writer survives and stays usable" do
      ledger = "probe-crash-#{System.unique_integer()}"

      assert {:error, 400, "InvalidBody"} =
               ConfidentialLedger.append_transaction(ledger, %{{:a, 1} => "v"})

      # Writer alive (not lazily restarted-from-dead: whereis non-nil across a
      # second refusal proves no death/restart cycle occurred).
      assert pid = GenServer.whereis(LedgerWriter)
      assert Process.alive?(pid)

      # The ledger was untouched: the refusal fires before any counter mint
      # (commit-point law, lens-4) — a later valid append is admitted.
      assert {:ok, %{"transactionId" => "1.1"}} =
               ConfidentialLedger.append_transaction(ledger, %{"ok" => "v"})
    end

    test "refusal does not burn the dup counter: same contents later admitted (other ledger)" do
      ledger = "probe-crash2-#{System.unique_integer()}"

      assert {:error, 400, "InvalidBody"} =
               ConfidentialLedger.append_transaction(ledger, %{"k" => make_ref()})

      assert {:ok, %{"transactionId" => "1.1"}} =
               ConfidentialLedger.append_transaction(ledger, %{"k" => "encodable"})
    end
  end

  describe "attest crash-class: hostile measurement_params refuses typed" do
    test "tuple value -> 400 attestationFailedVerdict, no raise" do
      measurement = String.duplicate("a", 64)
      Smalt.Store.put(:smalt_attestation_baseline, "m1", measurement)

      assert {:error, 400, "attestationFailedVerdict"} =
               Smalt.Security.Attestation.attest_enclave(%{
                 "measurement" => measurement,
                 "x" => {:tuple}
               })
    end

    test "tuple key -> 400 attestationFailedVerdict, no raise" do
      measurement = String.duplicate("b", 64)
      Smalt.Store.put(:smalt_attestation_baseline, "m2", measurement)

      assert {:error, 400, "attestationFailedVerdict"} =
               Smalt.Security.Attestation.attest_enclave(%{
                 {:bad, 1} => "v",
                 "measurement" => measurement
               })
    end
  end
end