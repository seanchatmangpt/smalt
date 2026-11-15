defmodule Smalt.H08.Vocab do
  @moduledoc """
  Named-constant vocabulary for the H08 treasury and rates surface: ASA result codes,
  ISO 20022 external reason codes, Plaid error codes, NACHA transaction codes, the
  SOFR curve knots and the ABS tape assignment cycles. Handlers emit these, never
  inline strings.
  """

  # Lithic ASA result enum (subset served by the decision engine).
  def asa_approve, do: "APPROVE"
  def asa_card_closed, do: "CARD_CLOSED"
  def asa_card_paused, do: "CARD_PAUSED"
  def asa_insufficient_funds, do: "INSUFFICIENT_FUNDS"
  def asa_unauthorized_merchant, do: "UNAUTHORIZED_MERCHANT"
  def asa_account_state_fail, do: "ACCOUNT_STATE_TRANSACTION_FAIL"

  def card_states, do: ["OPEN", "PAUSED", "CLOSED"]

  # ISO 20022 ExternalStatusReason1Code values used in pain.002-style reports.
  def reason_insufficient_funds, do: "AM04"
  def reason_not_allowed_amount, do: "AM02"
  def reason_not_allowed_currency, do: "AM03"
  def reason_incorrect_account, do: "AC01"
  def reason_duplicate, do: "DUPL"
  def reason_file_format, do: "FF01"

  def tx_settled, do: "ACSC"
  def tx_rejected, do: "RJCT"
  def group_accepted, do: "ACCP"
  def group_rejected, do: "RJCT"
  def group_partial, do: "PART"

  def currency, do: "USD"
  def epoch_stamp, do: "1970-01-01T00:00:00"

  # Plaid error codes.
  def plaid_invalid_token, do: {"ITEM_ERROR", "INVALID_ACCESS_TOKEN"}
  def plaid_invalid_field, do: {"INVALID_REQUEST", "INVALID_FIELD"}
  def plaid_missing_field, do: {"INVALID_REQUEST", "MISSING_FIELDS"}

  # NACHA transaction codes: {code, direction, account type}.
  def nacha_codes,
    do: %{"22" => :credit, "32" => :credit, "27" => :debit, "37" => :debit}

  def nacha_service_classes, do: ["200", "220", "225"]
  def nacha_secs, do: ["PPD", "CCD", "WEB"]
  def nacha_blocking_factor, do: 10
  def nacha_record_len, do: 94

  # SOFR curve knots: {tenor_days, offset_bps from the latest SOFR print}.
  def curve_knots,
    do: [{30, -2}, {91, -8}, {182, -15}, {365, -22}, {730, -30}, {1825, -12}, {3650, 8}]

  # ABS tape assignment cycles (deterministic by loan index).
  def tape_rates_bps, do: [1099, 1249, 1399, 1549, 1799]
  def tape_terms, do: [36, 48, 60, 72]
  def tape_seasoning, do: [0, 3, 6, 9, 12]
end
