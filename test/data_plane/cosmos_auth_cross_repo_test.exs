defmodule Smalt.DataPlane.Cosmos.AuthCrossRepoTest do
  # KD-G19 cross-repo handshake leg (smalt side). The arcus mint helper
  # (arcus/scripts/kd_g19_mint) writes a JSON fixture carrying its
  # Authorization header + newline-escaped string-to-sign; this test rebuilds
  # the string-to-sign with the smalt law (auth.ex string_to_sign/4, now
  # uppercase-verb post R-SMALT1), HMACs it with the SAME base64-decoded key
  # (arcus decodes before HMAC — see cosmos_auth.go CosmosMasterSig), and
  # asserts valid_master_sig?/6 accepts the arcus sig. Negative leg: a sig
  # over the LOWERCASE string-to-sign (the pre-R-SMALT1 law) is rejected.
  #
  # Fixture path comes from KD_G19_FIXTURE (written by the court script
  # arcus/scripts/kd_g19_handshake.sh). Chicago discipline: the fixture is a
  # real artifact produced by really running the Go mint helper — no mocks.
  use ExUnit.Case, async: true

  alias Smalt.DataPlane.Cosmos.Auth

  @resource_type "dbs"
  @resource_link "dbs/mydb"

  test "arcus-minted cosmos master-key sig validates under the smalt law" do
    path = System.get_env("KD_G19_FIXTURE") ||
             flunk("KD_G19_FIXTURE env var must point at the arcus mint fixture")

    fixture = path |> File.read!() |> Jason.decode!()

    verb = :get
    headers = %{"x-ms-date" => fixture["date"]}

    key_bytes = Base.decode64!(fixture["key"])

    arcus_sts = String.replace(fixture["string_to_sign"], "\\n", "\n")

    smalt_sts = Auth.string_to_sign(verb, @resource_type, @resource_link, headers)

    # Cross-repo agreement: the two laws derive the identical string-to-sign.
    assert smalt_sts == arcus_sts

    # And the arcus Authorization header validates (same decoded key bytes).
    assert Auth.valid_master_sig?(
             verb,
             @resource_type,
             @resource_link,
             headers,
             fixture["sig"],
             key_bytes
           )

    # Wire-shape check: the header carries the exact Cosmos envelope literal.
    assert String.starts_with?(
             fixture["authorization"],
             "type%3dmaster%26ver%3d1.0%26sig%3d"
           )
  end

  test "a sig over the LOWERCASE string-to-sign is rejected (negative leg)" do
    path = System.get_env("KD_G19_FIXTURE") ||
             flunk("KD_G19_FIXTURE env var must point at the arcus mint fixture")

    fixture = path |> File.read!() |> Jason.decode!()

    headers = %{"x-ms-date" => fixture["date"]}
    key_bytes = Base.decode64!(fixture["key"])

    lowercase_sts =
      "get\n#{@resource_type}\n#{@resource_link}\n#{String.downcase(fixture["date"])}\n\n"

    lowercase_sig =
      :crypto.mac(:hmac, :sha256, key_bytes, lowercase_sts)
      |> Base.encode64()

    refute Auth.valid_master_sig?(
             :get,
             @resource_type,
             @resource_link,
             headers,
             lowercase_sig,
             key_bytes
           )
  end
end
