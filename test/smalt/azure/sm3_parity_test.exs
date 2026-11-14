defmodule Smalt.Azure.SM3ParityTest do
  use ExUnit.Case, async: false

  alias Smalt.Azure.{KvCertificates, LogAnalytics}
  alias Smalt.DataPlane.Certificates
  alias Smalt.Store

  defp uniq(p), do: p <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)

  test "policy get/update and attribute update on a real cert" do
    n = uniq("sm3c-")
    {:ok, 201, _} = Certificates.create(n, "localhost", %{})
    {:ok, 200, pol} = KvCertificates.get_policy(n)
    assert pol["x509_props"]["subject"] == "CN=smalt-cert"
    {:ok, 200, pol2} = KvCertificates.update_policy(n, %{"x509_props" => %{"subject" => "CN=x"}})
    assert pol2["x509_props"]["subject"] == "CN=x"
    {:ok, 200, rec} = KvCertificates.update_attributes(n, %{"attributes" => %{"enabled" => false}})
    assert rec["attributes"]["enabled"] == false
    {:ok, 200, %{"value" => [_]}} = KvCertificates.list_versions(n)
    assert {:error, 404, _} = KvCertificates.get_policy(uniq("missing-"))
  end

  test "import round-trips a minted DER, rejects dup and garbage" do
    n = uniq("sm3i-")
    {:ok, der} = Certificates.mint_certificate("CN=imp", "CN=imp", 1_700_000_000, 1_800_000_000)
    b64 = Base.encode64(der)
    {:ok, 201, rec} = KvCertificates.import(n, "localhost", %{"value" => b64})
    assert rec["attributes"]["nbf"] == 1_700_000_000
    assert rec["attributes"]["exp"] == 1_800_000_000
    assert {:error, 409, _} = KvCertificates.import(n, "localhost", %{"value" => b64})
    assert {:error, 400, _} = KvCertificates.import(uniq("bad-"), "localhost", %{"value" => "!!"})
    Store.delete(:smalt_vault_certificates, n)
  end

  test "log analytics ingest then table list/get" do
    dcr = uniq("dcr-sm3-")
    assert {:ok, 204, ""} = LogAnalytics.ingest(dcr, "S1", [%{"m" => 1}, %{"m" => 2}])
    {:ok, 200, %{"value" => [t]}} = LogAnalytics.list_tables(dcr)
    assert t["properties"]["rowCount"] == 2
    assert {:ok, 200, _} = LogAnalytics.get_table(dcr, "S1")
    assert {:error, 404, _} = LogAnalytics.get_table(dcr, "nope")

    on_exit(fn ->
      for k <- Store.prefix_keys(:smalt_sentinel_rows, dcr), do: Store.delete(:smalt_sentinel_rows, k)
      for k <- Store.prefix_keys(:smalt_sentinel_streams, dcr), do: Store.delete(:smalt_sentinel_streams, k)
    end)
  end
end
