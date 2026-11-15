defmodule Smalt.H09.Vocab do
  @moduledoc """
  Named-constant vocabulary for the H09 tax/ERP/SWAR surface: routes, limits, error kinds,
  fixture tables. Everything the provider emits as a label lives here.
  """

  # ---- routes (relative to the mount point)
  def route(:ofac_screen), do: "/ofac/screen"
  def route(:ofac_list), do: "/ofac/list"
  def route(:fire_file), do: "/fire/1099"
  def route(:iris_submit), do: "/iris/submissions"
  def route(:iris_get), do: "/iris/submissions/:id"
  def route(:sales_tax), do: "/sales-tax/return"
  def route(:journal_validate), do: "/erp/journal/validate"
  def route(:journal_post), do: "/erp/journal"
  def route(:gl_accounts), do: "/erp/gl/accounts"
  def route(:trial_balance), do: "/erp/trial-balance"
  def route(:arap_sync), do: "/erp/arap/sync"
  def route(:arap_get), do: "/erp/arap/:entity/:kind"
  def route(:swar_admit), do: "/swar/admit"
  def route(:swar_gates), do: "/swar/gates"

  # ---- limits
  def fire_record_len, do: 750
  def screen_default_threshold_bps, do: 9000
  def vendor_discount_cap_cents, do: 5_000_00
  def vendor_discount_bps, do: 50
  def sales_tax_due_day, do: 20

  # ---- general ledger (fixture chart; intercompany accounts for elimination)
  def gl_accounts do
    [
      %{id: "1000", name: "Cash", type: "asset", normal: "debit"},
      %{id: "1200", name: "Accounts Receivable", type: "ar", normal: "debit"},
      %{id: "1300", name: "Intercompany Receivable", type: "asset", normal: "debit"},
      %{id: "2000", name: "Accounts Payable", type: "ap", normal: "credit"},
      %{id: "2100", name: "Sales Tax Payable", type: "liability", normal: "credit"},
      %{id: "2300", name: "Intercompany Payable", type: "liability", normal: "credit"},
      %{id: "3000", name: "Retained Earnings", type: "equity", normal: "credit"},
      %{id: "4000", name: "Revenue", type: "revenue", normal: "credit"},
      %{id: "5000", name: "Expenses", type: "expense", normal: "debit"}
    ]
  end

  # ---- state sales tax fixture rates (basis points of the taxable base)
  def state_rates_bps do
    %{"TX" => 625, "CA" => 725, "NY" => 400, "FL" => 600, "WA" => 650, "OR" => 0}
  end

  # ---- SDN fixture list (synthetic entities; not real designations)
  def sdn_fixture do
    [
      %{id: "FX-1001", name: "NORTHERN STAR MARITIME CO", aliases: ["N STAR SHIPPING"], program: "FIXTURE-SDGT"},
      %{id: "FX-1002", name: "BLUE HORIZON IMPORT EXPORT LLC", aliases: ["BLUEHORIZON TRADING"], program: "FIXTURE-IRAN"},
      %{id: "FX-1003", name: "GOLDEN CRESCENT HOLDINGS", aliases: [], program: "FIXTURE-RUSSIA"},
      %{id: "FX-1004", name: "ZENITH LOGISTICS FZE", aliases: ["ZENITH LOGISTIC"], program: "FIXTURE-CUBA"},
      %{id: "FX-1005", name: "ORCHID TRADING COMPANY", aliases: ["ORKID TRADING"], program: "FIXTURE-DPRK"}
    ]
  end

  # ---- error kinds
  def err(:invalid), do: :invalid_request
  def err(:unbalanced), do: :unbalanced_entry
  def err(:unknown_account), do: :unknown_account
  def err(:duplicate), do: :duplicate_entry
  def err(:unknown_state), do: :unknown_state
  def err(:bad_period), do: :bad_period
  def err(:not_found), do: :not_found
end
