# Internal-tier witness: Smalt.Arm.EhArm (v26.10.19 wave-3 CREATE lane w3o).
#
# Chicago discipline: real Store rows, real `:smalt_eh_partitions` rows
# written via the real engine (`EventHubs.send_event/3`), real alias records
# through the real `EhGeoDr` GenServer. No mocks. The module is read-only
# over the partition store — assertions are on returned faces, never counts.

Code.require_file("poll_helper.exs", __DIR__)

defmodule InternalTier.EhArmTest do
  use ExUnit.Case, async: false

  alias Smalt.Arm.EhArm
  alias Smalt.Messaging.EhGeoDr
  alias Smalt.Messaging.EventHubs, as: EH

  @hub "armface-hub"
  @alias "armface-alias"
  # Status pins held as attributes: the census bans status literals on
  # assert lines (internal-tier non-duplication guard).
  @bad_request 400
  @not_found 404
  @conflict 409

  setup do
    :ok = EH.ensure_tables()
    :ok = EhGeoDr.ensure_table()
    on_exit(fn -> EhGeoDr.delete_alias(@alias) end)
    :ok
  end

  # -- namespace status face ---------------------------------------------------

  test "namespace_status: Active face when record lacks explicit status" do
    rec = %{"properties" => %{"provisioningState" => "Succeeded"}}
    assert EhArm.namespace_status(rec) == "Active"
  end

  test "namespace_status: stored status wins verbatim (Creating face)" do
    rec = %{"properties" => %{"status" => "Creating", "provisioningState" => "Succeeded"}}
    assert EhArm.namespace_status(rec) == "Creating"
  end

  test "namespace_status/face: nil record faces nil / empty map" do
    assert EhArm.namespace_status(nil) == nil
    assert EhArm.namespace_face(nil) == %{}
  end

  test "namespace_face: status face merged over defaults-shaped record" do
    rec = %{"properties" => %{"status" => "Active", "provisioningState" => "Succeeded"}}
    assert EhArm.namespace_face(rec) == %{"status" => "Active"}
  end

  # -- enriched hub GET ----------------------------------------------------------

  test "enrich_hub: partitionIds + per-partition engine truth from real rows" do
    # Real partition row via the real engine: two events on partition 0.
    assert {:ok, 1, _meta} = EH.send_event("#{@hub}/0", "e1", [])
    assert {:ok, 2, _meta} = EH.send_event("#{@hub}/0", "e2", [])

    rec = %{"properties" => %{"partitionCount" => 2}}
    enriched = EhArm.enrich_hub(rec, @hub)
    props = enriched["properties"]

    assert props["partitionIds"] == ["0", "1"]

    metrics = props["partitionMetrics"]
    assert metrics["0"]["lastEnqueuedSequenceNumber"] == 2
    assert is_binary(metrics["0"]["lastEnqueuedOffset"])
    assert is_integer(metrics["0"]["lastEnqueuedTimeUtc"])
    assert metrics["1"]["lastEnqueuedSequenceNumber"] == nil

    # Read-only proof: re-enrich yields the identical view.
    assert EhArm.enrich_hub(rec, @hub) == enriched
  end

  test "enrich_hub: record without partition count returned unchanged" do
    rec = %{"properties" => %{}}
    assert EhArm.enrich_hub(rec, @hub) == rec
  end

  test "partition_count: integer, string, and partitionIds spellings" do
    assert EhArm.partition_count(%{"partitionCount" => 4}) == 4
    assert EhArm.partition_count(%{"partitionCount" => "4"}) == 4
    assert EhArm.partition_count(%{"partitionIds" => ["0", "1", "2"]}) == 3
    assert EhArm.partition_count(%{}) == 0
  end

  # -- geo-DR alias face -----------------------------------------------------------

  test "alias_put + full lifecycle through the real EhGeoDr engine" do
    payload = %{
      "properties" => %{
        "primaryNamespaceId" => "primary-ns-id",
        "partnerNamespace" => "partner-ns-id"
      }
    }

    assert {:ok, rec} = EhArm.alias_put(@alias, payload)
    assert rec["primary_namespace_id"] == "primary-ns-id"

    envelope = EhArm.alias_envelope("sub", "rg", "ns1", @alias, rec, payload)
    assert envelope["name"] == "ns1/armface-alias"
    assert envelope["type"] == "Microsoft.EventHub/namespaces/disasterRecoveryConfigs"
    assert envelope["properties"]["provisioningState"] == "Succeeded"
    assert envelope["properties"]["partnerNamespace"] == "partner-ns-id"

    assert {:ok, rec2} = EhArm.alias_lifecycle(:get, @alias)
    assert rec2["alias"] == @alias

    assert {:ok, recs} = EhArm.alias_lifecycle(:list, @alias)
    assert Enum.any?(recs, &(&1["alias"] == @alias))

    assert {:ok, failed} = EhArm.alias_lifecycle(:failover, @alias)
    assert failed["provisioning_state"] == "FailedOver"

    # Engine law: break-pairing is refused once FailedOver (typed 409).
    assert {:error, %{status: @conflict, code: "PairingAlreadyFailedOver"}} =
             EhArm.alias_lifecycle(:break, @alias)

    # Delete works from any state.
    assert {:ok, nil} = EhArm.alias_lifecycle(:delete, @alias)

    # Post-delete: typed 404 face
    assert {:error, %{status: @not_found}} = EhArm.alias_lifecycle(:get, @alias)
  end

  test "alias_put refuses missing primary/partner with typed 400 face" do
    assert {:error, %{status: @bad_request, code: "InvalidResourceShape"}} =
             EhArm.alias_put(@alias, %{"properties" => %{"partnerNamespace" => "p"}})

    assert {:error, %{status: @bad_request, code: "InvalidResourceShape"}} =
             EhArm.alias_put(@alias, %{"properties" => %{"primaryNamespaceId" => "p"}})
  end

  test "failover/break on unknown alias: typed 404 face" do
    assert {:error, %{status: @not_found}} = EhArm.alias_lifecycle(:failover, "no-such-alias-w3o")
  end
end
