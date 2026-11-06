# KD-A1 court (v26.11.6, lane R-KDRES): CAA record sets on the ARM DNS face.
# Parity raise — smalt arm/dns.ex previously refused CAA on PUT while arcus
# tenancy_dns.go RecordSetTypes admits it and smalt's own Ash registry maps
# Microsoft.Network/dnsZones/CAA to Smalt.Network.CAA. Chicago-style: real
# ETS store via the real module, assert final state.
defmodule Integration.ArmDnsCaaCourtTest do
  use ExUnit.Case, async: false

  alias Smalt.Arm.Dns

  @zone "kdres-caa.example.com"

  setup do
    Dns.ensure_table()

    on_exit(fn ->
      Dns.delete_zone("s-kdres", "rg-kdres", @zone)
    end)

    :ok
  end

  test "KD-A1: CAA record set PUT is admitted (201), GET returns the records, delete 404s after" do
    # zone may pre-exist (shared ETS across the module's tests) — 200 or 201 both lawful
    assert {:ok, st, _zone} = Dns.put_zone("s-kdres", "rg-kdres", @zone, %{})
    assert st in [200, 201]

    body = %{
      "properties" => %{
        "TTL" => 3600,
        "records" => [
          %{"flags" => 0, "tag" => "issue", "value" => "letsencrypt.org"}
        ]
      }
    }

    assert {:ok, 201, rec} = Dns.put_recordset("s-kdres", "rg-kdres", @zone, "CAA", "@", body)
    assert rec["type"] == "Microsoft.Network/dnsZones/CAA"
    assert rec["properties"]["fqdn"] == "@.#{String.downcase(@zone)}."

    assert {:ok, rec2} = Dns.get_recordset("s-kdres", "rg-kdres", @zone, "CAA", "@")
    assert [%{"tag" => "issue", "value" => "letsencrypt.org"}] = rec2["properties"]["records"]

    assert {:ok, 200, _upd} = Dns.put_recordset("s-kdres", "rg-kdres", @zone, "caa", "@", body)

    assert {:ok, :deleted} = Dns.delete_recordset("s-kdres", "rg-kdres", @zone, "CAA", "@")
    assert {:error, 404, _} = Dns.get_recordset("s-kdres", "rg-kdres", @zone, "CAA", "@")
  end

  test "KD-A1: CAA appears in the supported closed set; unsupported type still refused" do
    assert {:ok, 201, _} = Dns.put_zone("s-kdres", "rg-kdres", @zone, %{})

    props = %{"properties" => %{"TTL" => 60, "records" => [%{"x" => "y"}]}}

    # CAA no longer hits the unsupported-type arm.
    assert {:ok, 201, _} = Dns.put_recordset("s-kdres", "rg-kdres", @zone, "CAA", "lb", props)

    # the unsupported-type arm still fires for a genuinely unknown type.
    assert {:error, 400, %{code: "InvalidParameter", message: msg}} =
             Dns.put_recordset("s-kdres", "rg-kdres", @zone, "BOGUS", "x", props)

    assert msg =~ "unsupported record type"
  end
end
