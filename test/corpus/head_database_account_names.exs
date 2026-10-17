# INCIDENT → FIX → FENCE
#
# INCIDENT: azurerm 4.54 sends `HEAD /subscriptions/{sub}/providers/
# Microsoft.DocumentDB/databaseAccountNames/{name}` with NO api-version before
# create (CheckNameExists). The router 400'd on the missing api-version and
# autorest cannot parse a JSON body on HEAD — every cosmos terraform apply
# failed at the name-existence pre-check (tf-plan-probe EBIxd7 cosmos
# apply.log; HEAD route landed at lib/smalt/arm_gateway/router.ex:2839).
#
# FIX: HEAD existence checks answer 204 (exists) / 404 (not exists) with EMPTY
# bodies and no api-version requirement; existence = any stored resource
# record whose lowercased id ends with
# /providers/microsoft.documentdb/databaseaccounts/{name}.
#
# FENCE (this corpus row): the CLOSED wire shape cannot regress.
defmodule Smalt.Corpus.HeadDatabaseAccountNames do
  @moduledoc false

  use ExUnit.Case, async: false

  import Smalt.Corpus.Helper

  @sub "sub-corpus"
  @rg "corpus-rg"
  @name "corpus-cosmos"

  setup do
    ensure_store()
  end

  defp head_name do
    arm(:head, "/subscriptions/#{@sub}/providers/Microsoft.DocumentDB/databaseAccountNames/#{@name}")
  end

  defp put_account do
    arm(
      :put,
      "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.DocumentDB/databaseAccounts/#{@name}?api-version=2021-04-01",
      %{"location" => "eastus", "properties" => %{}}
    )
  end

  @tag :corpus
  test "HEAD before create -> 404 with an EMPTY body (no api-version required)" do
    conn = head_name()

    assert conn.status == 404
    assert conn.resp_body == ""
  end

  @tag :corpus
  test "HEAD after create -> 204 with an EMPTY body" do
    create = put_account()
    assert create.status in [200, 201], inspect(create.resp_body)

    conn = head_name()

    assert conn.status == 204
    assert conn.resp_body == ""
  end

  @tag :corpus
  test "existence check is case-insensitive on the account name" do
    create = put_account()
    assert create.status in [200, 201]

    conn =
      arm(
        :head,
        "/subscriptions/#{@sub}/providers/Microsoft.DocumentDB/databaseAccountNames/#{String.upcase(@name)}"
      )

    assert conn.status == 204
  end
end
