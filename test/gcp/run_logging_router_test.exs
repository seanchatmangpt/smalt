defmodule Smalt.GCP.RunLoggingRouterTest do
  # SW4 Chicago court: real Plug.Test conns, real router, real engines/Store.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Smalt.GCP.{Functions, Logging, RunLoggingRouter}

  defp req(method, path, body \\ nil) do
    conn = conn(method, path, body && Jason.encode!(body)) |> put_req_header("content-type", "application/json")
    conn = Map.put(conn, :host, if(String.starts_with?(path, "/v2/entries"), do: "logging.googleapis.com", else: "run.googleapis.com"))
    out = RunLoggingRouter.route(conn)
    {out.status, Jason.decode!(out.resp_body)}
  end

  defp uniq, do: "sw4p#{System.unique_integer([:positive])}"

  test "non-matching paths return nil" do
    assert RunLoggingRouter.route(conn("GET", "/v1/projects/x/topics")) == nil
    assert RunLoggingRouter.route(conn("GET", "/v2/projects/x/locations/l/unknown")) == nil
    assert RunLoggingRouter.route(conn("GET", "/v2/entries:write")) == nil
  end

  test "service lifecycle, LRO polling, IAM over the wire" do
    p = uniq()
    base = "/v2/projects/#{p}/locations/us-central1"
    body = %{"template" => %{"containers" => [%{"image" => "gcr.io/x/a"}]}}

    assert {200, %{"done" => true, "name" => opname, "response" => svc}} =
             req("POST", "#{base}/services?serviceId=api", body)

    refute Map.has_key?(svc, "_iam")
    assert {200, %{"done" => true}} = req("GET", "#{base}/operations/#{Path.basename(opname)}")
    assert {409, %{"error" => %{"status" => "ALREADY_EXISTS"}}} = req("POST", "#{base}/services?serviceId=api", body)
    assert {200, %{"services" => [_]}} = req("GET", "#{base}/services")
    assert {200, %{"name" => _} = got} = req("GET", "#{base}/services/api")
    refute Map.has_key?(got, "_revSeq")
    assert {404, _} = req("GET", "#{base}/services/nope")

    assert {200, %{"response" => %{"generation" => 2}}} =
             req("PATCH", "#{base}/services/api", %{"template" => %{"containers" => [%{"image" => "b"}]}})

    assert {200, %{"revisions" => [_, _]}} = req("GET", "#{base}/services/api/revisions")

    pol = %{"policy" => %{"bindings" => [%{"role" => "roles/run.invoker", "members" => ["allUsers"]}]}}
    assert {200, %{"bindings" => [_]}} = req("POST", "#{base}/services/api:setIamPolicy", pol)
    assert {200, %{"bindings" => [%{"members" => ["allUsers"]}]}} = req("POST", "#{base}/services/api:getIamPolicy", %{})

    assert {200, %{"done" => true}} = req("DELETE", "#{base}/services/api")
    assert {404, _} = req("GET", "#{base}/services/api")
  end

  test "entries write then list over the wire; bad filter is 400" do
    p = uniq()
    log = "projects/#{p}/logs/run"

    assert {200, %{}} =
             req("POST", "/v2/entries:write", %{
               "logName" => log,
               "resource" => %{"type" => "cloud_run_revision"},
               "entries" => [
                 %{"severity" => "INFO", "textPayload" => "hello"},
                 %{"severity" => "ERROR", "textPayload" => "boom"}
               ]
             })

    assert {200, %{"entries" => [%{"textPayload" => "boom"}]}} =
             req("POST", "/v2/entries:list", %{"resourceNames" => ["projects/#{p}"], "filter" => "severity>=ERROR"})

    assert {200, %{"entries" => [_, _]}} = req("POST", "/v2/entries:list", %{"resourceNames" => ["projects/#{p}"]})
    assert {400, _} = req("POST", "/v2/entries:list", %{"resourceNames" => ["projects/#{p}"], "filter" => "bogus!"})
    assert {400, _} = req("POST", "/v2/entries:write", %{"nope" => 1})
  end

  test "sinks create/get/update/list/delete" do
    p = uniq()
    base = "/v2/projects/#{p}/sinks"
    assert {200, %{"name" => "s1"}} = req("POST", base, %{"name" => "s1", "destination" => "storage.googleapis.com/b"})
    assert {409, _} = req("POST", base, %{"name" => "s1"})
    assert {400, _} = req("POST", base, %{})
    assert {200, %{"sinks" => [_]}} = req("GET", base)
    assert {200, %{"filter" => "severity>=ERROR", "destination" => "storage.googleapis.com/b"}} =
             req("PATCH", "#{base}/s1", %{"filter" => "severity>=ERROR"})
    assert {200, _} = req("DELETE", "#{base}/s1")
    assert {404, _} = req("GET", "#{base}/s1")
  end

  test "google_cloud_run_v2_service schema fields and 404 NOT_FOUND JSON shape" do
    p = uniq()
    base = "/v2/projects/#{p}/locations/us-central1"

    assert {404, %{"error" => %{"code" => 404, "status" => "NOT_FOUND", "message" => _}}} =
             req("GET", "#{base}/services/missing")

    body = %{
      "description" => "tf svc",
      "labels" => %{"env" => "dev"},
      "template" => %{"containers" => [%{"image" => "gcr.io/x/app:v1"}]}
    }

    assert {200, %{"done" => true, "name" => opname, "response" => svc}} =
             req("POST", "#{base}/services?serviceId=tf-svc", body)

    assert svc["name"] == "projects/#{p}/locations/us-central1/services/tf-svc"
    assert svc["uri"] == "https://tf-svc-#{p}.us-central1.run.smalt.local"
    assert svc["urls"] == [svc["uri"]]
    assert svc["generation"] == 1
    assert svc["observedGeneration"] == 1
    assert svc["reconciling"] == false
    assert is_binary(svc["etag"])
    assert svc["description"] == "tf svc"
    assert svc["labels"] == %{"env" => "dev"}
    assert [%{"type" => "Ready", "state" => "CONDITION_SUCCEEDED"}] = svc["conditions"]
    assert [%{"percent" => 100}] = svc["trafficStatuses"]

    assert {200, %{"done" => true, "name" => ^opname}} =
             req("GET", "#{base}/operations/#{Path.basename(opname)}")

    assert {200, %{"response" => patched}} =
             req("PATCH", "#{base}/services/tf-svc", %{"ingress" => "INGRESS_TRAFFIC_INTERNAL_ONLY"})

    assert patched["generation"] == 2
    assert patched["observedGeneration"] == 2
    assert patched["description"] == "tf svc"
    assert patched["ingress"] == "INGRESS_TRAFFIC_INTERNAL_ONLY"
  end

  test "google_cloudfunctions2_function buildConfig.entryPoint, update, and LROs" do
    p = uniq()

    body = %{
      "description" => "v2 fn",
      "labels" => %{"team" => "infra"},
      "buildConfig" => %{"runtime" => "nodejs20", "entryPoint" => "Elixir.Mod.fn"}
    }

    assert {:ok, %{"done" => true, "name" => opname, "response" => fun}} =
             Functions.create_function_lro(p, "us-central1", "fn-v2", body)

    assert fun["name"] == "projects/#{p}/locations/us-central1/functions/fn-v2"
    assert fun["state"] == "ACTIVE"
    assert fun["url"] == "https://us-central1-#{p}.cloudfunctions.smalt.local/fn-v2"
    assert fun["serviceConfig"]["uri"] == fun["url"]
    assert fun["buildConfig"]["entryPoint"] == "Elixir.Mod.fn"
    assert fun["description"] == "v2 fn"

    assert {:ok, %{"done" => true, "name" => ^opname}} =
             Functions.get_operation(Path.basename(opname))

    assert {:ok, %{"done" => true, "response" => updated}} =
             Functions.update_function_lro(p, "us-central1", "fn-v2", %{
               "serviceConfig" => %{"maxInstanceCount" => 2}
             })

    assert updated["serviceConfig"]["maxInstanceCount"] == 2
    assert updated["description"] == "v2 fn"

    assert {:ok, %{"done" => true}} = Functions.delete_function_lro(p, "us-central1", "fn-v2")
    assert {:error, {404, "NOT_FOUND", _}} = Functions.get_function(p, "us-central1", "fn-v2")
  end

  test "logging list_entries handles explicit nil filter, orderBy, pageSize" do
    p = uniq()
    log = "projects/#{p}/logs/run"

    assert {:ok, %{}} =
             Logging.write_entries(%{
               "logName" => log,
               "entries" => [%{"severity" => "INFO", "textPayload" => "ok"}]
             })

    assert {:ok, %{"entries" => [%{"textPayload" => "ok"}]}} =
             Logging.list_entries(%{
               "resourceNames" => ["projects/#{p}"],
               "filter" => nil,
               "orderBy" => nil,
               "pageSize" => nil
             })
  end
end
