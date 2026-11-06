defmodule Smalt.DataPlane.Cosmos.AuthVerbCaseTest do
  # KD-G19 witness: real Azure Cosmos signs the UPPERCASE verb. The fix at
  # lib/smalt/data_plane/cosmos/auth.ex:73-75 upcases the verb inside
  # string_to_sign/4; these legs prove (1) the string-to-sign carries
  # "GET\n" as its first member, (2) a signature minted over the uppercase
  # string-to-sign validates, and (3) a signature minted over the lowercase
  # (pre-fix) string-to-sign is REJECTED — the fix is load-bearing.
  # Pure crypto/string asserts: no HTTP, no AAD fetch.
  use ExUnit.Case, async: true

  alias Smalt.DataPlane.Cosmos.Auth

  @verb :get
  @resource_type "dbs"
  @resource_link "dbs/mydb"
  @headers %{"x-ms-date" => "Mon, 06 Nov 2026 00:00:00 GMT"}
  @key "cltevUjABCcUGzgauOAEGC5f4VZQT3dPrOIWTn2YXvPFfJmBvnfJ2jN9aifUkA2TnKFnCKcUYQSTRx0VtOhqiQ=="

  defp sig_over(string_to_sign) do
    :crypto.mac(:hmac, :sha256, @key, string_to_sign)
    |> Base.encode64()
  end

  test "string_to_sign/4 first member is the UPPERCASE verb" do
    sts = Auth.string_to_sign(@verb, @resource_type, @resource_link, @headers)
    [verb_member | _] = String.split(sts, "\n")
    assert verb_member == "GET"
    refute verb_member == "get"
    # Full shape sanity: verb / type / link / downcased date / two empty members
    assert sts ==
             "GET\ndbs\ndbs/mydb\nmon, 06 nov 2026 00:00:00 gmt\n\n"
  end

  test "sig minted over the UPPERCASE string-to-sign validates" do
    sts = Auth.string_to_sign(@verb, @resource_type, @resource_link, @headers)
    sig = sig_over(sts)

    assert Auth.valid_master_sig?(
             @verb,
             @resource_type,
             @resource_link,
             @headers,
             sig,
             @key
           )
  end

  test "sig minted over the LOWERCASE string-to-sign is rejected" do
    lowercase_sts =
      "get\n#{@resource_type}\n#{@resource_link}\n#{String.downcase("Mon, 06 Nov 2026 00:00:00 GMT")}\n\n"

    sig = sig_over(lowercase_sts)

    refute Auth.valid_master_sig?(
             @verb,
             @resource_type,
             @resource_link,
             @headers,
             sig,
             @key
           )
  end
end
