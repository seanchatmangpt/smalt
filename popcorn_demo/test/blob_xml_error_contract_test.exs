# Z5 — Chicago regression contract for the Azure-Storage XML error face
# (B-XML landing: Smalt.DataPlane.BlobError + :smalt_blob_face stamp).
#
# These are the KD-136..142 close-condition inputs, pinned as expected
# behaviors: each error shape must answer with the byte-shape XML envelope
# `<?xml ...?><Error><Code>..</Code><Message>..</Message></Error>`,
# Content-Type application/xml, and the x-ms-error-code / x-ms-request-id /
# x-ms-version header set — over the REAL substrate (data plane 8443, ARM
# 9443) via the shared loopback-only :httpc transport. No mocks.
#
# Scope regressions pin the faces that must NOT flip: non-blob (ARM) errors
# stay JSON; KD-66 ranged-GET content-md5 and KD-130 409 ContainerAlreadyExists
# stay green.
#
# Context: solo (live substrate leg, host-side :httpc).
#
# Beam-predate note: substrate pid 6909 booted 2026-10-21 10:15:54, AFTER
# lib/smalt/data_plane/blob_error.ex mtime (10:07) — the running beam carries
# the XML face (confirmed by live curl probes: BlobNotFound 404 XML on 8443),
# so every assertion below runs against the post-fix beam; none need a
# restart.

