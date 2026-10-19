defmodule ApiVersionAdmissionTest do
  @moduledoc """
  Fence pinning the KD-78 monotonic api-version admission law in
  `Smalt.ArmGateway.Router.check_version/3`.

  For 4 baseline admitted types (sorted prefix of
  `Registry.admitted_resource_types/0`):

    1. version == latest                     -> admitted (no api-version 400)
    2. version 2019-01-01 (older than latest) -> ADMITTED (the monotonic law;
       2xx or a typed non-api-version 4xx downstream are both acceptable)
    3. version 2099-01-01 (newer than latest) -> 400 InvalidApiVersionParameter
    4. api-version absent                     -> 400 MissingApiVersionParameter
    5. malformed "abc"                        -> 400 InvalidApiVersionParameter

  Also pins the stale-beam diagnostic: the InvalidApiVersionParameter refusal
  message names `Registry.latest_version/1` for the type.
  """

  use ExUnit.Case
  use Plug.Test

  alias Smalt.ArmGateway.Router
  alias Smalt.Registry

  @opts Router.init([])
  @sub "00000000-0000-0000-0000-000000000000"
  @rg "admission-rg"

  # KD-78 fence baselines: first 4 sorted admitted types.
  @baseline_types Enum.sort(Registry.admitted_resource_types()) |> Enum.take(4)

  setup do
    # Canonical resilient shared-Store setup (v26.10.18) — replaces the
    # hand-rolled ensure_store/0 bootstrap (monitor + bounded-recursion
    # retry, one more per-suite reimplementation of the audited primitive).
    SmaltTest.Store.resilient_setup()
    :ok
  end

  for type <- @baseline_types do
    describe "#{type} (KD-78 monotonic admission)" do
      test "version == latest -> admitted" do
        latest = Registry.latest_version(unquote(type))
        conn = put(unquote(type), latest)

        refute api_version_error?(conn),
               "expected latest #{latest} to be admitted, got " <>
                 inspect(%{status: conn.status, code: error_code(conn), body: conn.resp_body})
      end

      test "version OLDER than latest (2019-01-01) -> admitted (monotonic law)" do
        latest = Registry.latest_version(unquote(type))
        conn = put(unquote(type), "2019-01-01")

        # The behavior change under KD-78: an older version must NOT hit the
        # api-version gate. Accept 2xx (created) or a typed non-api-version
        # 4xx (GraphLaw shape / 404-parent) — never an api-version rejection.
        assert conn.status in [200, 201, 202, 400, 404]

        refute api_version_error?(conn),
               "expected monotonic admission of 2019-01-01 (<= latest #{latest}) but got " <>
                 inspect(%{status: conn.status, code: error_code(conn), body: conn.resp_body})
      end

      test "version NEWER than latest (2099-01-01) -> 400 InvalidApiVersionParameter naming Registry.latest_version" do
        latest = Registry.latest_version(unquote(type))
        conn = put(unquote(type), "2099-01-01")

        assert conn.status == 400
        assert error_code(conn) == "InvalidApiVersionParameter"

        # Stale-beam diagnostic: the refusal names the registry latest.
        assert conn.resp_body =~ to_string(latest),
               "expected refusal message to name Registry.latest_version #{latest}, got " <>
                 conn.resp_body
      end

      test "api-version absent -> 400 MissingApiVersionParameter" do
        conn = put(unquote(type), :omit)

        assert conn.status == 400
        assert error_code(conn) == "MissingApiVersionParameter"
      end

      test "malformed api-version 'abc' -> 400 InvalidApiVersionParameter" do
        conn = put(unquote(type), "abc")

        assert conn.status == 400
        assert error_code(conn) == "InvalidApiVersionParameter"
      end
    end
  end

  test "baseline inventory is non-empty" do
    assert length(@baseline_types) == 4
  end

  # -- helpers ---------------------------------------------------------------

  defp put(type, version, payload \\ %{"location" => "eastus", "properties" => %{}}) do
    [ns | rest] = String.split(type, "/", parts: 2)
    path = "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/#{ns}/#{rest}/admission-res"

    uri =
      case version do
        :omit -> path
        v -> path <> "?api-version=" <> to_string(v)
      end

    :put
    |> conn(uri, Jason.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> Router.call(@opts)
  end

  defp error_code(conn) do
    case Jason.decode(conn.resp_body) do
      {:ok, %{"error" => %{"code" => code}}} -> code
      _ -> nil
    end
  end

  defp api_version_error?(conn) do
    conn.status == 400 and
      error_code(conn) in ["InvalidApiVersionParameter", "MissingApiVersionParameter"]
  end
end
