# RG404 lane (v26.10.20): in-process Chicago court for the T21 typed finding —
# under a 128-wide ARM ramp, ~1/512 RG DELETE cycles got 404 on the FINAL
# DELETE though the RG existed through its own PUT/GET + child steps
# (docs/jira/v26.10.20/receipts/scvd-t21-arm-ramp.md). Hypotheses:
#   (a) lost ETS write under concurrent insert
#   (b) account-keyed lookup race
#   (c) client-side artifact (transport-retry re-sending an executed DELETE)
# This court removes the TLS-twin/HTTP2 transport entirely: real HTTP/1.1
# loopback against the real ArmGateway.Router + real Smalt.Store (anonymous
# test boot, ephemeral arm_port), 256-wide Task.async_stream, unique run-stamped
# names, every cycle asserting its own RG's final DELETE is 2xx. If the
# server-side state machine loses writes under concurrency, this reproduces;
# if it is clean here, the finding lives in the retried-DELETE client path
# (hypothesis c).
#
# Chicago discipline: real transport, real store, no mocks, no sleeps
# (bounded Task.async_stream timeout — a hang is a typed exit).
#
# Context: solo (internal tier, in-process wire faces).

defmodule Smalt.Test.Internal.Rg404ConcurrentLifecycleCourtTest do
  use ExUnit.Case, async: false

  @sub "00000000-0000-0000-0000-000000000000"
  @api "2021-04-01"
  @width 256
  @cycles_per_worker 2
  @op_timeout 30_000

  setup do
    case GenServer.start_link(Smalt.Store, []) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Loopback client for the real ARM face. inets/ssl are idempotent starts.
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    :ok
  end

  test "256-wide concurrent RG lifecycle: every cycle's final DELETE sees its own RG" do
    base = "http://127.0.0.1:#{Application.get_env(:smalt, :arm_port)}"
    run = Integer.to_string(System.system_time(:millisecond), 36)

    results =
      1..@width
      |> Task.async_stream(
        fn w ->
          results =
            for c <- 1..@cycles_per_worker do
              rg = "rg404-#{run}-#{w}-#{c}"
              acct = "rg404a#{run}#{w}#{c}"
              rg_path = "/subscriptions/#{@sub}/resourcegroups/#{rg}?api-version=#{@api}"

              res_path =
                "/subscriptions/#{@sub}/resourceGroups/#{rg}/providers/Microsoft.Storage/storageAccounts/#{acct}?api-version=#{@api}"

              steps = [
                {"PUT", rg_path, Jason.encode!(%{"location" => "eastus", "tags" => %{"lane" => "rg404"}})},
                {"GET", rg_path, nil},
                {"PUT", res_path,
                 Jason.encode!(%{
                   "location" => "eastus",
                   "kind" => "StorageV2",
                   "sku" => %{"name" => "Standard_LRS", "tier" => "Standard"}
                 })},
                {"GET", res_path, nil},
                {"DELETE", res_path, nil},
                {"DELETE", rg_path, nil}
              ]

              statuses =
                for {m, p, body} <- steps do
                  http_req(m, base <> p, body)
                end

              bad =
                steps
                |> Enum.zip(statuses)
                |> Enum.filter(fn {_, r} ->
                  case r do
                    {st, _} when is_integer(st) -> st < 200 or st >= 300
                    _ -> true
                  end
                end)

              if bad == [] do
                :ok
              else
                # Forensic probe: is the RG visible right after the failure?
                {fst, _} = http_req("GET", base <> rg_path_from(rg_path), nil)
                {:fail, rg, Enum.map(bad, fn {m, p, _} -> "#{m} #{Path.basename(p)} -> #{inspect(fst)} end" end),
                 Enum.map(statuses, fn {st, _} -> st end)}
              end
            end

          results
        end,
        max_concurrency: @width,
        timeout: @op_timeout * @cycles_per_worker
      )
      |> Enum.flat_map(fn
        {:ok, rs} -> rs
        {:exit, r} -> [{:exit, inspect(r)}]
      end)

    failures = Enum.filter(results, &(&1 != :ok))
    total = length(results)
    IO.puts("RG404 court: #{total} cycles, #{length(failures)} failures")

    Enum.each(Enum.take(failures, 5), fn f -> IO.puts("  FAIL: #{inspect(f, limit: 300)}") end)

    assert failures == [], "RG404 court found #{length(failures)}/#{total} failing cycles"
  end

  defp rg_path_from(rg_path), do: rg_path

  # Returns {status, body}. 5s per-request timeout so a hung request is a
  # typed value, not a stuck suite.
  defp http_req(method, url, body) do
    headers = []
    req = String.to_charlist(url)

    http_opts = [timeout: 20_000, autoredirect: false]

    opts =
      case method do
        "GET" -> [body_format: :binary]
        _ -> [body_format: :binary]
      end

    res =
      case method do
        "GET" -> :httpc.request(:get, {req, headers}, http_opts, opts)
        "PUT" -> :httpc.request(:put, {req, headers, ~c"application/json", body}, http_opts, opts)
        "DELETE" -> :httpc.request(:delete, {req, headers}, http_opts, opts)
      end

    case res do
      {:ok, {{_v, status, _phrase}, _hdrs, body}} ->
        {status, body}

      {:error, r} ->
        {:transport_error, inspect(r)}
    end
  end
end
