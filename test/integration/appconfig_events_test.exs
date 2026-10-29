# Integration-tier witness (egress router dispatch, integration tier):
# T-04 — App Configuration Key Vault reference content-type contract +
# kv-plane Event Grid change notifications (AppConfigurationKeyValueModified
# / …Deleted on topic "appconfig").
#
# Chicago discipline: real Store rows (:smalt_appconfig, tuple-keyed
# {key, label}), real egress dispatch (Plug.Router.call in-process, auth
# :anonymous in the test env — a non-tokenless Authorization header satisfies
# the /kv challenge guard, KD-15/53), real Event Grid engine (lazy-started,
# in-process subscription + assert_received). No mocks. The keyvaultref
# reference body round-trips BYTE-IDENTICALLY and is never resolved
# server-side (resolution stays client-side, per the real Azure posture).
#
#   PUT keyvaultref (create) -> 201 -> GET -> 200 same uri string + content
#     type -> LIST contains the reference item unmodified
#   PUT (create)      -> Modified event with key/label/etag of the record
#   PUT (If-Match)    -> second Modified event, NEW etag, fresh event id
#   DELETE (If-Match) -> Deleted event carrying the deleted record's etag
#   labeled kv        -> "key|label" subject + label in event data
#
# Context: solo (integration tier, in-process dispatch). NOT executed in the
# r7 lane (compile-freeze SLA) — stamped CODE-COMPLETE pending integration.

