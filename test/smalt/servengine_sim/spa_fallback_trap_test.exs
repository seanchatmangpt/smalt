defmodule Smalt.ServengineSim.SpaFallbackTrapTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  import Plug.Test

  alias Smalt.ServengineSim.SpaFallbackTrap

  describe "accept negotiation" do
    test "strict application/json rejects html while wildcard accept admits html" do
      refute SpaFallbackTrap.accepts_format?("application/json", :html)
      assert SpaFallbackTrap.accepts_format?("application/json", :json)
      assert SpaFallbackTrap.accepts_format?("application/vnd.api+json", :json)
      refute SpaFallbackTrap.accepts_format?("application/vnd.api+json", :html)

      # Axios / browser fetch defaults include */* which Phoenix :browser accepts(["html"]) admits
      assert SpaFallbackTrap.accepts_format?("application/json, text/plain, */*", :html)
      assert SpaFallbackTrap.accepts_format?("*/*", :html)
      assert SpaFallbackTrap.accepts_format?(nil, :html)

      # RFC 9110 specificity: explicit text/html;q=0 overrides */*
      refute SpaFallbackTrap.accepts_format?("*/*, text/html;q=0", :html)
      refute SpaFallbackTrap.accepts_format?("application/json, */*;q=0", :html)
    end
  end

  describe "406 detector on /entity/validate-sub-domain" do
    test "detects 406 Not Acceptable when Accept: application/json hits /*path in :trap mode" do
      conn =
        conn(:get, "/entity/validate-sub-domain?sub_domain=acme")
        |> put_req_header("accept", "application/json")
        |> SpaFallbackTrap.call(mode: :trap)

      assert conn.status == 406
      assert {:detected, finding} = SpaFallbackTrap.detect_406(conn)
      assert finding.trap == :spa_406_not_acceptable
      assert finding.status == 406
      assert finding.path == "/entity/validate-sub-domain"
      assert finding.method == "GET"
      assert finding.accept == "application/json"
      assert finding.reason == :browser_fallback_rejected_json_accept
      assert {:detected, ^finding} = SpaFallbackTrap.inspect_conn(conn)
    end

    test "probe_406 catches :trap and :shadowed modes, and passes :fixed mode" do
      assert {:detected, %{trap: :spa_406_not_acceptable, status: 406}} =
               SpaFallbackTrap.probe_406(
                 {SpaFallbackTrap, [mode: :trap]},
                 "/entity/validate-sub-domain"
               )

      assert {:detected, %{trap: :spa_406_not_acceptable, status: 406}} =
               SpaFallbackTrap.probe_406(
                 {SpaFallbackTrap, [mode: :shadowed]},
                 "/entity/validate-sub-domain"
               )

      assert :ok ==
               SpaFallbackTrap.probe_406(
                 {SpaFallbackTrap, [mode: :fixed]},
                 "/entity/validate-sub-domain"
               )
    end

    test "fixed mode answers 200 JSON on /entity/validate-sub-domain" do
      conn =
        conn(:get, "/entity/validate-sub-domain?sub_domain=acme")
        |> put_req_header("accept", "application/json")
        |> SpaFallbackTrap.call(mode: :fixed)

      assert conn.status == 200
      assert [ct | _] = get_resp_header(conn, "content-type")
      assert String.starts_with?(ct, "application/json")
      assert %{"valid" => true, "sub_domain" => "acme"} = Jason.decode!(conn.resp_body)
      assert :ok == SpaFallbackTrap.detect_406(conn)
    end
  end

  describe "200 HTML leak detector on /s3 and /device-tokens" do
    for path <- ["/s3", "/s3/presign", "/device-tokens", "/device-tokens/register"],
        accept <- ["*/*", "application/json, text/plain, */*", "text/html", nil] do
      @path path
      @accept accept
      test "detects 200 HTML leak on #{@path} with Accept: #{inspect(@accept)} in :trap mode" do
        conn = SpaFallbackTrap.dispatch({SpaFallbackTrap, [mode: :trap]}, :get, @path, @accept)

        assert conn.status == 200
        assert [ct | _] = get_resp_header(conn, "content-type")
        assert String.starts_with?(ct, "text/html")

        assert {:detected, finding} = SpaFallbackTrap.detect_html_leak(conn)
        assert finding.trap == :spa_200_html_leak
        assert finding.status == 200
        assert finding.path == @path
        assert finding.reason == :api_route_served_spa_html
        assert {:detected, ^finding} = SpaFallbackTrap.inspect_conn(conn)
      end
    end

    test "probe_html_leak flags :trap and :shadowed modes on /s3 and /device-tokens, passes :fixed" do
      for path <- ["/s3", "/device-tokens"] do
        assert {:detected, %{trap: :spa_200_html_leak, path: ^path}} =
                 SpaFallbackTrap.probe_html_leak({SpaFallbackTrap, [mode: :trap]}, path)

        assert {:detected, %{trap: :spa_200_html_leak, path: ^path}} =
                 SpaFallbackTrap.probe_html_leak({SpaFallbackTrap, [mode: :shadowed]}, path)

        assert :ok ==
                 SpaFallbackTrap.probe_html_leak({SpaFallbackTrap, [mode: :fixed]}, path)
      end
    end

    test "detect_html_leak catches HTML shell body even if content-type header is text/plain" do
      leaky_plug = fn conn ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, "<!doctype html><html><body><div id=\"root\"></div></body></html>")
        |> halt()
      end

      assert {:detected, %{trap: :spa_200_html_leak, path: "/s3"}} =
               SpaFallbackTrap.probe_html_leak(leaky_plug, "/s3")
    end

    test "fixed mode answers 200 JSON on /s3 and /device-tokens and 404 JSON on unknown API paths" do
      s3_conn = SpaFallbackTrap.dispatch({SpaFallbackTrap, [mode: :fixed]}, :get, "/s3", "*/*")
      assert s3_conn.status == 200
      assert %{"service" => "s3", "presigned" => true} = Jason.decode!(s3_conn.resp_body)
      assert :ok == SpaFallbackTrap.detect_html_leak(s3_conn)

      dt_conn =
        SpaFallbackTrap.dispatch(
          {SpaFallbackTrap, [mode: :fixed]},
          :get,
          "/device-tokens",
          "application/json, text/plain, */*"
        )

      assert dt_conn.status == 200
      assert %{"tokens" => []} = Jason.decode!(dt_conn.resp_body)
      assert :ok == SpaFallbackTrap.detect_html_leak(dt_conn)

      missing_api =
        SpaFallbackTrap.dispatch({SpaFallbackTrap, [mode: :fixed]}, :get, "/api/unknown", "*/*")

      assert missing_api.status == 404
      assert %{"error" => "not_found"} = Jason.decode!(missing_api.resp_body)
      assert :ok == SpaFallbackTrap.detect_html_leak(missing_api)
    end
  end

  describe "anti-false-positive boundaries" do
    test "legitimate SPA browser routes do not trigger HTML leak or 406 detectors" do
      for spa_path <- ["/", "/dashboard", "/s3-admin-ui"] do
        html_conn =
          SpaFallbackTrap.dispatch({SpaFallbackTrap, [mode: :trap]}, :get, spa_path, "text/html")

        assert html_conn.status == 200
        assert :ok == SpaFallbackTrap.detect_html_leak(html_conn)
        assert :ok == SpaFallbackTrap.inspect_conn(html_conn)

        json_conn =
          SpaFallbackTrap.dispatch(
            {SpaFallbackTrap, [mode: :trap]},
            :get,
            spa_path,
            "application/json"
          )

        assert json_conn.status == 406
        assert :ok == SpaFallbackTrap.detect_406(json_conn)
      end
    end

    test "mounted :api route /health is clean in :trap mode but shadowed in :shadowed mode" do
      trap_conn =
        SpaFallbackTrap.dispatch(
          {SpaFallbackTrap, [mode: :trap]},
          :get,
          "/health",
          "application/json"
        )

      assert trap_conn.status == 200
      assert %{"ok" => true} = Jason.decode!(trap_conn.resp_body)

      shadow_conn =
        SpaFallbackTrap.dispatch(
          {SpaFallbackTrap, [mode: :shadowed]},
          :get,
          "/health",
          "application/json"
        )

      assert shadow_conn.status == 406

      assert {:detected, %{trap: :spa_406_not_acceptable}} =
               SpaFallbackTrap.detect_406(shadow_conn, api_only: false)
    end
  end

  describe "full audit/2 report" do
    test "reports :trapped with both 406 and 200 HTML leak findings in :trap and :shadowed modes" do
      trap_report = SpaFallbackTrap.audit({SpaFallbackTrap, [mode: :trap]})
      assert trap_report.verdict == :trapped
      assert trap_report.by_trap == %{spa_406_not_acceptable: 1, spa_200_html_leak: 4}

      assert Enum.any?(
               trap_report.findings,
               &(&1.path == "/entity/validate-sub-domain" and &1.status == 406)
             )

      assert Enum.any?(trap_report.findings, &(&1.path == "/s3" and &1.status == 200))
      assert Enum.any?(trap_report.findings, &(&1.path == "/device-tokens" and &1.status == 200))

      shadow_report = SpaFallbackTrap.audit({SpaFallbackTrap, [mode: :shadowed]})
      assert shadow_report.verdict == :trapped
      assert shadow_report.by_trap == %{spa_406_not_acceptable: 1, spa_200_html_leak: 4}
    end

    test "reports :clean with zero findings in :fixed mode" do
      fixed_report = SpaFallbackTrap.audit({SpaFallbackTrap, [mode: :fixed]})
      assert fixed_report.verdict == :clean
      assert fixed_report.findings == []
      assert fixed_report.by_trap == %{spa_406_not_acceptable: 0, spa_200_html_leak: 0}
    end
  end
end
