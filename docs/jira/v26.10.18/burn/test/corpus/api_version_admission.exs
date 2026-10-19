# INCIDENT → FIX → FENCE
#
# INCIDENT: KD-78 — azurerm 4.54.0 pins resourceGroups api-version 2023-07-01
# while the router capped resourceGroups at 2021-04-01; every terraform apply
# failed at the RG pre-check GET with 400 InvalidApiVersionParameter
# (tf-plan-probe, v26.10.16).
#
# FIX: monotonic admission law in `Smalt.ArmGateway.Router.check_version/3` —
# any api-version <= Registry.latest_version/1 admits; only strictly newer
# versions are refused 400 InvalidApiVersionParameter (naming the registry
# latest as the stale-beam diagnostic).
#
# FENCE (this corpus row): the CLOSED wire shape cannot regress.
Code.require_file("helper.exs", __DIR__)

defmodule Smalt.Corpus.ApiVersionAdmission do
  @moduledoc false

  use ExUnit.Case, async: false

  import Smalt.Corpus.Helper

  alias Smalt.Registry

  @admit_type "Microsoft.Storage/storageAccounts"

  setup do
    ensure_store()
  end

  defp put_account(version) do
    uri =
      "/subscriptions/sub-corpus/resourceGroups/corpus-rg/providers/Microsoft.Storage/storageAccounts/corpus-acct"

    uri =
      case version do
        :omit -> uri
        v -> uri <> "?api-version=" <> v
      end

    arm(:put, uri, %{"location" => "eastus", "properties" => %{}})
  end

  defp api_version_error?(conn),
    do: code(conn) in ["InvalidApiVersionParameter", "MissingApiVersionParameter"]

  @tag :corpus
  test "api-version == latest admits (no api-version 400)" do
    latest = Registry.latest_version(@admit_type)
    conn = put_account(latest)

    refute api_version_error?(conn),
           "latest #{latest} refused: #{conn.status} #{inspect(conn.resp_body)}"
  end

  @tag :corpus
  test "api-version OLDER than latest (2019-01-01) admits — the monotonic law (KD-78)" do
    conn = put_account("2019-01-01")

    assert conn.status in [200, 201, 202, 400, 404]
    refute api_version_error?(conn), "monotonic admission regressed: #{inspect(conn.resp_body)}"
  end

  @tag :corpus
  test "api-version NEWER than latest (2099-01-01) -> 400 InvalidApiVersionParameter naming the registry latest" do
    latest = Registry.latest_version(@admit_type)
    conn = put_account("2099-01-01")

    assert conn.status == 400
    assert code(conn) == "InvalidApiVersionParameter"
    assert conn.resp_body =~ to_string(latest)
  end

  @tag :corpus
  test "api-version absent -> 400 MissingApiVersionParameter" do
    conn = put_account(:omit)

    assert conn.status == 400
    assert code(conn) == "MissingApiVersionParameter"
  end
end
