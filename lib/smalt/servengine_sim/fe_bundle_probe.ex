defmodule Smalt.ServengineSim.FeBundleProbe do
  @moduledoc """
  Scans built Vite JS/HTML bundle assets for broken endpoint / env-wiring
  regressions before serving or packaging:

    * `https://auth/token` (empty host interpolated into `https://${host}/auth/token`)
    * `//auth/token` (protocol-relative fallback from empty auth base URL)
    * `localhost:4000` (hardcoded dev backend URL leaked into build output)
    * unset `VITE_PLATFORM_RPC_BASE_URL` (unreplaced `import.meta.env`,
      template placeholder, or empty/`null`/`undefined`/`void 0` binding)
    * unset `VITE_PLATFORM_AUTH_URL` (same)

  Returns `{:ok, report}` when clean and `{:refused, report}` when any finding
  is observed. Missing/unreadable targets or directories with no JS/HTML assets
  return `{:error, reason}` rather than passing vacuously.
  """

  @asset_extensions ~w(.js .mjs .cjs .html .htm)

  @type finding_kind ::
          :https_auth_token
          | :protocol_relative_auth_token
          | :localhost_4000
          | :unset_vite_platform_rpc_base_url
          | :unset_vite_platform_auth_url

  @type finding :: %{
          kind: finding_kind(),
          pattern: String.t(),
          file: String.t(),
          line: pos_integer(),
          column: pos_integer(),
          match: String.t(),
          snippet: String.t()
        }

  @type report :: %{
          status: :ok | :refused,
          root: String.t() | nil,
          files_scanned: [String.t()],
          file_count: non_neg_integer(),
          findings: [finding()],
          counts: %{optional(finding_kind()) => non_neg_integer()}
        }

  @https_auth_token_re ~r/https:\/\/auth\/token/
  # Avoid double-counting `https://auth/token` as `//auth/token`, while still
  # catching `"//auth/token"`, `'//auth/token'`, and `https://host//auth/token`.
  @protocol_relative_auth_token_re ~r/(?<![A-Za-z0-9+.-]:)\/\/auth\/token/
  @localhost_4000_re ~r/localhost:4000(?![0-9])/

  unset_env_regex = fn var_name ->
    v = Regex.escape(var_name)

    [
      ~S/(?:import\.meta|process)\.env(?:\?\.|\.)<<VAR>>\b/,
      ~S/(?:import\.meta|process)\.env(?:\?\.)?\[\s*["']<<VAR>>["']\s*\]/,
      ~S/%<<VAR>>%/,
      ~S/\$\{<<VAR>>\}/,
      ~S/\{\{\s*<<VAR>>\s*\}\}/,
      ~S/__<<VAR>>__/,
      ~S/["']?<<VAR>>["']?\s*(?::|=)\s*(?:"\s*"|'\s*'|`\s*`|null\b|undefined\b|void\s+0\b|void\s*\(\s*0\s*\)|"undefined"|'undefined'|"null"|'null')/,
      ~S/<meta\b[^>]*\bname=["']<<VAR>>["'][^>]*\bcontent=["']\s*["'][^>]*>/,
      ~S/<meta\b[^>]*\bcontent=["']\s*["'][^>]*\bname=["']<<VAR>>["'][^>]*>/
    ]
    |> Enum.map(&String.replace(&1, "<<VAR>>", v))
    |> Enum.join("|")
    |> Regex.compile!()
  end

  @rules [
    {:https_auth_token, "https://auth/token", @https_auth_token_re},
    {:protocol_relative_auth_token, "//auth/token", @protocol_relative_auth_token_re},
    {:localhost_4000, "localhost:4000", @localhost_4000_re},
    {:unset_vite_platform_rpc_base_url, "unset VITE_PLATFORM_RPC_BASE_URL",
     unset_env_regex.("VITE_PLATFORM_RPC_BASE_URL")},
    {:unset_vite_platform_auth_url, "unset VITE_PLATFORM_AUTH_URL",
     unset_env_regex.("VITE_PLATFORM_AUTH_URL")}
  ]

  @env_checks [
    {"VITE_PLATFORM_RPC_BASE_URL", :unset_vite_platform_rpc_base_url,
     "unset VITE_PLATFORM_RPC_BASE_URL"},
    {"VITE_PLATFORM_AUTH_URL", :unset_vite_platform_auth_url, "unset VITE_PLATFORM_AUTH_URL"}
  ]

  @doc "All finding kinds emitted by this probe."
  @spec finding_kinds() :: [finding_kind()]
  def finding_kinds do
    Enum.map(@rules, &elem(&1, 0))
  end

  @doc "Returns true when `path` is a built Vite JS or HTML asset."
  @spec vite_asset?(Path.t()) :: boolean()
  def vite_asset?(path) when is_binary(path) do
    String.downcase(Path.extname(path)) in @asset_extensions
  end

  @doc """
  Recursively scans built Vite JS/HTML files under `dir`.

  Options:
    * `:allow_empty` - when `true`, an asset-less directory returns `{:ok, report}`
      instead of `{:error, :no_assets}` (default `false`).
    * `:env` - optional map of build/runtime environment variables to also check
      for missing or blank `VITE_PLATFORM_RPC_BASE_URL` and `VITE_PLATFORM_AUTH_URL`.
  """
  @spec scan_dir(Path.t(), keyword()) :: {:ok, report()} | {:refused, report()} | {:error, atom()}
  def scan_dir(dir, opts \\ []) when is_binary(dir) do
    cond do
      not File.exists?(dir) ->
        {:error, :enoent}

      not File.dir?(dir) ->
        {:error, :not_a_directory}

      true ->
        files = collect_assets(dir)

        if files == [] and not Keyword.get(opts, :allow_empty, false) do
          {:error, :no_assets}
        else
          file_findings =
            Enum.flat_map(files, fn path ->
              rel = Path.relative_to(path, dir)
              content = File.read!(path)
              find_in_content(content, rel)
            end)

          findings = file_findings ++ env_findings(Keyword.get(opts, :env))

          dir
          |> build_report(Enum.map(files, &Path.relative_to(&1, dir)), findings)
          |> report_tuple()
        end
    end
  end

  @doc "Scans a single built Vite JS/HTML file."
  @spec scan_file(Path.t(), keyword()) ::
          {:ok, report()} | {:refused, report()} | {:error, atom()}
  def scan_file(path, opts \\ []) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        findings = find_in_content(content, path) ++ env_findings(Keyword.get(opts, :env))
        build_report(Path.dirname(path), [path], findings) |> report_tuple()

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Scans in-memory JS or HTML asset content."
  @spec scan_content(binary(), keyword()) :: {:ok, report()} | {:refused, report()}
  def scan_content(content, opts \\ []) when is_binary(content) do
    file = Keyword.get(opts, :file, "<memory>")
    findings = find_in_content(content, file) ++ env_findings(Keyword.get(opts, :env))
    build_report(nil, [file], findings) |> report_tuple()
  end

  @doc "Formats a human-readable summary of a probe report."
  @spec format_report(report()) :: String.t()
  def format_report(%{status: :ok, file_count: count}) do
    "FE_BUNDLE_PROBE OK: #{count} asset(s) scanned, 0 findings"
  end

  def format_report(%{status: :refused, file_count: count, findings: findings}) do
    lines =
      Enum.map(findings, fn f ->
        "  - [#{f.kind}] #{f.file}:#{f.line}:#{f.column} matched #{inspect(f.match)} (#{f.snippet})"
      end)

    Enum.join(
      [
        "FE_BUNDLE_PROBE REFUSED: #{length(findings)} finding(s) across #{count} asset(s)"
        | lines
      ],
      "\n"
    )
  end

  # -- internals ---------------------------------------------------------------

  defp collect_assets(dir) do
    dir
    |> walk_files()
    |> Enum.filter(&vite_asset?/1)
    |> Enum.sort()
  end

  defp walk_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          full = Path.join(dir, entry)

          cond do
            File.dir?(full) -> walk_files(full)
            File.regular?(full) -> [full]
            true -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp find_in_content(content, file) do
    @rules
    |> Enum.flat_map(fn {kind, pattern_label, regex} ->
      Regex.scan(regex, content, return: :index)
      |> Enum.map(fn [{offset, len} | _] ->
        {line, column} = line_col(content, offset)

        %{
          kind: kind,
          pattern: pattern_label,
          file: file,
          line: line,
          column: column,
          match: binary_part(content, offset, len),
          snippet: bounded_snippet(content, offset, len)
        }
      end)
    end)
    |> Enum.sort_by(&{&1.line, &1.column, &1.kind})
  end

  defp env_findings(nil), do: []

  defp env_findings(env) when is_map(env) do
    Enum.flat_map(@env_checks, fn {var_name, kind, pattern_label} ->
      val = Map.get(env, var_name)

      if is_binary(val) and String.trim(val) != "" do
        []
      else
        [
          %{
            kind: kind,
            pattern: pattern_label,
            file: "<env>",
            line: 1,
            column: 1,
            match: "#{var_name}=#{inspect(val)}",
            snippet: "#{var_name} is unset or empty"
          }
        ]
      end
    end)
  end

  defp line_col(content, offset) do
    prefix = binary_part(content, 0, offset)
    lines = :binary.matches(prefix, "\n")
    line = length(lines) + 1

    col =
      case List.last(lines) do
        nil -> offset + 1
        {nl_pos, 1} -> offset - nl_pos
      end

    {line, col}
  end

  defp bounded_snippet(content, offset, len) do
    total = byte_size(content)
    start_pos = max(0, offset - 32)
    end_pos = min(total, offset + len + 32)

    content
    |> binary_part(start_pos, end_pos - start_pos)
    |> valid_utf8_slice()
    |> String.replace(~r/[\r\n\t]+/, " ")
  end

  defp valid_utf8_slice(bin) do
    bin
    |> String.chunk(:valid)
    |> Enum.filter(&String.valid?/1)
    |> Enum.join()
  end

  defp build_report(root, files_scanned, findings) do
    counts =
      Enum.reduce(findings, %{}, fn %{kind: kind}, acc ->
        Map.update(acc, kind, 1, &(&1 + 1))
      end)

    %{
      status: if(findings == [], do: :ok, else: :refused),
      root: root,
      files_scanned: files_scanned,
      file_count: length(files_scanned),
      findings: findings,
      counts: counts
    }
  end

  defp report_tuple(%{status: :ok} = report), do: {:ok, report}
  defp report_tuple(%{status: :refused} = report), do: {:refused, report}
end