defmodule PopcornDemo.BlobXmlErrorContractTest do
  use ExUnit.Case, async: false

  @base "http://127.0.0.1:8443"
  @arm "http://127.0.0.1:9443"
  @sts "http://127.0.0.1:9443"
  @tenant "smalt-tenant"
  @account "popcorn"
  @ms_version "2021-12-02"

  # -- real collaborator: loopback :httpc ------------------------------------

  defp req(method, url, headers, body \\ nil) do
    {:ok, token} = mint()

    case PopcornDemo.Transport.Httpc.request(%{
           method: method,
           url: url,
           headers: [{"authorization", "Bearer " <> token}] ++ headers,
           body: body
         }) do
      {:ok, resp} -> resp
      {:error, reason} -> flunk("httpc transport error on #{url}: #{inspect(reason)}")
    end
  end

  defp mint do
    {:ok, %{status: 200, body: body}} =
      PopcornDemo.Transport.Httpc.request(%{
        method: "POST",
        url: @sts <> "/#{@tenant}/oauth2/v2.0/token",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: "grant_type=client_credentials&client_id=popcorn-demo&client_secret=not-checked"
      })

    %{"access_token" => tok} = Jason.decode!(body)
    {:ok, tok}
  end

  defp fresh_name(prefix),
    do: prefix <> Integer.to_string(System.system_time(:millisecond)) <> "-" <> Integer.to_string(:erlang.unique_integer([:positive]))

  defp hdr(resp, name) do
    case Enum.filter(resp.headers, fn {k, _v} -> k == name end) do
      [{^name, v}] -> {:ok, v}
      [{^name, v} | _rest] -> {:ok, v}
      [] -> flunk("missing response header #{name} (got: #{inspect(resp.headers)})")
    end
  end

  # -- the contract under test -----------------------------------------------

  describe "blob-face XML error envelope (KD-136..142 close-condition inputs)" do
    @tag :bxml
    test "BlobNotFound 404 is byte-shape XML with the full error header set" do
      ctr = fresh_name("bxmlc")
      assert %{status: 201} = req("PUT", "#{@base}/#{@account}/#{ctr}?restype=container", [{"x-ms-version", @ms_version}])

      resp =
        req("GET", "#{@base}/#{@account}/#{ctr}/no-such-blob", [{"x-ms-version", @ms_version}])

      assert resp.status == 404
      assert_xml_error(resp, "BlobNotFound")
    end

    @tag :bxml
    test "ContainerNotFound 404 is XML (Get Container Properties on a missing container)" do
      resp = req("GET", "#{@base}/#{@account}/no-such-ctr-z5?restype=container", [{"x-ms-version", @ms_version}])

      assert resp.status == 404
      assert_xml_error(resp, "ContainerNotFound")
    end

    @tag :bxml
    test "ContainerAlreadyExists 409 is XML (also the KD-130 regression pin)" do
      ctr = fresh_name("bmldup")
      url = "#{@base}/#{@account}/#{ctr}?restype=container"
      vh = [{"x-ms-version", @ms_version}]

      assert %{status: 201} = req("PUT", url, vh)
      resp = req("PUT", url, vh)

      assert resp.status == 409
      assert_xml_error(resp, "ContainerAlreadyExists")
    end

    @tag :bxml
    test "InvalidQueryParameterValue 400 is XML (unhandled comp)" do
      ctr = fresh_name("bxmlq")
      vh = [{"x-ms-version", @ms_version}]
      assert %{status: 201} = req("PUT", "#{@base}/#{@account}/#{ctr}?restype=container", vh)

      resp = req("GET", "#{@base}/#{@account}/#{ctr}/blk?comp=not-a-comp", vh)

      assert resp.status == 400
      assert_xml_error(resp, "InvalidQueryParameterValue")
    end

    @tag :bxml
    test "MissingXMsVersion 400 is XML (no x-ms-version request header)" do
      ctr = fresh_name("bxmlv")
      vh = [{"x-ms-version", @ms_version}]
      assert %{status: 201} = req("PUT", "#{@base}/#{@account}/#{ctr}?restype=container", vh)

      # Bearer present, x-ms-version deliberately absent.
      {:ok, token} = mint()

      {:ok, resp} =
        PopcornDemo.Transport.Httpc.request(%{
          method: "GET",
          url: "#{@base}/#{@account}/#{ctr}/blk",
          headers: [{"authorization", "Bearer " <> token}],
          body: nil
        })

      assert resp.status == 400
      assert_xml_error(resp, "MissingXMsVersion")
    end

    @tag :bxml
    test "InvalidRange 416 is XML" do
      ctr = fresh_name("bxmlr")
      vh = [{"x-ms-version", @ms_version}]
      assert %{status: 201} = req("PUT", "#{@base}/#{@account}/#{ctr}?restype=container", vh)
      assert %{status: 201} =
               req("PUT", "#{@base}/#{@account}/#{ctr}/r", [
                 {"x-ms-version", @ms_version},
                 {"x-ms-blob-type", "BlockBlob"}
               ], "bxml-range-payload")

      resp =
        req("GET", "#{@base}/#{@account}/#{ctr}/r", [
          {"x-ms-version", @ms_version},
          {"x-ms-range", "bytes=99999999-"}
        ])

      assert resp.status == 416
      assert_xml_error(resp, "InvalidRange")
    end
  end

  # -- scope + sibling-KD regression pins -------------------------------------

  describe "scope regressions — non-blob faces and sibling KDs stay green" do
    @tag :bxml
    test "ARM face error stays JSON, never the XML envelope" do
      resp = req("GET", "#{@arm}/subscriptions/z5-nonexistent/resourceGroups/z5-rg", [{"x-ms-version", @ms_version}])

      assert resp.status in [400, 404]
      {:ok, ct} = hdr(resp, "content-type")
      assert ct =~ "application/json"
      assert String.starts_with?(resp.body, "{")
      assert %{} = Jason.decode!(resp.body)
      # The XML envelope never leaks onto the ARM face.
      refute resp.body =~ "<Error><Code>"
      {:ok, _} = hdr(resp, "x-ms-request-id")
    end

    @tag :bxml
    test "KD-66 pinned green: ranged GET answers 206 with matching content-md5" do
      ctr = fresh_name("bxml66")
      payload = "z5-kd66-md5-payload"
      vh = [{"x-ms-version", @ms_version}]
      assert %{status: 201} = req("PUT", "#{@base}/#{@account}/#{ctr}?restype=container", vh)
      assert %{status: 201} =
               req("PUT", "#{@base}/#{@account}/#{ctr}/r", [
                 {"x-ms-version", @ms_version},
                 {"x-ms-blob-type", "BlockBlob"}
               ], payload)

      resp =
        req("GET", "#{@base}/#{@account}/#{ctr}/r", [
          {"x-ms-version", @ms_version},
          {"x-ms-range", "bytes=0-"},
          {"x-ms-range-get-content-md5", "true"}
        ])

      assert resp.status == 206
      assert resp.body == payload

      expected_md5 = Base.encode64(:crypto.hash(:md5, payload))
      {:ok, served_md5} = hdr(resp, "content-md5")
      assert served_md5 == expected_md5
    end
  end

  # -- shared assertions -------------------------------------------------------

  defp assert_xml_error(resp, code) do
    body = resp.body

    # Byte-shape envelope: XML decl + <Error><Code>..</Code><Message>..</Message></Error>
    assert String.starts_with?(body, ~s(<?xml version="1.0" encoding="utf-8"?><Error><Code>))
    assert body =~ "<Code>#{code}</Code>"
    assert String.ends_with?(body, "</Message></Error>")

    {:ok, ct} = hdr(resp, "content-type")
    assert ct =~ "application/xml"

    {:ok, err_code} = hdr(resp, "x-ms-error-code")
    assert err_code == code

    {:ok, req_id} = hdr(resp, "x-ms-request-id")

    assert Regex.match?(
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
             req_id
           )

    {:ok, ver} = hdr(resp, "x-ms-version")
    assert ver == "2021-12-02"
  end
end
