defmodule Smalt.TwilioExt.TrustHub do
  @moduledoc "A2P 10DLC brand/campaign and SHAKEN/STIR trust-product objects (state machines, pure)."
  @use_cases ~w(2FA MARKETING CUSTOMER_CARE MIXED LOW_VOLUME)
  @attest ~w(A B C)

  def brand(%{"CustomerProfileBundleSid" => "BU" <> _ = bu, "A2PProfileBundleSid" => "BU" <> _ = a2p}),
    do: {:ok, %{"sid" => "BN" <> String.duplicate("0", 32), "customer_profile_bundle_sid" => bu,
                "a2p_profile_bundle_sid" => a2p, "status" => "PENDING", "tcr_id" => nil}}
  def brand(_), do: err(20001, "Invalid brand registration parameters")

  def approve_brand(%{"status" => "PENDING"} = b), do: {:ok, %{b | "status" => "APPROVED", "tcr_id" => "BXXXXXX"}}
  def approve_brand(_), do: err(20001, "Brand not pending")

  def campaign(%{"status" => "APPROVED"} = brand, %{"UseCase" => uc, "MessageSamples" => [_ | _] = _s})
      when uc in @use_cases,
      do: {:ok, %{"sid" => "QE" <> String.duplicate("0", 32), "brand_registration_sid" => brand["sid"],
                  "us_app_to_person_usecase" => uc, "campaign_status" => "IN_PROGRESS"}}
  def campaign(%{"status" => st}, _) when st != "APPROVED", do: err(20001, "Brand not approved")
  def campaign(_, _), do: err(20001, "Invalid campaign parameters")

  def shaken_stir(%{"EndUserSid" => "IT" <> _ = eu, "Attestation" => a}) when a in @attest,
    do: {:ok, %{"sid" => "BU" <> String.duplicate("0", 32), "policy" => "shaken_stir", "end_user_sid" => eu,
                "attestation" => a, "status" => "draft"}}
  def shaken_stir(_), do: err(20001, "Invalid SHAKEN/STIR trust product")

  def submit(%{"status" => "draft"} = t), do: {:ok, %{t | "status" => "pending-review"}}
  def submit(_), do: err(20001, "Trust product not draft")

  defp err(c, m), do: {:error, %{"code" => c, "message" => m, "status" => 400}}
end
