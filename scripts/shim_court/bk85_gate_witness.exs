# BK-85 gate tamper-court witness.
#
# Usage: mix run --no-start scripts/shim_court/bk85_gate_witness.exs ok
#        mix run --no-start --eval-halt... (see court script)
#
# mode `ok`    : a real seal MUST succeed (landed behavior).
# mode `tamper`: a real seal MUST refuse {:error, :invariant_violation}
#                (the shimmed gate's corrupted host hash leg).
alias Smalt.Affidavit.WasmEngine

{:ok, _} = WasmEngine.start_link([])
[mode] = System.argv()

delta = "bk85-tamper-probe-" <> Integer.to_string(System.system_time())

case WasmEngine.call_admit_and_seal(delta, 7, 1, %{}) do
  {:ok, %{ctrt_bytes: ctrt}} when byte_size(ctrt) == 352 ->
    :ok = if mode == "ok", do: :ok, else: throw(:unexpected_ok)

  {:error, :invariant_violation} ->
    :ok = if mode == "tamper", do: :ok, else: throw(:unexpected_refusal)

  other ->
    throw({:unexpected_engine_return, other})
end

IO.puts("WITNESS-#{mode}-PASS")
System.halt(0)
