defmodule Smalt.TaxSanctions.Form1099 do
  @moduledoc "1099-NEC / 1099-K record builders with required-field validation."

  @nec_threshold 60_000
  @tin ~r/^\d{9}$/

  def nec(%{} = a) do
    with :ok <- req(a, [:payer_tin, :payee_tin, :payee_name, :tax_year, :nonemployee_comp_cents]),
         :ok <- tins(a.payer_tin, a.payee_tin),
         :ok <- pos(a.nonemployee_comp_cents) do
      {:ok,
       %{
         form: "1099-NEC",
         tax_year: a.tax_year,
         payer_tin: a.payer_tin,
         recipient_tin: a.payee_tin,
         recipient_name: a.payee_name,
         box1_nonemployee_compensation_cents: a.nonemployee_comp_cents,
         box4_federal_withheld_cents: Map.get(a, :federal_withheld_cents, 0),
         filing_required?: a.nonemployee_comp_cents >= @nec_threshold
       }}
    end
  end

  def k(%{} = a) do
    with :ok <- req(a, [:filer_tin, :payee_tin, :payee_name, :tax_year, :monthly_gross_cents]),
         :ok <- tins(a.filer_tin, a.payee_tin),
         :ok <- twelve(a.monthly_gross_cents) do
      {:ok,
       %{
         form: "1099-K",
         tax_year: a.tax_year,
         filer_tin: a.filer_tin,
         payee_tin: a.payee_tin,
         payee_name: a.payee_name,
         box1a_gross_cents: Enum.sum(a.monthly_gross_cents),
         box5_monthly: a.monthly_gross_cents,
         box4_federal_withheld_cents: Map.get(a, :federal_withheld_cents, 0)
       }}
    end
  end

  defp twelve(l) when is_list(l) and length(l) == 12, do: :ok
  defp twelve(_), do: {:error, :monthly_gross_must_have_12}

  defp req(a, keys) do
    case Enum.filter(keys, &(Map.get(a, &1) in [nil, ""])) do
      [] -> :ok
      m -> {:error, {:missing, m}}
    end
  end

  defp tins(p, q) do
    if Regex.match?(@tin, p) and Regex.match?(@tin, q), do: :ok, else: {:error, :bad_tin}
  end

  defp pos(n) when is_integer(n) and n >= 0, do: :ok
  defp pos(_), do: {:error, :bad_amount}
end
