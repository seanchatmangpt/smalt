# X8 — Chicago-school live leg over the REAL smalt substrate (ARM control
# plane 9443, Microsoft.Network/privateDnsZones family, KD-29 witnessed
# face). No mocks: run/0 walks the real ARM face — STS mint, RG PUT, private
# zone PUT (run-unique), virtualNetworkLinks PUT/GET (KD-29), A-recordset
# probe, zone DELETE + 404 re-GET — all over real :httpc. A down substrate
# surfaces as a loud SKIP naming the step, never a fake pass.
#
# Witnessed (live probe 2026-10-20): the A-recordset route under
# privateDnsZones is ABSENT (404 RouteNotFound) — run/0 returns the typed
# loud dns=UNSUPPORTED(recordset-A:...) refusal while zone CRUD + deletion
# prove the rest of the face live.
#
# Context: solo (live substrate leg, host-side :httpc).

defmodule PopcornDemo.LiveDnsTest do
  use ExUnit.Case, async: false

  alias PopcornDemo.LiveDns

  describe "run/0 full walk over live substrate" do
    test "walks zone CRUD + vNetLink and answers the record face loudly" do
      result = LiveDns.run()

      # Either the top-level walk passes or the absent record face is
      # loudly UNSUPPORTED — never a fake pass, never a silent skip.
      assert match?({:ok, "dns=OK(" <> _}, result) or
               match?({:error, "dns=UNSUPPORTED(recordset-A:" <> _}, result),
             "unexpected walk result: #{inspect(result)}"
    end

    test "run/0 is repeatable (re-create after delete, run-unique zones)" do
      r1 = LiveDns.run()
      r2 = LiveDns.run()

      for r <- [r1, r2] do
        assert match?({:ok, _}, r) or
                 match?({:error, "dns=UNSUPPORTED(" <> _}, r),
               "non-repeatable walk: #{inspect(r)}"
      end
    end
  end

  describe "real wire state" do
    test "private zone PUT 200/201, GET echo, DELETE, 404 re-GET (zone CRUD is live)" do
      zone = "dns-x8-crud-#{System.system_time(:second)}"

      assert :ok = LiveDns.put_zone_seam(zone)

      assert {:ok, %{status: 200, body: %{"name" => ^zone, "type" => type}}} =
               LiveDns.get_zone_seam(zone)

      assert type == LiveDns.zone_type()

      assert {:ok, %{status: s}} = LiveDns.delete_zone_seam(zone)
      assert s in [200, 204]

      assert {:ok, %{status: 404}} = LiveDns.get_zone_seam(zone)
    end

    test "tokenless GET is refused 401 with a WWW-Authenticate challenge" do
      assert {:ok, %{status: 401, headers: headers}} = LiveDns.fetch_tokenless()

      assert {"www-authenticate", challenge} =
               Enum.find(headers, fn {k, _} -> k == "www-authenticate" end),
             "no www-authenticate header in #{inspect(headers)}"

      assert challenge =~ "Bearer"
    end

    test "A record set under a private zone is loudly absent (RouteNotFound)" do
      zone = "dns-x8-absent-#{System.system_time(:second)}"
      assert :ok = LiveDns.put_zone_seam(zone)

      assert {:route_absent, 404, "RouteNotFound"} = LiveDns.probe_recordset_seam(zone)

      assert {:ok, %{status: s}} = LiveDns.delete_zone_seam(zone)
      assert s in [200, 204]
    end
  end
end
