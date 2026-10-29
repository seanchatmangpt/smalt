# BK-85 seal invariant gate court (v26.10.22, lane bk85).
#
# Falsifier for the SPOF-3 observation ("seal invariant gate fails
# deterministically on any probe delta; no successful-seal test exists in
# the tree"):
#
#   Root cause (receipt bk85-seal-invariant.md): CALLER BUG, not layout
#   drift. `run_seal/5` allocated the guest delta block via af_alloc(len)
#   but never WROTE the delta bytes into it — the guest hashed stale heap,
#   so the host blake3(delta) leg of the invariant gate never bound and
#   every seal refused {:error, :invariant_violation} deterministically.
#   Fix: write_mem(delta_ptr, delta) before the affi_admit_and_seal export.
#
# Court legs (Chicago: real wasm artifact, real NIF, real b3sum):
#   1. SUCCESSFUL seal via call_admit_and_seal/4: {:ok, %{ctrt_bytes,
#      pqc_receipt}}, 352 bytes, blake3 leg binds (guest [70..102] ==
#      host b3sum --raw blake3(delta)), tariff/modality/anchor legs.
#   2. Successful seal via the JSON seam affi_admit_and_seal/1
#      (Smalt.Affidavit.Seal.admit_and_seal/2 end-to-end).
#   3. NON-VACUITY of the gate: tamper leg lives in the shim court
#      scripts/shim_court/bk85_gate_court.sh (BEFORE landed-seal-ok → SHIM
#      corrupt-host-hash → AFTER invariant_violation → RESTORE sha-exact);
#      an in-process test cannot inject a tampered ctrt without a shim.
#
# Bounded polls only, zero sleeps.

Code.require_file("poll_helper.exs", __DIR__)

defmodule InternalTier.Bk85SealInvariantCourtTest do
  use ExUnit.Case, async: false

  import SmaltTest.Internal.Poll, only: [eventually: 1]

  alias Smalt.Affidavit.{Seal, WasmEngine}

  setup do
    assert {:ok, engine_pid} =
             eventually(fn ->
               case Process.whereis(WasmEngine) do
                 pid when is_pid(pid) -> {:ok, pid}
                 nil -> {:engine_down, false}
               end
             end)

    {:ok, engine: engine_pid}
  end

  defp host_blake3(delta) do
    tmp = Path.join(System.tmp_dir!(), "bk85-court-" <> Integer.to_string(System.system_time()))

    File.write!(tmp, delta)

    try do
      case System.cmd("b3sum", ["--raw", tmp]) do
        {raw, 0} -> raw
        _ -> flunk("b3sum failed")
      end
    after
      File.rm(tmp)
    end
  end

  @tag :smalt_internal
  test "successful seal: guest CTRT [70..102] binds host blake3(delta); structural legs hold" do
    delta = Jason.encode!(%{probe: "bk85-court", n: System.unique_integer([:positive])})
    tariff = 4_242

    assert {:ok, %{ctrt_bytes: ctrt, pqc_receipt: pqc}} =
             WasmEngine.call_admit_and_seal(delta, tariff, 1, %{})

    assert byte_size(ctrt) == 352
    assert binary_part(ctrt, 0, 4) == "CTRT"
    assert binary_part(ctrt, 4, 2) == <<1::little-unsigned-integer-size(16)>>

    # blake3 leg: the guest hash is exactly the host's blake3 of the delta.
    assert binary_part(ctrt, 70, 32) == host_blake3(delta)
    assert binary_part(ctrt, 151, 10) == "GAIN_5050" <> <<0>>
    assert binary_part(ctrt, 167, 8) == <<tariff::little-unsigned-integer-size(64)>>
    assert binary_part(ctrt, 175, 1) == <<1>>

    # nullifier = blake3(delta_hash); PQC receipt = verified nullifier segment.
    assert pqc == binary_part(ctrt, 176, 32)
  end

  @tag :smalt_internal
  test "FORBID modality seals and binds modality byte 0x02" do
    delta = Jason.encode!(%{probe: "bk85-forbid"})

    assert {:ok, %{ctrt_bytes: ctrt, pqc_receipt: _}} =
             WasmEngine.call_admit_and_seal(delta, 0, 2, %{})

    assert binary_part(ctrt, 175, 1) == <<2>>
    assert binary_part(ctrt, 70, 32) == host_blake3(delta)
  end

  @tag :smalt_internal
  test "JSON seam end-to-end: Seal.admit_and_seal/2 seals a five-R-field receipt" do
    receipt = %{
      subject_sha: "bk85-" <> Integer.to_string(System.system_time()),
      authority: "lane-bk85",
      consequence: "successful seal witnessed",
      replay: "test/internal/bk85_seal_invariant_court_test.exs",
      standing: "PASS"
    }

    assert {:ok, %{sealed: sealed, receipt: canonical}} = Seal.admit_and_seal(receipt)
    assert byte_size(sealed) == 352
    assert binary_part(sealed, 0, 4) == "CTRT"
    assert binary_part(sealed, 70, 32) == host_blake3(canonical)
    assert is_binary(canonical)
  end
end
