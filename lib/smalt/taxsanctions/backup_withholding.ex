defmodule Smalt.TaxSanctions.BackupWithholding do
  @moduledoc "24% backup-withholding diversion on TIN mismatch (IRC 3406)."
  alias Smalt.TaxSanctions.TinMatch

  @rate_bps 2400

  def rate_bps, do: @rate_bps

  @doc "Amounts in integer cents."
  def divert(amount_cents, code) when is_integer(amount_cents) and amount_cents >= 0 do
    if TinMatch.matched?(code) do
      %{withhold?: false, withheld_cents: 0, payee_cents: amount_cents, code: code}
    else
      w = div(amount_cents * @rate_bps + 5000, 10_000)
      %{withhold?: true, withheld_cents: w, payee_cents: amount_cents - w, code: code}
    end
  end
end
