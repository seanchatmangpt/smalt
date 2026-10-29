defmodule PopcornDemo.LiveTest do
  @moduledoc """
  Chicago-school tests for the live leg over the REAL substrate on 9443.

  Real collaborator: `PopcornDemo.Transport.Httpc` (real :httpc sockets, real
  substrate responses). No mocks. Skips loudly only when the substrate is
  actually down.
  """

  use ExUnit.Case, async: false

  @base "http://127.0.0.1:9443"

  # L1 finding 8: substrate-down must produce a LOUD SKIP, not a confusing
  # raise from setup. ExUnit's supported skip mechanism is the `skip:` tag
  # (truthy tag value => test skipped, tag value becomes the skip reason).
  # Tag values are read at test-module compile time, and `mix test` compiles
  # test modules immediately before running them, so a compile-time probe
  # reflects the substrate state for THIS run.
  @skip_reason "substrate down — run 9>&- just substrate-up"

  probe_url = ~c"http://127.0.0.1:9443/metadata/endpoints"

  substrate_down? =
    try do
      {:ok, _} = Application.ensure_all_started(:inets)

      # mix's boot path is pruned to the dep closure (:inets is NOT an
      # extra_application here), so raw :httpc can fail with
      # ":http_util is not available" — which the rescue below would
      # misreport as substrate-down. Make the inets ebin loadable first.
      root = :code.root_dir() |> List.to_string()

      Enum.each(["crypto-*", "asn1-*", "public_key-*", "inets-*"], fn app ->
        case Path.wildcard(Path.join([root, "lib", app, "ebin"])) do
          [ebin | _] -> Code.append_path(ebin)
          _ -> :ok
        end
      end)


      case :httpc.request(:get, {probe_url, []}, [timeout: 2_000], []) do
        {:ok, {{_, 200, _}, _headers, _body}} -> false
        _ -> true
      end
    rescue
      _ -> true
    catch
      _, _ -> true
  end

  @substrate_skip if(substrate_down?, do: @skip_reason, else: false)

  if substrate_down? do
    IO.puts(:stderr, """
    [popcorn_demo] SKIP: substrate down — run 9>&- just substrate-up
    """)
  end

  @tag skip: @substrate_skip
  test "tokenless GET /subscriptions is refused 401 by the real substrate" do
    # L1 finding 8b: assert on status 401 alone — no weak body clause.
    assert {:ok, %{status: 401}} =
             PopcornDemo.Transport.Httpc.request(%{
               method: "GET",
               url: @base <> "/subscriptions?api-version=2022-12-01"
             })
  end

  @tag skip: @substrate_skip
  test "Httpc transport walks the lawful auth path live=OK" do
    assert {:ok, "endpoints,tenants,sts,subscriptions=" <> n} = PopcornDemo.Live.run()
    assert {count, ""} = Integer.parse(n)
    assert is_integer(count) and count >= 0
  end

  @tag skip: @substrate_skip
  test "tenant id from /tenants is UUID-shaped and value is a non-empty list" do
    {:ok, %{status: 200, body: body}} =
      PopcornDemo.Transport.Httpc.request(%{method: "GET", url: @base <> "/tenants"})

    assert {:ok, %{"value" => value}} = Jason.decode(body)
    assert is_list(value) and value != []

    tid = hd(value)["tenantId"]
    assert is_binary(tid)

    assert Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, tid)
  end

  @tag skip: @substrate_skip
  test "bearer-authed GET /subscriptions returns 200 with list value (real state)" do
    {:ok, %{status: 200, body: tenants_body}} =
      PopcornDemo.Transport.Httpc.request(%{method: "GET", url: @base <> "/tenants"})

    {:ok, %{"value" => [%{"tenantId" => tid} | _]}} = Jason.decode(tenants_body)

    form =
      URI.encode_query(%{
        "grant_type" => "client_credentials",
        "client_id" => "popcorn-demo",
        "client_secret" => "popcorn-demo"
      })

    {:ok, %{status: 200, body: token_body}} =
      PopcornDemo.Transport.Httpc.request(%{
        method: "POST",
        url: @base <> "/" <> tid <> "/oauth2/v2.0/token",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: form
      })

    assert {:ok, %{"access_token" => token}} = Jason.decode(token_body)
    assert is_binary(token) and byte_size(token) > 0

    {:ok, %{status: 200, body: subs_body}} =
      PopcornDemo.Transport.Httpc.request(%{
        method: "GET",
        url: @base <> "/subscriptions?api-version=2022-12-01",
        headers: [{"authorization", "Bearer " <> token}]
      })

    assert {:ok, %{"value" => subs}} = Jason.decode(subs_body)
    assert is_list(subs)
  end

  @tag skip: @substrate_skip
  test "Httpc transport hard-refuses non-loopback hosts" do
    assert {:error, {:httpc_refused, _}} =
             PopcornDemo.Transport.Httpc.request(%{method: "GET", url: "http://example.com/"})
  end

  # Receipt hygiene (ERCC-R9): a JWT-shaped substring embedded in a FAIL
  # reason is redacted and the fragment is capped — a hardcoded fake token,
  # asserted on real output of the pure format/1 (no mock, no substrate).
  test "format/1 redacts JWT-shaped strings and caps the fragment" do
    fake_jwt =
      "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJwb3Bjb3JuLWRlbW8ifQ.f4ke-s1gn4tur3-v4lue"

    fragment = PopcornDemo.Live.format({:fail, "sts:status=500 body=" <> fake_jwt})

    assert String.starts_with?(fragment, "live=FAIL(")
    refute fragment =~ fake_jwt
    refute Regex.match?(~r/eyJ[A-Za-z0-9_-]{10,}/, fragment)
    assert fragment =~ "eyJ<redacted>"
    assert String.length(fragment) <= String.length("live=FAIL(") + 120
  end

  test "format/1 redacts JWT in skip reasons too" do
    fake_jwt = "eyJhbGciOiJIUzI1NiJ9.tok.tok"

    fragment =
      PopcornDemo.Live.format(
        {:skip, {:substrate_down, "weird gateway said " <> fake_jwt}}
      )

    refute fragment =~ "eyJhbGciOiJIUzI1NiJ9"
    assert fragment =~ "eyJ<redacted>"
    assert String.starts_with?(fragment, "live=SKIP(")
  end
end
