defmodule ArmKd87StsLeadingEmptySegmentTest do
  @moduledoc """
  KD-87 falsifier leg: azurerm 4.54 derives the STS authority from the metadata
  loginEndpoint (trailing slash) and joins the tenant with a leading slash,
  POSTing `//{tenant}/oauth2/v2.0/token`. Plug.Router cannot match the leading
  empty path segment — the request falls through to the bearer guard → 401
  MissingBearerToken (TF_LOG receipt, KD-87 row). The
  normalize_leading_empty_segment plug (lib/smalt/arm_gateway/router.ex:85,
  KD-COVERS: KD-87) rewrites ["", tenant, ...] so the STS token POST reaches
  handle_token.

  Falsifier: an STS token POST whose wire path carries the leading empty
  segment answers 200 with an access_token, never 401 MissingBearerToken.
  """

  use ExUnit.Case
  use Plug.Test

  alias Smalt.ArmGateway.Router

  @opts Router.init([])

  defp post_token(path) do
    "grant_type=client_credentials&client_id=c&client_secret=s&scope=https://management.azure.com/.default"
    |> then(&Plug.Test.conn(:post, path, &1))
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> Router.call(@opts)
  end

  test "STS POST with leading empty segment reaches handle_token (200, not 401)" do
    conn = post_token("//00000000-0000-0000-0000-000000000000/oauth2/v2.0/token")

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert is_binary(body["access_token"]) and body["access_token"] != ""
  end

  test "control: normal single-slash STS token POST also answers 200" do
    conn = post_token("/00000000-0000-0000-0000-000000000000/oauth2/v2.0/token")
    assert conn.status == 200
  end
end
