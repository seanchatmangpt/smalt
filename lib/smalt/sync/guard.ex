defmodule Smalt.Sync.Guard do
  @moduledoc """
  ATH-1 per-frame governance dispatch. The verdict contract is the
  operator's byte contract:

      {:admit, <<0::8>>}                        — admit
      {:andon, <<1::8, ReasonLen::16, Reason::binary>>} — immediate ANDON,
      commit never fires for the frame

  Seam (identical shape to `Smalt.Powl2.Executor.run_guard/4`'s nil arm):
  `run_guard/2` with a `nil` guard admits — the stub/unset face. When
  `:smalt, :sync_guard` is `:wasm`, the frame payload is dispatched through
  the EXISTING `Smalt.Wasm.Bridge` path (`eval/2`, pool + packet-4 port;
  with `:wasm_binary_path` unset the stub runner face applies, same as
  everywhere else in the repo — no new sandbox seam is invented).

  A configured refuse-op (`:smalt, :sync_guard => {:fun, fun}`) lets a
  court inject a REAL law function (never a mock) that returns the verdict
  bytes above.
  """

  alias Smalt.Wasm.Bridge

  @doc "Decodes a verdict map from `Bridge.eval/2` into the byte contract."
  def verdict_bytes({:ok, %{"conforms" => true}}), do: {:admit, <<0::8>>}

  def verdict_bytes({:ok, %{"conforms" => false} = verdict}) do
    reason = verdict["reason"] || "law-refused"
    {:andon, <<1::8, byte_size(reason)::16, reason::binary>>}
  end

  def verdict_bytes({:ok, %{"ok" => false, "error" => %{"message" => msg}}}) do
    {:andon, <<1::8, byte_size(msg)::16, msg::binary>>}
  end

  def verdict_bytes({:ok, %{"result" => %{"error" => msg}}}) when is_binary(msg) do
    {:andon, <<1::8, byte_size(msg)::16, msg::binary>>}
  end

  def verdict_bytes({:error, {:abi_refusal, %{message: msg}}}) do
    {:andon, <<1::8, byte_size(msg)::16, msg::binary>>}
  end

  def verdict_bytes(other) do
    msg = "guard-unresolved: " <> inspect(other)
    {:andon, <<1::8, byte_size(msg)::16, msg::binary>>}
  end

  @doc """
  Runs the configured guard for one frame payload.

      nil               -> {:admit, <<0>>}          (unset seam, admit face)
      {:fun, fun}       -> fun.(payload) verdict bytes enforced
      :wasm             -> Smalt.Wasm.Bridge.eval/2, verdict mapped to bytes
  """
  def run_guard(payload, guard) when is_binary(payload) do
    case guard || Application.get_env(:smalt, :sync_guard) do
      nil ->
        {:admit, <<0::8>>}

      {:fun, fun} when is_function(fun, 1) ->
        normalize(fun.(payload))

      :wasm ->
        request = Bridge.pack_focus_node(%{"text" => Base.encode64(payload)})
        Bridge.eval(request) |> verdict_bytes()
    end
  end

  defp normalize({:admit, _} = ok), do: ok

  defp normalize({:andon, <<1::8, len::16, reason::binary>>}) when byte_size(reason) == len,
    do: {:andon, <<1::8, len::16, reason::binary>>}

  defp normalize(other) do
    msg = "guard-invalid-verdict: " <> inspect(other)
    {:andon, <<1::8, byte_size(msg)::16, msg::binary>>}
  end

  @doc "Reason bytes out of an ANDON verdict."
  def reason({:andon, <<1::8, _len::16, reason::binary>>}), do: reason
end
