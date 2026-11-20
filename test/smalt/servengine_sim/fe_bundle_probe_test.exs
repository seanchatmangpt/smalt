defmodule Smalt.ServengineSim.FeBundleProbeTest do
  use ExUnit.Case, async: true

  alias Smalt.ServengineSim.FeBundleProbe

  @moduletag :tmp_dir

  defp write_bundle!(root, files) do
    for {rel, body} <- files do
      path = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, body)
    end

    root
  end

  describe "vite_asset?/1 and finding_kinds/0" do
    test "recognizes built Vite JS and HTML extensions" do
      assert FeBundleProbe.vite_asset?("dist/index.html")
      assert FeBundleProbe.vite_asset?("dist/frame.HTM")
      assert FeBundleProbe.vite_asset?("dist/assets/index-abc123.js")
      assert FeBundleProbe.vite_asset?("dist/assets/worker.mjs")
      assert FeBundleProbe.vite_asset?("dist/assets/legacy.cjs")

      refute FeBundleProbe.vite_asset?("dist/assets/index-abc123.js.map")
      refute FeBundleProbe.vite_asset?("dist/assets/style.css")
      refute FeBundleProbe.vite_asset?("dist/assets/logo.svg")
      refute FeBundleProbe.vite_asset?("dist/manifest.json")
    end

    test "exposes all five finding kinds" do
      assert Enum.sort(FeBundleProbe.finding_kinds()) ==
               Enum.sort([
                 :https_auth_token,
                 :protocol_relative_auth_token,
                 :localhost_4000,
                 :unset_vite_platform_rpc_base_url,
                 :unset_vite_platform_auth_url
               ])
    end
  end

  describe "clean bundles (no false positives)" do
    test "passes clean Vite dist directory and ignores sourcemaps/css", %{tmp_dir: tmp_dir} do
      dist =
        write_bundle!(tmp_dir, %{
          "index.html" => """
          <!doctype html>
          <html>
            <head>
              <meta name="VITE_PLATFORM_AUTH_URL" content="https://auth.prod.example.com" />
              <script>
                window.__ENV__ = {
                  VITE_PLATFORM_RPC_BASE_URL: "https://rpc.prod.example.com",
                  VITE_PLATFORM_AUTH_URL: "https://auth.prod.example.com"
                };
              </script>
              <script type="module" src="/assets/index-001.js"></script>
            </head>
            <body><div id="app"></div></body>
          </html>
          """,
          "assets/index-001.js" => """
          const rpc = window.__ENV__.VITE_PLATFORM_RPC_BASE_URL || "https://rpc.prod.example.com";
          const auth = "https://auth.prod.example.com";
          fetch(`${auth}/auth/token`, { method: "POST" });
          fetch("/auth/token", { method: "GET" });
          const portEdge = "http://localhost:40000/health";
          """,
          "assets/chunk-002.mjs" => "export const ok = true;\n",
          "assets/app.css" => "body{color:#111}",
          "assets/index-001.js.map" => ~s({"sourcesContent":["http://localhost:4000"]})
        })

      assert {:ok, report} = FeBundleProbe.scan_dir(dist)
      assert report.status == :ok
      assert report.root == dist
      assert report.file_count == 3

      assert report.files_scanned == [
               "assets/chunk-002.mjs",
               "assets/index-001.js",
               "index.html"
             ]

      assert report.findings == []
      assert report.counts == %{}
      assert FeBundleProbe.format_report(report) =~ "OK: 3 asset(s) scanned, 0 findings"
    end
  end

  describe "endpoint leak patterns" do
    test "detects https://auth/token without double-counting //auth/token" do
      js = """
      const x = 1;
      fetch("https://auth/token", { method: "POST" });
      """

      assert {:refused, report} = FeBundleProbe.scan_content(js, file: "assets/main.js")
      assert report.counts == %{https_auth_token: 1}
      assert [finding] = report.findings
      assert finding.kind == :https_auth_token
      assert finding.file == "assets/main.js"
      assert finding.line == 2
      assert finding.column == 8
      assert finding.match == "https://auth/token"
    end

    test "detects protocol-relative //auth/token and double-slash path //auth/token" do
      js = ~s(const a="//auth/token";const b="https://app.example.com//auth/token";)

      assert {:refused, report} = FeBundleProbe.scan_content(js)
      assert report.counts == %{protocol_relative_auth_token: 2}
      assert Enum.all?(report.findings, &(&1.kind == :protocol_relative_auth_token))
      assert Enum.map(report.findings, & &1.match) == ["//auth/token", "//auth/token"]
    end

    test "detects localhost:4000 across schemes while ignoring localhost:40000" do
      js = """
      const httpUrl = "http://localhost:4000/rpc";
      const wsUrl = "ws://localhost:4000/socket";
      const otherPort = "http://localhost:40000/metrics";
      """

      assert {:refused, report} = FeBundleProbe.scan_content(js)
      assert report.counts == %{localhost_4000: 2}
      assert Enum.map(report.findings, & &1.line) == [1, 2]
      assert Enum.all?(report.findings, &(&1.match == "localhost:4000"))
    end

    test "detects 127.0.0.1:[::1] and case-folded localhost:4000; ignores *:40000" do
      js = """
      const v4 = "http://127.0.0.1:4000/rpc";
      const v6 = "http://[::1]:4000/rpc";
      const cased = "http://LocalHost:4000/auth";
      const edge = "http://127.0.0.1:40000/metrics";
      """

      assert {:refused, report} = FeBundleProbe.scan_content(js)
      assert report.counts == %{localhost_4000: 3}
      assert Enum.map(report.findings, & &1.match) == [
               "127.0.0.1:4000",
               "[::1]:4000",
               "LocalHost:4000"
             ]
    end
  end

  describe "unset VITE_PLATFORM_RPC_BASE_URL and VITE_PLATFORM_AUTH_URL" do
    test "flags unreplaced import.meta.env / process.env references" do
      js = """
      const rpc = import.meta.env.VITE_PLATFORM_RPC_BASE_URL;
      const rpcOpt = import.meta.env?.VITE_PLATFORM_RPC_BASE_URL;
      const authBracket = import.meta.env["VITE_PLATFORM_AUTH_URL"];
      const authProc = process.env.VITE_PLATFORM_AUTH_URL;
      """

      assert {:refused, report} = FeBundleProbe.scan_content(js)

      assert report.counts == %{
               unset_vite_platform_rpc_base_url: 2,
               unset_vite_platform_auth_url: 2
             }
    end

    test "flags unsubstituted HTML and JS template placeholders" do
      html = """
      <script>
        window.__ENV__ = {
          rpc: "%VITE_PLATFORM_RPC_BASE_URL%",
          auth: "${VITE_PLATFORM_AUTH_URL}",
          rpc2: "{{VITE_PLATFORM_RPC_BASE_URL}}",
          auth2: "__VITE_PLATFORM_AUTH_URL__"
        };
      </script>
      """

      assert {:refused, report} = FeBundleProbe.scan_content(html, file: "index.html")

      assert report.counts == %{
               unset_vite_platform_rpc_base_url: 2,
               unset_vite_platform_auth_url: 2
             }
    end

    test "flags empty, null, undefined, void 0, and empty meta tag bindings" do
      asset = """
      <meta name="VITE_PLATFORM_AUTH_URL" content="">
      <meta content="" name="VITE_PLATFORM_RPC_BASE_URL">
      <script>
        const cfg = {
          VITE_PLATFORM_RPC_BASE_URL: "",
          "VITE_PLATFORM_AUTH_URL": void 0,
          VITE_PLATFORM_RPC_BASE_URL: null,
          VITE_PLATFORM_AUTH_URL: undefined
        };
        const a = VITE_PLATFORM_RPC_BASE_URL = "   ";
        const b = VITE_PLATFORM_AUTH_URL = 'undefined';
      </script>
      """

      assert {:refused, report} = FeBundleProbe.scan_content(asset, file: "index.html")

      assert report.counts == %{
               unset_vite_platform_rpc_base_url: 4,
               unset_vite_platform_auth_url: 4
             }
    end
  end

  describe "directory, file, env, and UTF-8 edge cases" do
    test "scans mixed JS/HTML files recursively and formats refusal report", %{tmp_dir: tmp_dir} do
      dist =
        write_bundle!(tmp_dir, %{
          "index.html" => ~s(<script>window.__ENV__={VITE_PLATFORM_AUTH_URL:""}</script>),
          "nested/embed.htm" => ~s(<a href="//auth/token">login</a>),
          "assets/app.js" => ~S|fetch("https://auth/token");|,
          "assets/rpc.cjs" => ~s(const u="http://localhost:4000/rpc";),
          "assets/worker.mjs" => ~s(export const r=import.meta.env.VITE_PLATFORM_RPC_BASE_URL;)
        })

      assert {:refused, report} = FeBundleProbe.scan_dir(dist)
      assert report.file_count == 5

      assert report.counts == %{
               https_auth_token: 1,
               protocol_relative_auth_token: 1,
               localhost_4000: 1,
               unset_vite_platform_rpc_base_url: 1,
               unset_vite_platform_auth_url: 1
             }

      formatted = FeBundleProbe.format_report(report)
      assert formatted =~ "FE_BUNDLE_PROBE REFUSED: 5 finding(s) across 5 asset(s)"
      assert formatted =~ "[https_auth_token]"
      assert formatted =~ "[protocol_relative_auth_token]"
      assert formatted =~ "[localhost_4000]"
      assert formatted =~ "[unset_vite_platform_rpc_base_url]"
      assert formatted =~ "[unset_vite_platform_auth_url]"
    end

    test "fails closed on missing, non-directory, or asset-less targets", %{tmp_dir: tmp_dir} do
      missing = Path.join(tmp_dir, "does_not_exist")
      assert {:error, :enoent} = FeBundleProbe.scan_dir(missing)
      assert {:error, :enoent} = FeBundleProbe.scan_file(missing)

      file_path = Path.join(tmp_dir, "only.txt")
      File.write!(file_path, "hello")
      assert {:error, :not_a_directory} = FeBundleProbe.scan_dir(file_path)

      empty_dir = Path.join(tmp_dir, "empty_dist")
      File.mkdir_p!(empty_dir)
      File.write!(Path.join(empty_dir, "style.css"), "body{}")
      assert {:error, :no_assets} = FeBundleProbe.scan_dir(empty_dir)
      assert {:ok, %{file_count: 0}} = FeBundleProbe.scan_dir(empty_dir, allow_empty: true)
    end

    test "scan_file/2 inspects a single built asset", %{tmp_dir: tmp_dir} do
      js_path = Path.join(tmp_dir, "bundle.js")
      File.write!(js_path, ~s(const rpc="http://localhost:4000";))

      assert {:refused, report} = FeBundleProbe.scan_file(js_path)
      assert report.file_count == 1
      assert report.counts == %{localhost_4000: 1}
    end

    test "optional env check catches missing or blank VITE_PLATFORM_* vars" do
      clean_js = ~s(export const ok = true;)

      assert {:refused, report} =
               FeBundleProbe.scan_content(clean_js,
                 env: %{"VITE_PLATFORM_RPC_BASE_URL" => "   "}
               )

      assert report.counts == %{
               unset_vite_platform_rpc_base_url: 1,
               unset_vite_platform_auth_url: 1
             }

      assert {:ok, _} =
               FeBundleProbe.scan_content(clean_js,
                 env: %{
                   "VITE_PLATFORM_RPC_BASE_URL" => "https://rpc.prod.example.com",
                   "VITE_PLATFORM_AUTH_URL" => "https://auth.prod.example.com"
                 }
               )
    end

    test "snippet slicing stays valid UTF-8 and bounded on minified lines" do
      prefix = String.duplicate("✓—α", 40)
      suffix = String.duplicate("🚀β", 40)
      minified = prefix <> ~S|fetch("https://auth/token")| <> suffix

      assert {:refused, report} = FeBundleProbe.scan_content(minified)
      assert [finding] = report.findings
      assert String.valid?(finding.snippet)
      assert byte_size(finding.snippet) <= 120
      assert finding.snippet =~ "https://auth/token"
    end
  end
end
