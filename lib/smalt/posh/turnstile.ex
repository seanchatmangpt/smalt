defmodule Smalt.Posh.Turnstile do
  @moduledoc """
  The S3 turnstile (POSH-002): no unreceipted delta passes.

  admit(route, payload, state_root) validates via Admission (let-it-crash task
  admission), then settles via Settlement into a 32-byte receipt. Typed refusal
  short-circuits before any settlement — the type signature is the fence:
  an `{:ok, %{delta, receipt}}` exists only for a receipted delta.
  """

  @doc """
  Admits a payload at a route against `policy`, settling the resulting delta
  against `state_root`.

  Opts: `:timestamp_ns`, `:node_id`, `:log_name`, `:op`, and `:payload_body`
  (the raw request body, threaded to Settlement for the BLAKE3 digest).

      {:ok, %{delta: delta, receipt: <<_::256>>, ...}}
      {:refused, :no_admission_policy}
      {:refused, {:shape_violation, details}}
      {:refused, {:admission_crash, reason}}
  """
  @spec admit(Smalt.Posh.Ingress.Admission.t(), term(), map(), String.t(), keyword()) ::
          {:ok, map()} | {:refused, term()}
  def admit(policy, route, payload, state_root, opts \\ []) do
    case Smalt.Posh.Ingress.Admission.validate_task(policy, route, payload, opts) do
      {:admitted, delta} ->
        settle_opts =
          opts
          |> Keyword.take([:timestamp_ns, :node_id, :log_name, :op, :payload_body])
          |> Keyword.put_new(:node_id, "smalt-node-1")

        case Smalt.Posh.Egress.Settlement.settle(delta, settle_opts[:node_id], state_root, settle_opts) do
          {:ok, settlement} -> {:ok, Map.put(settlement, :delta, delta)}
        end

      {:refused, _} = refused ->
        refused
    end
  end
end
