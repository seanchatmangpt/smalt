defmodule Smalt.Gatemask do
  @moduledoc """
  64-bit external gate mask (port of fnox fibo/swar_gate.py): 16 named bits,
  required mask 0xFFFF, refusal 0xE300 ||| lowest-missing-bit.
  """
  import Bitwise

  @gates ~w(SENDER_DKIM_SMIME CARRIER_SIM_CLEAN ENTITY_GOOD_STAND OFAC_BOI_CLEAR
            IRS_TIN_MATCHED LICENSE_EPA_VALID COI_CARRIER_LIVE CMMS_NTE_LOCKED
            EDI_BOM_CONFIRMED DUAL_CLOCK_CAUSAL WEBRTC_VISION_QA PLAID_ROUTING_OWNED
            UCC9_LIEN_PERFECTED ENCLAVE_HW_ATTESTED SHACL_CENT_BALANCED AFFI_MLDSA65_SEALED)
  @required 0xFFFF
  @m64 0xFFFFFFFFFFFFFFFF

  @spec gates() :: [String.t()]
  def gates, do: @gates

  @spec bit(String.t()) :: non_neg_integer()
  def bit(name) do
    case Enum.find_index(@gates, &(&1 == name)) do
      nil -> raise ArgumentError, "unknown gate #{name}"
      i -> 1 <<< i
    end
  end

  @spec set_gate(non_neg_integer(), String.t()) :: non_neg_integer()
  def set_gate(mask, name), do: (mask ||| bit(name)) &&& @m64

  @doc "`:admitted` or `{:refused, 0xE300 ||| lowest_missing_bit}`."
  @spec admit_instant_wire(non_neg_integer()) :: :admitted | {:refused, non_neg_integer()}
  def admit_instant_wire(row_mask) do
    missing = @required &&& bnot(row_mask) &&& @m64

    if missing == 0 do
      :admitted
    else
      {:refused, 0xE300 ||| lowest_bit_index(missing, 0)}
    end
  end

  defp lowest_bit_index(n, i) when (n &&& 1) == 1, do: i
  defp lowest_bit_index(n, i), do: lowest_bit_index(n >>> 1, i + 1)
end
