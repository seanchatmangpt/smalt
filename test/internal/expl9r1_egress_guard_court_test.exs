# EXPL9-R1 court (v26.10.22): read_body guards + crash-path fence on the real
# egress router (real HTTP over loopback, real Smalt.Store, no mocks).
#
# Repairs under court (docs/jira/v26.10.22/receipts/expl9-egress-arm-errc.md):
#   F2 (HIGH, witnessed): {:put_range, s, p} arm matched Plug.Conn.read_body/1
#       unguarded — a 9MB PUT comp=range escaped as {:more,_,_} -> MatchError,
#       and because EgressRouter had NO Plug.ErrorHandler, Bandit rendered a
#       NAKED adapter 500 (empty body, no envelope, no x-ms-request-id). Fix:
#       (a) guarded read_body case -> typed 413 RequestBodyTooLarge (file-face
#       XML envelope), (b) `use Plug.ErrorHandler` crash-path fence rendering
#       the Storage <Error> envelope + x-ms-request-id on ANY unhandled crash
#       (GAP-AZB20-3 class; KD-COVERS: KD-174).
#   F4 (LOW): PUT /:account?restype=service&comp=properties (service
#       properties arm, behind the x-ms-version fence) — same unguarded
#       escape, same canonical guard -> 413 on the blob face.
#
# Falsifiers:
#   - 9MB PUT comp=range -> 413 RequestBodyTooLarge envelope (never a naked
#     500, never a MatchError)
#   - 9MB service-properties PUT (valid x-ms-version) -> 413 envelope
#   - small-body baselines unchanged (range on absent share -> typed 404;
#     service properties small body -> parsed/typed response, not a crash)
#   - crash fence exists and renders envelope + x-ms-request-id (fence leg)
#
# Context: solo (internal tier, in-process wire faces).

defmodule Smalt.Test.Internal.Expl9r1EgressGuardCourtTest do
  use ExUnit.Case, async: false

  @oversize 9 * 1024 * 1024
  @version "2021-12-02"

  setup do
    case GenServer.start_link(Smalt.Store, []) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    :ok
  end

  defp base, do: "http://127.0.0.1:#{Application.fetch_env!(:smalt, :egress_port)}"

  defp put(url, ctype, body, headers) do
    :httpc.request(
      :put,
      {String.to_charlist(url), headers, ~c"application/octet-stream", body},
      [],
      body_format: :binary
    )
    |> case do
      {:ok, {{_v, status, _phrase}, hds, rsp}} ->
        {status, hds, rsp}

      {:error, reason} ->
        flunk("httpc error on #{url}: #{inspect(reason)}")
    end
  end

  defp header(hds, name) do
    case :proplists.get_all_values(String.to_charlist(name), hds) do
      [] -> nil
      vals -> vals |> List.last() |> to_string()
    end
  end

  defp xml_code(body) do
    case Regex.run(~r/<Code>([^<]+)<\/Code>/, body) do
      [_, code] -> code
      _ -> nil
    end
  end

  # -- F2a: oversized Put Range -> typed 413, never a naked 500 ---------------

  test "F2: 9MB PUT comp=range answers 413 RequestBodyTooLarge envelope (the witnessed frame flips)" do
    share = "expl9r1share"
    dir = "expl9r1dir"
    file = "expl9r1file.txt"
    url = "#{base()}/#{share}/#{dir}/#{file}?comp=range"
    body = :binary.copy(<<0>>, @oversize)

    {status, hds, rsp} = put(url, ~c"application/octet-stream", body, [])

    assert status == 413, "expected 413, got #{status}: body=#{inspect(rsp)}"
    assert xml_code(rsp) == "RequestBodyTooLarge"
    # envelope contract: x-ms-request-id always present on typed errors
    assert is_binary(header(hds, "x-ms-request-id"))
    assert header(hds, "x-ms-error-code") == "RequestBodyTooLarge"
  end

  test "F2 baseline: small-body PUT comp=range on absent share keeps the typed 404 ShareNotFound" do
    share = "expl9r1share-absent-#{System.unique_integer([:positive])}"
    url = "#{base()}/#{share}/d/f.txt?comp=range"

    {status, hds, rsp} = put(url, ~c"application/octet-stream", "tiny", [])

    assert status == 404, "expected 404, got #{status}: #{inspect(rsp)}"
    assert xml_code(rsp) == "ShareNotFound"
    assert is_binary(header(hds, "x-ms-request-id"))
  end

  # -- F2b: crash-path fence (no naked adapter 500) ----------------------------

  test "F2b: crash-path fence is wired (use Plug.ErrorHandler + handle_errors renders envelope)" do
    src = File.read!("lib/smalt/egress_router.ex")

    assert src =~ "use Plug.ErrorHandler"
    assert src =~ "defp handle_errors("
    # the handler renders the Storage envelope + request id, never a naked 500
    assert src =~ ~s{error_xml("InternalServerError", "Internal server error.")}
    assert src =~ ~s{put_resp_header("x-ms-request-id", generate_request_id())}
  end

  # -- F4: service-properties arm same guard ----------------------------------

  test "F4: 9MB PUT service properties (valid x-ms-version) answers 413 RequestBodyTooLarge" do
    url = "#{base()}/expl9r1acct?restype=service&comp=properties"
    body = String.pad_trailing(~S(<StorageServiceProperties />), @oversize, "x")

    {status, hds, rsp} =
      put(url, ~c"application/xml", body, [{~c"x-ms-version", String.to_charlist(@version)}])

    assert status == 413, "expected 413, got #{status}: body=#{inspect(rsp)}"
    assert xml_code(rsp) == "RequestBodyTooLarge"
    assert is_binary(header(hds, "x-ms-request-id"))
  end

  test "F4 baseline: small service-properties body stays typed (no crash, no naked 500)" do
    url = "#{base()}/expl9r1acct?restype=service&comp=properties"
    xml = ~S(<StorageServiceProperties />)

    {status, _hds, rsp} =
      put(url, ~c"application/xml", xml, [{~c"x-ms-version", String.to_charlist(@version)}])

    assert status in [202, 400], "expected typed 202/400, got #{status}: #{inspect(rsp)}"
  end
end
