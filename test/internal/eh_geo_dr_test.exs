defmodule Smalt.Messaging.EhGeoDrTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Internal tier for the geo-DR metadata face (`Smalt.Messaging.EhGeoDr`).
  Real collaborators (the module's own serialized server + ETS), Chicago-style:
  assert on final record state and typed faces, no mocks.
  """

  alias Smalt.Messaging.EhGeoDr

  @primary "/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.EventHub/namespaces/ns-primary"
  @partner "/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.EventHub/namespaces/ns-partner"
  @alias "dr-alias-test"

  setup do
    EhGeoDr.ensure_table()
    on_exit(fn -> EhGeoDr.delete_alias(@alias) end)
    :ok
  end

  test "create, get, list returns the pairing record" do
    {:ok, rec} = EhGeoDr.create_or_update_alias(@alias, @primary, @partner)

    assert rec["alias"] == @alias
    assert rec["primary_namespace_id"] == @primary
    assert rec["partner_namespace_id"] == @partner
    assert rec["provisioning_state"] == "Succeeded"
    assert rec["last_commit_succeeded"] > 0

    assert {:ok, ^rec} = EhGeoDr.get_alias(@alias)
    assert Enum.any?(EhGeoDr.list_aliases(), &(&1["alias"] == @alias))
  end

  test "failover flips the primary designation" do
    {:ok, _} = EhGeoDr.create_or_update_alias(@alias, @primary, @partner)
    {:ok, rec} = EhGeoDr.failover(@alias)

    assert rec["primary_namespace_id"] == @partner
    assert rec["partner_namespace_id"] == @primary
    assert rec["role_by_ns"][@primary] == :secondary
    assert rec["role_by_ns"][@partner] == :primary
    assert rec["provisioning_state"] == "FailedOver"
  end

  test "failover on unpaired/missing alias is typed-refused" do
    {:error, missing} = EhGeoDr.failover("no-such-alias")
    assert missing.status == 404
    assert missing.code == "AliasNotFound"

    {:ok, _} = EhGeoDr.create_or_update_alias(@alias, @primary, @partner)
    {:ok, _} = EhGeoDr.failover(@alias)
    # second failover: pairing no longer intact
    {:error, unpaired} = EhGeoDr.failover(@alias)
    assert unpaired.status == 409
    assert unpaired.code == "AliasNotPaired"
  end

  test "break-pairing post-failover is typed-refused; pre-failover it succeeds" do
    {:ok, _} = EhGeoDr.create_or_update_alias(@alias, @primary, @partner)

    # paired: break succeeds
    assert {:ok, broken} = EhGeoDr.break_pairing(@alias)
    assert broken["provisioning_state"] == "Broken"

    # broken: failover and break both refuse
    {:error, f} = EhGeoDr.failover(@alias)
    assert f.code == "AliasNotPaired"

    # fresh pairing, failover, then break must be refused
    {:ok, _} = EhGeoDr.create_or_update_alias(@alias, @primary, @partner)
    {:ok, _} = EhGeoDr.failover(@alias)

    {:error, refused} = EhGeoDr.break_pairing(@alias)
    assert refused.status == 409
    assert refused.code == "PairingAlreadyFailedOver"
  end

  test "delete_alias removes the record from any state" do
    {:ok, _} = EhGeoDr.create_or_update_alias(@alias, @primary, @partner)
    assert :ok = EhGeoDr.delete_alias(@alias)
    assert {:error, %{code: "AliasNotFound"}} = EhGeoDr.get_alias(@alias)
  end
end
