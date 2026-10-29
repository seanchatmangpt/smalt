defmodule PopcornDemo.Smoke do
  @moduledoc """
  End-to-end smoke for the pure smalt slice inside the Popcorn VM.

  Three real smalt layers, no servers, no NIFs:
    1. `Smalt.CosmosSql` — parse + evaluate a Cosmos SQL query over docs
    2. `Smalt.SbRules` — compile + evaluate a Service Bus SQL rule filter
    3. `Smalt.Registry` — admitted-type registry lookups
  """

  require Logger

  def run do
    results = [cosmos_sql(), sb_rule(), registry()]
    message = format(results)

    Logger.info("smalt-on-popcorn smoke: #{message}")

    browser? = Code.ensure_loaded?(Popcorn.JS) and function_exported?(Popcorn.JS, :run!, 2)

    if browser?, do: report(message)

    message
  end

  @doc "Writes a receipt string into the page's #status element (browser only)."
  def report(message) do
    js =
      """
      () => {
        const el = document.querySelector("#status");
        if (el) el.textContent = #{Jason.encode!(message)};
        return "done";
      }
      """
      |> String.trim()

    Popcorn.JS.run!(js)
  end

  defp format(results) do
    Enum.map_join(results, "; ", fn
      {:ok, label, detail} -> label <> "=OK(" <> detail <> ")"
      {:error, label, detail} -> label <> "=FAIL(" <> detail <> ")"
    end)
  end

  defp cosmos_sql do
    query =
      "SELECT c.name FROM c WHERE c.kind = @kind AND c.size > 10 ORDER BY c.name ASC LIMIT 5"

    docs = [
      %{"kind" => "app", "size" => 42, "name" => "beta"},
      %{"kind" => "app", "size" => 8, "name" => "alpha"}
    ]

    case Smalt.CosmosSql.run(query, docs, %{"kind" => "app"}) do
      {:ok, rows} ->
        names = Enum.map(rows, & &1["name"])

        if names == ["beta"] do
          ok("cosmos_sql", "where+order+limit correct")
        else
          fail("cosmos_sql", "rows=" <> inspect(names))
        end

      {:error, reason} ->
        fail("cosmos_sql", inspect(reason))
    end
  end

  defp sb_rule do
    props = %{"sqlExpression" => "sys.label = 'orders' AND priority = 7"}
    msg = [label: "orders", app_props: %{"priority" => 7}]

    with {:ok, {:sql_ast, ast}} <- Smalt.SbRules.compile(props) do
      if Smalt.SbRules.filter_matches_for_test?(ast, msg) do
        ok("sb_rule", "sql filter matched")
      else
        fail("sb_rule", "no match")
      end
    else
      {:error, code, fragment} -> fail("sb_rule", inspect(code) <> " " <> inspect(fragment))
      {:error, code} -> fail("sb_rule", inspect(code))
    end
  end

  defp registry do
    ok1 = Smalt.Registry.admitted?("Microsoft.App/containerApps")
    ok2 = Smalt.Registry.admitted_version?("Microsoft.Storage/storageAccounts", "2021-04-01")

    if ok1 and ok2 do
      ok("registry", "admitted-type + api-version checks pass")
    else
      fail("registry", "admitted?=" <> inspect(ok1) <> " version?=" <> inspect(ok2))
    end
  end

  defp ok(label, detail), do: {:ok, label, detail}
  defp fail(label, detail), do: {:error, label, PopcornDemo.Redact.fragment(detail)}
end
