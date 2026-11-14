defmodule Smalt.Twilio.Core do
  @moduledoc """
  Pure core: TypeID + fnox route law, Twilio sid minting, resource shapes.
  Event vocabulary is OCEL 2.0 shaped; domain classes are FIBO.
  """

  @crockford ~c"0123456789abcdefghjkmnpqrstvwxyz"
  @roles ~w(principal revops vendor client distributor credit)
  @surfaces ~w(app api)

  @lead %{
    "principal" => {"deal", "MasterAgreement"},
    "revops" => {"wo", "ServiceAgreement"},
    "vendor" => {"off", "Offering"},
    "client" => {"po", "Contract"},
    "distributor" => {"bom", "ContractualCommitment"},
    "credit" => {"pool", "PoolBackedSecurity"}
  }

  # Non-lead otypes: allowed roles (assumption recorded in docs/twilio-parity/TS1.md).
  @shared %{
    "ent" => @roles,
    "qa" => ~w(principal revops vendor client),
    "stl" => ~w(principal revops client credit),
    "inv" => ~w(principal revops vendor client)
  }

  def roles, do: @roles

  def fibo_class(otype) do
    case Enum.find(@lead, fn {_, {o, _}} -> o == otype end) do
      {_, {_, c}} -> c
      nil -> %{"ent" => "LegalPerson", "qa" => "AssessmentEvent", "stl" => "Settlement", "inv" => "PaymentObligation"}[otype]
    end
  end

  def allowed_roles(otype) do
    case Enum.find(@lead, fn {_, {o, _}} -> o == otype end) do
      {role, _} -> [role]
      nil -> Map.get(@shared, otype, [])
    end
  end

  def new_ulid do
    ts = System.system_time(:millisecond)
    <<n::128>> = <<ts::48, :crypto.strong_rand_bytes(10)::binary>>
    encode128(n)
  end

  defp encode128(n) do
    # 26 chars * 5 bits = 130 bits; top 2 bits zero so first char is 0-7.
    for i <- 25..0//-1, into: "" do
      <<Enum.at(@crockford, Bitwise.band(Bitwise.bsr(n, i * 5), 31))>>
    end
  end

  def type_id(prefix), do: prefix <> "_" <> new_ulid()

  @spec parse_typeid(String.t()) :: {:ok, {String.t(), String.t()}} | {:error, atom()}
  def parse_typeid(s) do
    case String.split(s, "_") do
      [prefix, ulid] ->
        cond do
          not Regex.match?(~r/^[a-z]+$/, prefix) -> {:error, :bad_prefix}
          not Regex.match?(~r/^[0-7][0-9a-hjkmnp-tv-z]{25}$/, ulid) -> {:error, :bad_ulid}
          true -> {:ok, {prefix, ulid}}
        end

      _ ->
        {:error, :malformed_typeid}
    end
  end

  @doc "Route law check for /{role}/{otype}_{ulid}/{surface}; runs before any state access."
  def check_route(role, oid, surface) do
    with true <- role in @roles || {:refused, :unknown_role},
         true <- surface in @surfaces || {:refused, :unknown_surface},
         {:ok, {otype, _}} <- wrap(parse_typeid(oid)),
         true <- allowed_roles(otype) != [] || {:refused, :unknown_otype},
         true <- role in allowed_roles(otype) || {:refused, :cross_role_traversal} do
      {:ok, %{role: role, otype: otype, id: oid, surface: surface, fibo: fibo_class(otype)}}
    else
      {:refused, why} -> {:refused, why}
      {:error, why} -> {:refused, why}
    end
  end

  defp wrap({:ok, _} = ok), do: ok
  defp wrap({:error, _} = e), do: e

  # --- Twilio sids -------------------------------------------------------

  def sid(prefix) when prefix in ~w(AC PN SM CA VA VE), do: prefix <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  def valid_account_sid?(s), do: Regex.match?(~r/^AC[0-9a-f]{32}$/, s)

  def incoming_number(account, params, now \\ DateTime.utc_now()) do
    s = sid("PN")

    %{
      "sid" => s,
      "account_sid" => account,
      "phone_number" => params["PhoneNumber"] || "+15005550006",
      "friendly_name" => params["FriendlyName"] || params["PhoneNumber"] || "",
      "sms_url" => params["SmsUrl"] || "",
      "voice_url" => params["VoiceUrl"] || "",
      "date_created" => DateTime.to_iso8601(now),
      "uri" => "/2010-04-01/Accounts/#{account}/IncomingPhoneNumbers/#{s}.json"
    }
  end

  def message(account, params, now \\ DateTime.utc_now()) do
    s = sid("SM")

    %{
      "sid" => s,
      "account_sid" => account,
      "to" => params["To"],
      "from" => params["From"],
      "body" => params["Body"] || "",
      "status" => "queued",
      "direction" => "outbound-api",
      "date_created" => DateTime.to_iso8601(now),
      "uri" => "/2010-04-01/Accounts/#{account}/Messages/#{s}.json"
    }
  end

  def call(account, params, now \\ DateTime.utc_now()) do
    s = sid("CA")

    %{
      "sid" => s,
      "account_sid" => account,
      "to" => params["To"],
      "from" => params["From"],
      "url" => params["Url"] || "",
      "status" => "queued",
      "direction" => "outbound-api",
      "date_created" => DateTime.to_iso8601(now),
      "uri" => "/2010-04-01/Accounts/#{account}/Calls/#{s}.json"
    }
  end

  def verification(service, params) do
    %{
      "sid" => sid("VE"),
      "service_sid" => service,
      "to" => params["To"],
      "channel" => params["Channel"] || "sms",
      "status" => "pending"
    }
  end

  def sim_swap_lookup(number) do
    %{
      "phone_number" => number,
      "valid" => true,
      "sim_swap" => %{"last_sim_swap" => %{"last_sim_swap_date" => nil, "swapped_period" => nil, "swapped_in_period" => false}}
    }
  end

  @doc "OCEL 2.0 event record for an emulator action."
  def ocel_event(activity, objects, now \\ DateTime.utc_now()) do
    %{
      "ocel:id" => "e_" <> new_ulid(),
      "ocel:type" => activity,
      "ocel:time" => DateTime.to_iso8601(now),
      "ocel:relationships" => Enum.map(objects, fn o -> %{"ocel:objectId" => o, "ocel:qualifier" => "involves"} end)
    }
  end
end
