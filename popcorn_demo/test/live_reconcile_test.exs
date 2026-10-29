defmodule PopcornDemo.LiveReconcileTest do
  use ExUnit.Case, async: false

  # Chicago-school leg for S10: real substrate (cosmos 8443 + STS 9443),
  # real docs, real feed, real etags, real CAS refusals — no mocks. The
  # monotonic winner round-trip and the typed (never-overwritten) conflict
  # on the REAL wire are the point of the leg.

  alias PopcornDemo.LiveReconcile

  @base "http://127.0.0.1:8443"
  @sts "http://127.0.0.1:9443"
  @tenant "00000000-0000-0000-0000-000000000000"
  @db "popcorn"
  @coll "smoke"
  @ids ["live-reconcile-fresh", "live-reconcile-stale", "live-reconcile-conf"]

  setup do
    purge_all()
    on_exit(fn -> purge_all() end)
    :ok
  end

  describe "run/0 local↔cloud reconcile walk over live substrate" do
    @tag :live_reconcile
    test "returns OK naming all stages" do
      assert {:ok, "reconcile=OK(3-staged,seeded,feed-" <> _rest} = LiveReconcile.run()
    end

    @tag :live_reconcile
    test "monotonic winners round-trip on the real wire" do
      assert {:ok, _} = LiveReconcile.run()

      # fresh id: local (_v 5) beat remote (_v 2) → the pushed winner bytes
      # must be on the wire verbatim.
      assert {:ok, %{status: 200, body: %{"v" => 5, "payload" => "local-new"}}} =
               http(:get, doc_url("live-reconcile-fresh"))

      # stale id: remote (_v 9) beat local (_v 1) → the remote bytes survive.
      assert {:ok, %{status: 200, body: %{"v" => 9, "payload" => "remote-v9"}}} =
               http(:get, doc_url("live-reconcile-stale"))
    end

    @tag :live_reconcile
    test "typed conflict is surfaced and overwrites nothing on the wire" do
      assert {:ok, _} = LiveReconcile.run()

      # The equal-_v divergent-bytes doc keeps its REMOTE bytes (remote-B):
      # typed conflict, never a silent overwrite.
      assert {:ok, %{status: 200, body: %{"v" => 3, "payload" => "remote-B"}}} =
               http(:get, doc_url("live-reconcile-conf"))

      # And the local side of the conflict is still in the store, untouched.
      assert %{_v: 3, payload: "local-A"} = PopcornDemo.Reconcile.stored("live-reconcile-conf")
    end
  end

  # -- Helpers (defensive real-wire purge; each test owns its state) --------

  defp purge_all do
    mint()

    Enum.each(@ids, fn id ->
      case http(:get, doc_url(id)) do
        {:ok, %{status: 200, body: %{"_etag" => etag}}} ->
          http(:delete, doc_url(id), headers: [{"if-match", etag}])

        _ ->
          :ok
      end
    end)

    PopcornDemo.Reconcile.reset()
    :ok
  end

  defp doc_url(id), do: "#{@base}/dbs/#{@db}/colls/#{@coll}/docs/#{id}"

  defp mint do
    body =
      "grant_type=client_credentials&client_id=x&client_secret=y" <>
        "&scope=https://cosmos.azure.com/.default"

    case http(:post, "#{@sts}/#{@tenant}/oauth2/v2.0/token",
            body: body,
            headers: [{"content-type", "application/x-www-form-urlencoded"}]) do
      {:ok, %{status: 200, body: %{"access_token" => tok}}} ->
        Process.put(:lr_test_token, tok)

      _ ->
        :ok
    end

    :ok
  end

  defp http(method, url, opts \\ []) do
    body =
      if method == :get and not Keyword.has_key?(opts, :body),
        do: nil,
        else: Keyword.get(opts, :body, "")

    request = %{
      method: String.upcase(to_string(method)),
      url: url,
      headers: headers_for(Keyword.get(opts, :headers, [])),
      body: body
    }

    request |> PopcornDemo.Transport.Httpc.request() |> decode_body()
  end

  defp decode_body({:ok, %{body: body} = resp}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, %{resp | body: decoded}}
      _ -> {:ok, resp}
    end
  end

  defp decode_body(other), do: other

  defp headers_for(extra) do
    bearer =
      case Process.get(:lr_test_token) do
        nil -> []
        tok -> [{"authorization", "Bearer " <> tok}]
      end

    extra = List.wrap(extra)
    has_ct = Enum.any?(extra, fn {k, _} -> String.downcase(k) == "content-type" end)
    default = if has_ct, do: [], else: [{"content-type", "application/json"}]
    default ++ extra ++ bearer
  end
end
