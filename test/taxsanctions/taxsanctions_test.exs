defmodule Smalt.TaxSanctionsTest do
  use ExUnit.Case, async: true
  alias Smalt.TaxSanctions.{TinMatch, BackupWithholding, Form1099, W8BenE, Vies, Screening}

  @reg %{"123456789" => %{name: "Acme LLC", type: :ein}, "987654321" => %{name: "Jane Doe", type: :ssn}}

  test "tin match codes" do
    assert TinMatch.match("Acme, LLC", "12-3456789", @reg) == 7
    assert TinMatch.match("Jane Doe", "987654321", @reg) == 6
    assert TinMatch.match("Jane Doe", "12345", @reg) == 1
    assert TinMatch.match("Jane Doe", "111111111", @reg) == 2
    assert TinMatch.match("Bob", "987654321", @reg) == 3
    assert TinMatch.match("", "987654321", @reg) == 4
    seen = MapSet.new([{"JANEDOE", "987654321"}])
    assert TinMatch.match("Jane Doe", "987654321", @reg, seen) == 5
    assert TinMatch.code_meaning(8) == :matched_ssn_and_ein
  end

  test "backup withholding 24% on mismatch only" do
    assert %{withheld_cents: 2400, payee_cents: 7600} = BackupWithholding.divert(10_000, 3)
    assert %{withhold?: false, payee_cents: 10_000} = BackupWithholding.divert(10_000, 6)
  end

  test "1099 builders" do
    a = %{payer_tin: "123456789", payee_tin: "987654321", payee_name: "J", tax_year: 2026, nonemployee_comp_cents: 70_000}
    assert {:ok, %{form: "1099-NEC", filing_required?: true}} = Form1099.nec(a)
    assert {:error, :bad_tin} = Form1099.nec(%{a | payee_tin: "1"})
    assert {:error, {:missing, [:payee_name]}} = Form1099.nec(%{a | payee_name: ""})
    k = %{filer_tin: "123456789", payee_tin: "987654321", payee_name: "J", tax_year: 2026, monthly_gross_cents: List.duplicate(100, 12)}
    assert {:ok, %{box1a_gross_cents: 1200}} = Form1099.k(k)
    assert {:error, :monthly_gross_must_have_12} = Form1099.k(%{k | monthly_gross_cents: [1]})
  end

  test "w8ben-e" do
    f = %{entity_name: "GmbH", country_of_incorporation: "DE", chapter3_status: "corporation",
          permanent_address: "x", signature: "s", signed_on: ~D[2026-01-01], capacity: "dir"}
    assert :ok = W8BenE.validate(f)
    assert {:error, errs} = W8BenE.validate(%{f | country_of_incorporation: "US", signature: nil})
    assert {:invalid, :us_entity_must_use_w9} in errs and {:missing, :signature} in errs
    assert {:error, [{:missing, :limitation_on_benefits}]} = W8BenE.validate(Map.put(f, :treaty_country, "DE"))
    assert W8BenE.expires_on(~D[2026-05-05]) == ~D[2029-12-31]
  end

  test "vies and dac7" do
    r = MapSet.new(["DE123456789"])
    assert %{valid: true} = Vies.check("de 123456789", r)
    assert %{reason: :not_registered} = Vies.check("DE999999999", r)
    assert %{reason: :bad_format} = Vies.check("DE12", r)
    assert %{reason: :unsupported_country} = Vies.check("ZZ1", r)

    rep = Vies.dac7_report(%{platform_id: "P", year: 2026, sellers: [
      %{name: "A", tin: "1", residence: "DE", listings: 1, activities: 40, quarterly_consideration_cents: [1, 2, 3, 4]},
      %{name: "B", tin: "2", residence: "FR", listings: 1, activities: 2, quarterly_consideration_cents: [1, 1, 1, 1]}]})
    assert [%{seller_name: "A", total_consideration_cents: 10}] = rep.sellers
  end

  test "r2 hardening" do
    reg = %{"123456789" => %{name: "X", type: :weird}}
    assert {:error, {:unknown_registry_type, :weird}} = TinMatch.match("X", "123456789", reg)

    a = %{payer_tin: "123456789", payee_tin: "987654321", payee_name: "J", tax_year: 2026, nonemployee_comp_cents: 100}
    assert {:error, :bad_tin} = Form1099.nec(%{a | payee_tin: "987654321\n"})
    assert {:error, :bad_withholding} = Form1099.nec(Map.put(a, :federal_withheld_cents, 101))
    k = %{filer_tin: "123456789", payee_tin: "987654321", payee_name: "J", tax_year: 2026, monthly_gross_cents: List.duplicate(100, 12)}
    assert {:error, :bad_amount} = Form1099.k(%{k | monthly_gross_cents: [-1 | List.duplicate(100, 11)]})
    assert {:error, :bad_amount} = Form1099.k(%{k | monthly_gross_cents: [1.5 | List.duplicate(100, 11)]})

    f = %{entity_name: "G", country_of_incorporation: "de", chapter3_status: "corporation",
          permanent_address: "x", signature: "s", signed_on: ~D[2026-01-01], capacity: "dir"}
    assert :ok = W8BenE.validate(f)
    assert {:error, e1} = W8BenE.validate(%{f | country_of_incorporation: "usa"})
    assert {:invalid, :us_entity_must_use_w9} in e1
    assert {:error, e2} = W8BenE.validate(%{f | country_of_incorporation: " us "})
    assert {:invalid, :us_entity_must_use_w9} in e2
    t = Map.merge(f, %{treaty_country: "DE", lob_qualified: true})
    assert :ok = W8BenE.validate(Map.put(t, :treaty_rate_pct, 15))
    assert {:error, [{:invalid, :treaty_rate_pct}]} = W8BenE.validate(Map.put(t, :treaty_rate_pct, 31))
    assert {:error, [{:missing, :treaty_rate_pct}]} = W8BenE.validate(Map.put(t, :treaty_rate_pct, 7.5))
  end

  test "screening containment" do
    list = [%{id: "2", name: "BANCO NACIONAL DE CUBA", aliases: nil, program: "CUBA"}]
    assert %{status: :potential_match} = Screening.result("BANCO NACIONAL DE CUBA S A", list)
    one = [%{id: "3", name: "Petrov", program: "X"}]
    assert %{status: :clear} = Screening.result("Ivan Petrov", one)
  end

  test "screening" do
    list = [%{id: "1", name: "Ivan Petrov", aliases: ["Ivan P Petrov"], program: "SDGT"}]
    assert %{status: :potential_match, hits: [%{id: "1", score: 1.0}]} = Screening.result("PETROV, Ivan", list)
    assert %{status: :clear} = Screening.result("Maria Lopez", list)
  end
end
