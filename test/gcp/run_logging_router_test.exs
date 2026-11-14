defmodule Smalt.GCP.RunLoggingRouterTest do
  # SW4 Chicago court: real Plug.Test conns, real router, real engines/Store.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Smalt.GCP.RunLoggingRouter

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
end
