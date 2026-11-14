defmodule Smalt.Twilio.LookupVerifyTest do
  use ExUnit.Case, async: true
  alias Smalt.Twilio.{Lookup, Verify}

  @va "VA" <> String.duplicate("0", 32)

  test "lookup valid magic number with sim_swap" do
    {:ok, r} = Lookup.fetch(Lookup.magic().valid, "sim_swap")
    assert r["valid"] == true
    assert r["national_format"] == "(500) 555-0006"
    assert r["sim_swap"]["last_sim_swap"]["swapped_in_period"] == false
    assert r["url"] == "https://lookups.twilio.com/v2/PhoneNumbers/%2B15005550006"
  end

  test "lookup invalid and swapped magic numbers" do
    {:ok, bad} = Lookup.fetch(Lookup.magic().invalid)
    assert bad["valid"] == false and bad["validation_errors"] == ["INVALID_NUMBER"]
    {:ok, sw} = Lookup.fetch(Lookup.magic().swapped, "sim_swap")
    assert sw["sim_swap"]["last_sim_swap"]["swapped_in_period"] == true
    {:ok, no} = Lookup.fetch(Lookup.magic().swapped)
    assert no["sim_swap"] == nil
  end

  test "verify create then check approves magic code only" do
    {:ok, v} = Verify.create(@va, %{"To" => "+15005550006", "Channel" => "sms"})
    assert v["status"] == "pending" and String.starts_with?(v["sid"], "VE")
    {:ok, a} = Verify.check(@va, %{"To" => "+15005550006", "Code" => Verify.magic().code})
    assert a["status"] == "approved" and a["valid"] == true
    {:ok, p} = Verify.check(@va, %{"To" => "+15005550006", "Code" => "000000"})
    assert p["status"] == "pending" and p["valid"] == false
  end

  test "verify refusals are typed" do
    assert {:error, %{"code" => 60200, "status" => 400}} =
             Verify.create(@va, %{"To" => Verify.magic().invalid_to})

    assert {:error, %{"code" => 20404, "status" => 404}} =
             Verify.create("VAbad", %{"To" => "+15005550006"})
  end
end
