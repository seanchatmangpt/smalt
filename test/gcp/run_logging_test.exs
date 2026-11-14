defmodule Smalt.GCP.RunLoggingTest do
  use ExUnit.Case, async: false

  alias Smalt.GCP.{CloudRun, Logging}

  defp uniq, do: "p#{System.unique_integer([:positive])}"

  test "service create returns done LRO, get/list/duplicate behave" do
    p = uniq()
    body = %{"template" => %{"containers" => [%{"image" => "gcr.io/x/a"}]}}
    assert {:ok, %{"done" => true, "response" => svc}} = CloudRun.create_service(p, "us-central1", "api", body)
    assert svc["ingress"] == "INGRESS_TRAFFIC_ALL"
    refute Map.has_key?(svc, "_iam")
    assert {:ok, %{"done" => true}} = CloudRun.get_operation(Path.basename(elem(CloudRun.create_service(p, "us-central1", "b", body), 1)["name"]))
    assert {:error, {409, "ALREADY_EXISTS", _}} = CloudRun.create_service(p, "us-central1", "api", body)
    assert length(CloudRun.list_services(p, "us-central1")) == 2
    assert {:error, {404, _, _}} = CloudRun.get_service(p, "us-central1", "nope")
    assert {:error, {400, _, _}} = CloudRun.create_service(p, "us-central1", "Bad_Id", body)
  end

  test "replace with new template mints a new revision; same template does not" do
    p = uniq()
    t1 = %{"containers" => [%{"image" => "a"}]}
    {:ok, _} = CloudRun.create_service(p, "l", "s", %{"template" => t1})
    assert length(CloudRun.list_revisions(p, "l", "s")) == 1
    {:ok, _} = CloudRun.replace_service(p, "l", "s", %{"template" => t1, "ingress" => "INGRESS_TRAFFIC_INTERNAL_ONLY"})
    assert length(CloudRun.list_revisions(p, "l", "s")) == 1
    {:ok, %{"response" => r}} = CloudRun.replace_service(p, "l", "s", %{"template" => %{"containers" => [%{"image" => "b"}]}})
    assert length(CloudRun.list_revisions(p, "l", "s")) == 2
    assert r["generation"] == 3
    assert r["ingress"] == "INGRESS_TRAFFIC_INTERNAL_ONLY"
    assert {:ok, _} = CloudRun.get_revision(p, "l", "s", Path.basename(r["latestReadyRevision"]))
    assert {:error, {400, _, _}} = CloudRun.replace_service(p, "l", "s", %{"ingress" => "BOGUS"})
  end

  test "invoker IAM survives replace; allUsers and member checks; delete removes revisions" do
    p = uniq()
    {:ok, _} = CloudRun.create_service(p, "l", "s", %{})
    refute CloudRun.invoker?(p, "l", "s", "user:a@x.com")
    {:ok, _} = CloudRun.set_iam_policy(p, "l", "s", %{"bindings" => [%{"role" => "roles/run.invoker", "members" => ["user:a@x.com"]}]})
    assert CloudRun.invoker?(p, "l", "s", "user:a@x.com")
    refute CloudRun.invoker?(p, "l", "s", "user:b@x.com")
    {:ok, _} = CloudRun.replace_service(p, "l", "s", %{"template" => %{"containers" => [%{"image" => "z"}]}})
    assert CloudRun.invoker?(p, "l", "s", "user:a@x.com")
    {:ok, _} = CloudRun.set_iam_policy(p, "l", "s", %{"bindings" => [%{"role" => "roles/run.invoker", "members" => ["allUsers"]}]})
    assert CloudRun.invoker?(p, "l", "s", "user:anyone")
    assert {:ok, %{"done" => true}} = CloudRun.delete_service(p, "l", "s")
    assert CloudRun.list_revisions(p, "l", "s") == []
    assert {:error, {404, _, _}} = CloudRun.get_service(p, "l", "s")
  end

  test "logging write then list with filters and ordering" do
    p = uniq()
    log = "projects/#{p}/logs/run"
    res = %{"type" => "cloud_run_revision"}

    assert {:ok, _} =
             Logging.write_entries(%{
               "logName" => log,
               "resource" => res,
               "entries" => [
                 %{"severity" => "INFO", "textPayload" => "boot ok"},
                 %{"severity" => "ERROR", "textPayload" => "boom"},
                 %{"severity" => "WARNING", "textPayload" => "slow"}
               ]
             })

    {:ok, %{"entries" => all}} = Logging.list_entries(%{"resourceNames" => ["projects/#{p}"]})
    assert Enum.map(all, & &1["textPayload"]) == ["boot ok", "boom", "slow"]
    refute Map.has_key?(hd(all), "_ns")

    {:ok, %{"entries" => hi}} = Logging.list_entries(%{"resourceNames" => ["projects/#{p}"], "filter" => ~s(severity>=WARNING AND resource.type="cloud_run_revision")})
    assert Enum.map(hi, & &1["severity"]) == ["ERROR", "WARNING"]

    {:ok, %{"entries" => d}} = Logging.list_entries(%{"resourceNames" => ["projects/#{p}"], "orderBy" => "timestamp desc", "pageSize" => 1})
    assert [%{"textPayload" => "slow"}] = d

    {:ok, %{"entries" => t}} = Logging.list_entries(%{"resourceNames" => ["projects/#{p}"], "filter" => ~s(textPayload:"boo")})
    assert length(t) == 2 and Enum.all?(t, &String.contains?(&1["textPayload"], "boo"))
  end

  test "logging refuses bad logName, severity, and unsupported filter" do
    assert {:error, {400, _, _}} = Logging.write_entries(%{"entries" => [%{"logName" => "bad"}]})
    assert {:error, {400, _, _}} = Logging.write_entries(%{"logName" => "projects/p/logs/x", "entries" => [%{"severity" => "LOUD"}]})
    assert {:error, {400, "INVALID_ARGUMENT", _}} = Logging.list_entries(%{"resourceNames" => ["projects/p"], "filter" => "jsonPayload.x=1"})
  end
end
