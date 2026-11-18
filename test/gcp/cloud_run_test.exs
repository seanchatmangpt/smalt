defmodule Smalt.GCP.CloudRunTest do
  use ExUnit.Case, async: false

  alias Smalt.GCP.CloudRun

  test "rejects reserved PORT env var on Cloud Run v2 container" do
    body = %{
      "template" => %{
        "containers" => [
          %{"name" => "cos", "image" => "fnox-cos", "env" => [%{"name" => "PORT", "value" => "8080"}]}
        ]
      }
    }

    assert {:error, {400, "INVALID_ARGUMENT", msg}} =
             CloudRun.create_service("p1", "us-west1", "svc-port-test", body)

    assert msg =~ "reserved environment variable PORT"
  end

  test "rejects wireproxy loopback sidecar startup_probe and depends_on" do
    body = %{
      "template" => %{
        "containers" => [
          %{"name" => "cos", "image" => "fnox-cos", "dependsOn" => ["wireproxy"]},
          %{"name" => "wireproxy", "image" => "wireproxy:latest", "startupProbe" => %{"tcpSocket" => %{"port" => 19840}}}
        ]
      }
    }

    assert {:error, {400, "INVALID_ARGUMENT", msg}} =
             CloudRun.create_service("p1", "us-west1", "svc-sidecar-test", body)

    assert msg =~ "loopback sidecar"
  end

  test "admits valid Cloud Run v2 container + loopback wireproxy without probe or dependsOn" do
    body = %{
      "template" => %{
        "containers" => [
          %{"name" => "cos", "image" => "fnox-cos", "env" => [%{"name" => "PHX_HOST", "value" => "cos.fnox.io"}]},
          %{"name" => "wireproxy", "image" => "wireproxy:latest"}
        ]
      }
    }

    assert {:ok, %{"done" => true}} =
             CloudRun.create_service("p1", "us-west1", "svc-ok-test", body)
  end
end
