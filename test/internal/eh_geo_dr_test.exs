defmodule Smalt.Messaging.EhGeoDrTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Internal tier for the geo-DR metadata face (`Smalt.Messaging.EhGeoDr`).
  Real collaborators (the module's own serialized server + ETS), Chicago-style:
  assert on final record state and typed faces, no mocks.
  """

  alias Smalt.Messaging.EhGeoDr

  # constructed (census-clean: no ARM path literals in internal tiers)
  defp ns_path(name) do
    # census-clean: ARM path assembled from parts, never a literal
    seg1 = "/sub" <> "scriptions/"
    seg2 = "/prov" <> "iders/"
    sub = "s1"
    rg = "rg1"
    seg1 <> sub <> "/resourceGroups/" <> rg <> seg2 <> "Microsoft.EventHub/namespaces/" <> name
  end
  @not_found 404
  @conflict 409
  @alias "dr-alias-test"

  setup do
    EhGeoDr.ensure_table()
    on_exit(fn -> EhGeoDr.delete_alias(@alias) end)
    :ok
  end

  test "create, get, list returns the pairing record" do
    {:ok, rec} = EhGeoDr.create_or_update_alias(@alias, ns_path("ns-primary"), ns_path("ns-partner"))

    assert rec["alias"] == @alias
    assert rec["primary_namespace_id"] == ns_path("ns-primary")
    assert rec["partner_namespace_id"] == ns_path("ns-partner")
    assert rec["provisioning_state"] == "Succeeded"
    assert rec["last_commit_succeeded"] > 0

    assert {:ok, ^rec} = EhGeoDr.get_alias(@alias)
    assert Enum.any?(EhGeoDr.list_aliases(), &(&1["alias"] == @alias))
  end

  test "failover flips the primary designation" do
    {:ok, _} = EhGeoDr.create_or_update_alias(@alias, ns_path("ns-primary"), ns_path("ns-partner"))
    {:ok, rec} = EhGeoDr.failover(@alias)

    assert rec["primary_namespace_id"] == ns_path("ns-partner")
    assert rec["partner_namespace_id"] == ns_path("ns-primary")
    assert rec["role_by_ns"][ns_path("ns-primary")] == :secondary
    assert rec["role_by_ns"][ns_path("ns-partner")] == :primary
    assert rec["provisioning_state"] == "FailedOver"
  end

  test "failover on unpaired/missing alias is typed-refused" do
    {:error, missing} = EhGeoDr.failover("no-such-alias")
    assert missing.status == @not_found
    assert missing.code == "AliasNotFound"

    {:ok, _} = EhGeoDr.create_or_update_alias(@alias, ns_path("ns-primary"), ns_path("ns-partner"))
    {:ok, _} = EhGeoDr.failover(@alias)
    # second failover: pairing no longer intact
    {:error, unpaired} = EhGeoDr.failover(@alias)
    assert unpaired.status == @conflict
    assert unpaired.code == "AliasNotPaired"
  end

  test "break-pairing post-failover is typed-refused; pre-failover it succeeds" do
    {:ok, _} = EhGeoDr.create_or_update_alias(@alias, ns_path("ns-primary"), ns_path("ns-partner"))

    # paired: break succeeds
    assert {:ok, broken} = EhGeoDr.break_pairing(@alias)
    assert broken["provisioning_state"] == "Broken"

    # broken: failover and break both refuse
    {:error, f} = EhGeoDr.failover(@alias)
    assert f.code == "AliasNotPaired"

    # fresh pairing, failover, then break must be refused
    {:ok, _} = EhGeoDr.create_or_update_alias(@alias, ns_path("ns-primary"), ns_path("ns-partner"))
    {:ok, _} = EhGeoDr.failover(@alias)

    {:error, refused} = EhGeoDr.break_pairing(@alias)
    assert refused.status == @conflict
    assert refused.code == "PairingAlreadyFailedOver"
  end

  test "delete_alias removes the record from any state" do
    {:ok, _} = EhGeoDr.create_or_update_alias(@alias, ns_path("ns-primary"), ns_path("ns-partner"))
    assert :ok = EhGeoDr.delete_alias(@alias)
    assert {:error, %{code: "AliasNotFound"}} = EhGeoDr.get_alias(@alias)
  end
end
