defmodule Smalt.Arm.Dns do
  @moduledoc """
  Azure DNS control-plane face (wave-6 lane w6y, v26.10.20).
  Verb bodies for /providers/Microsoft.Network/dnsZones surface; router
  gates api-version and delegates here. Storage: shadow ETS tables
  :smalt_arm_dns / :smalt_arm_dns_records, lazily created with 3-tuple
  :heir to init (silent-disarm class, v26.10.19).
  """

  @table :smalt_arm_dns
  @rec_table :smalt_arm_dns_records
  @recordset_types ~w(A AAAA CNAME MX TXT SRV PTR)
  @seed_types ~w(SOA NS)

  @spec ensure_table() :: :ok
  def ensure_table do
    ensure_one(@table)
    ensure_one(@rec_table)
    :ok
  end

  defp ensure_one(table) do
    case :ets.info(table) do
      :undefined ->
        :ets.new(table, [:named_table, :set, :public, {:read_concurrency, true}, {:heir, Process.whereis(:init), []}])
        :ok

      _ -> :ok
    end
  end

  # --- zones ----------------------------------------------------------------

  def put_zone(sub, rg, zone, _body) do
    ensure_table()

    if String.contains?(zone, ".") do
      now = DateTime.utc_now() |> DateTime.to_iso8601()
      key = zone_key(zone)

      record =
        zone_envelope(sub, rg, zone, etag(), now)
        |> put_in(["properties", "maxNumberOfRecordSets"], 10000)

      case :ets.lookup(@table, key) do
        [] ->
          true = :ets.insert(@table, {key, record})
          seed(zone)
          {:ok, 201, record}

        [{_, prior}] ->
          record = put_in(record, ["etag"], prior["etag"])
          true = :ets.insert(@table, {key, record})
          {:ok, 200, record}
      end
    else
      {:error, 400, %{code: "InvalidParameter", message: "zone name must be an FQDN (contain at least one dot)"}}
    end
  end

  def get_zone(_sub, _rg, zone) do
    ensure_table()

    case :ets.lookup(@table, zone_key(zone)) do
      [{_, rec}] -> {:ok, rec}
      [] -> {:error, 404, nf("zone", zone)}
    end
  end

  def list_zones(_sub, rg) do
    ensure_table()

    items =
      :ets.tab2list(@table)
      |> Enum.filter(fn {{:dns_zone, _}, rec} -> rec["id"] =~ "/resourceGroups/#{rg}/" end)
      |> Enum.map(fn {_, rec} -> rec end)
      |> Enum.sort_by(& &1["name"])
      |> Enum.take(100)

    {:ok, items}
  end

  def delete_zone(_sub, _rg, zone) do
    ensure_table()
    key = zone_key(zone)

    case :ets.lookup(@table, key) do
      [] ->
        {:error, 404, nf("zone", zone)}

      [{_, _}] ->
        leftovers =
          :ets.tab2list(@rec_table)
          |> Enum.filter(fn
            {{:dns_rec, z, t, _n}, _} -> z == String.downcase(zone) and t not in @seed_types
            _ -> false
          end)

        case leftovers do
          [] ->
            for {{:dns_rec, z, t, n}, _} <- :ets.tab2list(@rec_table), z == String.downcase(zone) do
              true = :ets.delete(@rec_table, {:dns_rec, z, t, n})
            end

            true = :ets.delete(@table, zone_key(zone))
            {:ok, :deleted}

          _ ->
            {:error, 409, %{code: "ZoneHasRecordSets", message: "Zone #{zone} still contains record sets; delete record sets first"}}
        end
    end
  end

  # --- record sets -----------------------------------------------------------

  def put_recordset(sub, rg, zone, rtype, rname, body) do
    ensure_table()
    up = String.upcase(rtype)

    cond do
      up == "CAA" ->
        {:error, 400, %{code: "InvalidParameter", message: "CAA records are not supported"}}

      up in @seed_types and (rname == "@" or rname == zone <> ".") ->
        {:error, 400, %{code: "InvalidParameter", message: "SOA/NS at zone apex is auto-seeded and not editable"}}

      up not in @recordset_types ->
        {:error, 400, %{code: "InvalidParameter", message: "unsupported record type #{rtype}"}}

      true ->
        do_put_recordset(sub, rg, zone, up, rname, body)
    end
  end

  defp do_put_recordset(sub, rg, zone, up, rname, body) do
    zone_ex? =
      case :ets.lookup(@table, zone_key(zone)) do
        [{_, _}] -> true
        [] -> false
      end

    unless zone_ex? do
      {:error, 404, nf("zone", zone)}
    else
      props = body["properties"] || %{}
      records =
        props["records"] || props["ARecords"] || props["MXRecords"] ||
          props["CNAMERecord"] || props["NSRecords"] || props["TXTRecords"] ||
          props["SRVRecords"] || props["PTRRecords"] || props["AAAARecords"] || []

      unless is_list(records) and records != [] do
        {:error, 400, %{code: "InvalidARecords", message: "properties.records must be a non-empty list"}}
      else
        rec =
          %{
            "id" => "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/Microsoft.Network/dnsZones/#{zone}/#{up}/#{rname}",
            "name" => rname,
            "type" => "Microsoft.Network/dnsZones/#{up}",
            "resourceGroup" => rg,
            "etag" => "00000000-0000-0000-0000-000000000000",
            "properties" => %{
              "fqdn" => "#{rname}.#{zone}.",
              "records" => records,
              "TTL" => props["TTL"] || 3600
            }
          }

        key = rec_key(zone, up, rname)
        existed = match?([{_, _}], :ets.lookup(@rec_table, key))
        true = :ets.insert(@rec_table, {key, rec})
        if existed, do: {:ok, 200, rec}, else: {:ok, 201, rec}
      end
    end
  end

  def get_recordset(_sub, _rg, zone, rtype, rname) do
    ensure_table()

    case :ets.lookup(@rec_table, rec_key(zone, rtype, rname)) do
      [{_, rec}] -> {:ok, rec}
      [] -> {:error, 404, nf("record set", "#{rtype}/#{rname}")}
    end
  end

  def delete_recordset(_sub, _rg, zone, rtype, rname) do
    ensure_table()

    case :ets.lookup(@rec_table, rec_key(zone, rtype, rname)) do
      [{_, _}] ->
        true = :ets.delete(@rec_table, rec_key(zone, rtype, rname))
        {:ok, :deleted}

      [] ->
        {:error, 404, nf("record set", "#{rtype}/#{rname}")}
    end
  end

  def list_recordsets(_sub, _rg, zone, top) do
    ensure_table()
    z = String.downcase(zone)

    items =
      :ets.tab2list(@rec_table)
      |> Enum.filter(fn {{:dns_rec, zz, _t, _n}, _} -> zz == z end)
      |> Enum.map(fn {_, rec} -> rec end)
      |> Enum.sort_by(& &1["id"])
      |> Enum.take(top)

    {:ok, items}
  end

  # --- helpers ---------------------------------------------------------------

  defp nf(what, name), do: {404, %{code: "NotFound", message: "#{what} #{name} was not found"}}

  defp zone_key(name), do: {:dns_zone, String.downcase(name)}

  defp rec_key(zone, rtype, rname), do: {:dns_rec, String.downcase(zone), String.upcase(rtype), String.downcase(rname)}

  defp etag do
    "\"" <> Integer.to_string(:erlang.phash2({:dns, System.system_time()})) <> "\""
  end

  defp zone_envelope(sub, rg, zone, et, now) do
    %{
      "id" => "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/Microsoft.Network/dnsZones/#{zone}",
      "type" => "Microsoft.Network/dnsZones",
      "location" => "global",
      "etag" => et,
      "properties" => %{
        "zoneType" => "Public",
        "numberOfRecordSets" => rec_count(zone),
        "maxNumberOfRecordSets" => 10000,
        "nameServers" => ["ns1-01.azure-dns.com.", "ns1-02.azure-dns.com.", "ns1-03.azure-dns.com.", "ns1-04.azure-dns.com."]
      },
      "systemData" => %{"createdByType" => "Application", "createdAt" => now}
    }
  end

  defp rec_count(zone) do
    :ets.tab2list(@rec_table)
    |> Enum.count(fn {{:dns_rec, z, _t, _n}, _} -> z == String.downcase(zone) end)
  end

  defp seed(zone) do
    z = String.downcase(zone)
    now = DateTime.utc_now() |>
 DateTime.to_iso8601()

    soa = %{
      "id" => "/seed/soa",
      "name" => "@",
      "type" => "Microsoft.Network/dnsZones/SOA",
      "etag" => etag(),
      "properties" => %{
        "fqdn" => "#{zone}.",
        "SOARecord" => %{"host" => "azuredns-hostmaster.", "mname" => "azuredns-hostmaster.", "refreshTime" => 3600, "retryTime" => 300, "expireTime" => 2419200, "minimumTTL" => 1, "serialNumber" => now},
        "TTL" => 3600
      }
    }

    ns = %{
      "id" => "/seed/ns",
      "name" => "@",
      "type" => "Microsoft.Network/dnsZones/NS",
      "etag" => etag(),
      "properties" => %{
        "fqdn" => "#{zone}.",
        "NSRecords" => [%{"nsdname" => "ns1-01.azure-dns.com."}],
        "TTL" => 3600
      }
    }

    true = :ets.insert(@rec_table, {{:dns_rec, z, "SOA", "@"}, soa})
    true = :ets.insert(@rec_table, {{:dns_rec, z, "NS", "@"}, ns})
    :ok
  end
end