defmodule Smalt.Internal.AppconfigEventsTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.Messaging.EventGrid
  alias Smalt.Store

  @kv_ref_content_type "application/vnd.microsoft.appconfig.keyvaultref+json"
  @ref_uri "https://t04-vault.vault.azure.net/secrets/orders-readonly"
  @ref_value "{\"uri\":\"#{@ref_uri}\"}"
  @eg_topic "appconfig"

  setup do
    # Fresh topic state per test: drops stale subscriptions (a dead test
    # process pid from a previous test would otherwise stay subscribed).
    EventGrid.reset(@eg_topic)

    on_exit(fn ->
      Store.delete(:smalt_appconfig, {"orders-uri", ""})
      Store.delete(:smalt_appconfig, {"orders-language", ""})
      Store.delete(:smalt_appconfig, {"orders-uri-labeled", "prod"})
    end)

    :ok
  end

  defp kv_req(method, path, body \\ nil, headers \\ []) do
    conn =
      if body do
        conn(method, path, Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
      else
        conn(method, path)
      end

    conn =
      conn
      # Non-tokenless: the /kv challenge guard 401s tokenless requests even
      # in anonymous auth mode; in the test env any bearer value rides.
      |> Plug.Conn.put_req_header("authorization", "Bearer smalt-t04-court")
      |> then(fn c ->
        Enum.reduce(headers, c, fn {k, v}, acc -> Plug.Conn.put_req_header(acc, k, v) end)
      end)

    Smalt.EgressRouter.call(Plug.Conn.fetch_query_params(conn), [])
  end

  # -- T-04 scope 1: keyvaultref round-trip (no server-side resolution) ---------

  test "keyvaultref value + content type round-trip byte-identically through PUT/GET/list" do
    put_conn =
      kv_req(
        :put,
        "/kv/orders-uri",
        %{"value" => @ref_value, "contentType" => @kv_ref_content_type},
        [{"if-none-match", "*"}]
      )

    assert put_conn.status == 201

    put_body = Jason.decode!(put_conn.resp_body)
    assert put_body["key"] == "orders-uri"
    assert put_body["value"] == @ref_value
    assert put_body["contentType"] == @kv_ref_content_type
    assert is_binary(put_body["etag"])

    # GET serves the exact reference string back — the service never resolves
    # the uri server-side (opaque passthrough, real Azure parity).
    get_conn = kv_req(:get, "/kv/orders-uri")
    assert get_conn.status == 200

    get_body = Jason.decode!(get_conn.resp_body)
    assert get_body["value"] == @ref_value
    assert get_body["contentType"] == @kv_ref_content_type
    assert get_body["etag"] == put_body["etag"]

    list_conn = kv_req(:get, "/kv?key=orders-uri")
    assert list_conn.status == 200

    %{"items" => items} = Jason.decode!(list_conn.resp_body)
    item = Enum.find(items, &(&1["key"] == "orders-uri"))
    assert item["value"] == @ref_value
    assert item["contentType"] == @kv_ref_content_type
  end

  # -- T-04 scope 2: change notifications on the "appconfig" Event Grid topic --

  test "kv PUT create + If-Match modify publish Modified events with the record etags" do
    sub = :t04_events
    EventGrid.subscribe(@eg_topic, sub, self())

    put_conn =
      kv_req(:put, "/kv/orders-language", %{"value" => "rust", "contentType" => "text/plain"}, [
        {"if-none-match", "*"}
      ])

    assert put_conn.status == 201
    created = Jason.decode!(put_conn.resp_body)

    assert_received {:event_grid, @eg_topic, ^sub, _id, created_event}
    assert created_event[:eventType] == "AppConfigurationKeyValueModified"
    assert created_event[:subject] == "orders-language"
    assert created_event[:data][:key] == "orders-language"
    assert created_event[:data][:label] == ""
    assert created_event[:data][:etag] == created["etag"]
    assert is_binary(created_event[:id]) and created_event[:id] != ""
    assert is_binary(created_event[:eventTime])

    # Modify (If-Match CAS): a second Modified event with the NEW etag and a
    # fresh dedup id (the engine never folds distinct events by id).
    mod_conn =
      kv_req(:put, "/kv/orders-language", %{"value" => "elixir", "contentType" => "text/plain"}, [
        {"if-match", created["etag"]}
      ])

    assert mod_conn.status == 200
    modified = Jason.decode!(mod_conn.resp_body)
    assert modified["etag"] != created["etag"]

    assert_received {:event_grid, @eg_topic, ^sub, _id, modified_event}
    assert modified_event[:eventType] == "AppConfigurationKeyValueModified"
    assert modified_event[:data][:key] == "orders-language"
    assert modified_event[:data][:etag] == modified["etag"]
    assert modified_event[:id] != created_event[:id]
  end

  test "kv DELETE (If-Match) publishes Deleted with the deleted record's etag" do
    sub = :t04_deleted
    EventGrid.subscribe(@eg_topic, sub, self())

    put_conn =
      kv_req(:put, "/kv/orders-language", %{"value" => "rust", "contentType" => "text/plain"}, [
        {"if-none-match", "*"}
      ])

    assert put_conn.status == 201
    created = Jason.decode!(put_conn.resp_body)

    # Drain the create's Modified event so the mailbox holds only the delete's.
    assert_received {:event_grid, @eg_topic, ^sub, _id, _}

    del_conn = kv_req(:delete, "/kv/orders-language", nil, [{"if-match", created["etag"]}])
    assert del_conn.status == 204

    assert_received {:event_grid, @eg_topic, ^sub, _id, deleted_event}
    assert deleted_event[:eventType] == "AppConfigurationKeyValueDeleted"
    assert deleted_event[:subject] == "orders-language"
    assert deleted_event[:data][:key] == "orders-language"
    assert deleted_event[:data][:label] == ""
    assert deleted_event[:data][:etag] == created["etag"]

    # Post-delete GET: the kv is gone (404 KvNotFound), and nothing else was
    # published (no mailbox residue beyond the Deleted event).
    assert kv_req(:get, "/kv/orders-language").status == 404
    refute_received {:event_grid, @eg_topic, ^sub, _id, _}
  end

  test "labeled kv events carry the key|label subject suffix and the label in data" do
    sub = :t04_labeled
    EventGrid.subscribe(@eg_topic, sub, self())

    put_conn =
      kv_req(
        :put,
        "/kv/orders-uri-labeled?label=prod",
        %{"value" => @ref_value, "contentType" => @kv_ref_content_type},
        [{"if-none-match", "*"}]
      )

    assert put_conn.status == 201
    labeled = Jason.decode!(put_conn.resp_body)
    assert labeled["label"] == "prod"

    assert_received {:event_grid, @eg_topic, ^sub, _id, event}
    assert event[:eventType] == "AppConfigurationKeyValueModified"
    assert event[:subject] == "orders-uri-labeled|prod"
    assert event[:data][:key] == "orders-uri-labeled"
    assert event[:data][:label] == "prod"
    assert event[:data][:etag] == labeled["etag"]
  end
end
