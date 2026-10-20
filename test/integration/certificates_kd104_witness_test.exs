defmodule Smalt.Test.Internal.CertificatesKd104WitnessTest do
  @moduledoc """
  KD-104 witness: module-level create→get roundtrip on the real
  `Smalt.DataPlane.Certificates` (no mocks). Subject CN and validity are
  read back through `:public_key.der_decode/2` off the stored DER, and the
  PEM export is decoded back via `:public_key.pem_decode/1`.
  """

  use ExUnit.Case, async: false

  alias Smalt.DataPlane.Certificates

  test "create→get roundtrip honors subject CN + validity; PEM exports; delete→purge typed" do
    name = "witness-kd104-#{System.system_time(:millisecond)}"

    {:ok, 201, created} =
      Certificates.create(name, "localhost", %{
        "policy" => %{
          "x509_props" => %{"subject" => "CN=witness.smalt.local", "validity_months" => 6}
        }
      })

    assert created["name"] == name
    assert created["id"] == "https://localhost:8443/certificates/#{name}"
    {:ok, 200, fetched} = Certificates.get(name)
    assert created == fetched

    # Chicago: decode the real ASN.1, assert on the certificate itself.
    {:ok, der} = Base.decode64(fetched["cer"])
    cert = :public_key.der_decode(:OTPCertificate, der)
    tbs = elem(cert, 1)

    cn =
      case elem(tbs, 6) do
        {:"Name", {:rdnSequence, rdns}} ->
          cn_from_rdns(rdns)

        {:rdnSequence, rdns} ->
          cn_from_rdns(rdns)
      end

    assert cn == "witness.smalt.local"

    {:Validity, nbf, na} = elem(tbs, 5)
    nbf_s = asn1_time_to_unix(nbf)
    na_s = asn1_time_to_unix(na)
    now = System.system_time(:second)
    assert abs(nbf_s - now) <= 5
    # 6 policy months → 182 days
    assert div(na_s - nbf_s, 86_400) in 180..183

    # PEM export roundtrips to the same DER
    assert {:ok, pem} = Certificates.pem(name)
    assert pem |> String.split("\n") |> hd() == "-----BEGIN CERTIFICATE-----"

    assert [{:Certificate, pem_der, :not_encrypted}] = :public_key.pem_decode(pem)
    assert pem_der == der

    # list contains the row before deletion
    {:ok, 200, %{"value" => items}} = Certificates.list()
    assert Enum.any?(items, &(&1["name"] == name))

    # delete → typed 404s; purge idempotent-by-404
    assert {:ok, 200, deleted} = Certificates.delete(name)
    assert is_integer(deleted["deletedDate"])
    assert {:error, 404, e1} = Certificates.get(name)
    assert get_in(e1, ["error", "code"]) == "CertificateNotFound"
    assert {:error, 404, e2} = Certificates.purge(name)
    assert get_in(e2, ["error", "code"]) == "CertificateNotFound"
  end

  test "duplicate create is refused atomically while first row survives intact" do
    name = "witness-kd104-dup-#{System.system_time(:millisecond)}"

    {:ok, 201, first} = Certificates.create(name, "localhost", %{})

    assert {:error, 409, _} = Certificates.create(name, "localhost", %{})
    {:ok, 200, after_dup} = Certificates.get(name)
    assert after_dup == first
  end

  defp cn_from_rdns(rdns) do
    rdns
    |> List.flatten()
    |> Enum.find_value(fn {_, {2, 5, 4, 3}, {_, v}} -> to_string(v) end)
  end

  defp asn1_time_to_unix({:utcTime, t}), do: base(t)
  defp asn1_time_to_unix({:generalizedTime, t}), do: base(t)

  defp base(t) do
    s = to_string(t)
    len = String.length(s)

    {year, rest} =
      if len == 13 do
        {y0, r} = String.split_at(s, 2)
        yy = String.to_integer(y0)
        {if(yy >= 50, do: 1900 + yy, else: 2000 + yy), r}
      else
        {y0, r} = String.split_at(s, 4)
        {String.to_integer(y0), r}
      end

    <<mo::binary-size(2)>> <> <<d::binary-size(2)>> <> <<h::binary-size(2)>> <>
      <<mi::binary-size(2)>> <> <<ss::binary-size(2)>> <> _ = rest

    :calendar.datetime_to_gregorian_seconds(
      {{year, String.to_integer(mo), String.to_integer(d)},
       {String.to_integer(h), String.to_integer(mi), String.to_integer(ss)}}
    ) - 62_167_219_200
  end
end
