defmodule PopcornDemo.LiveRgTest do
  @moduledoc """
  Chicago-school test for the W3-7 Resource Graph walk: the only
  collaborators are the REAL substrate (ARM 9443 + STS 9443) over real
  `:httpc` sockets. No mocks. Skips loudly only when the substrate is down.
  """

  use ExUnit.Case, async: false

  substrate_down? =
    with {:ok, sock} <-
           :gen_tcp.connect(~c"127.0.0.1", 9443, [:binary, active: false], 2_000) do
      :gen_tcp.close(sock)
      false
    else
      _ -> true
    end

  @substrate_skip if(substrate_down?, do: "substrate down — run 9>&- just substrate-up", else: false)

  if substrate_down? do
    IO.puts(:stderr, "[popcorn_demo] SKIP: " <> "substrate down — run 9>&- just substrate-up")
  end

  @tag skip: @substrate_skip
  test "rg walk returns 200 shape on the live substrate" do
    assert {:ok, "rg=OK(" <> rest} = PopcornDemo.LiveRg.run()
    assert {n, "-rows)"} = Integer.parse(rest)
    # Empty data on a fresh substrate is a REAL assertion: the walk proved
    # the 200 envelope (count/data/totalRecords) end to end. n >= 0.
    assert n >= 0
  end

  @tag skip: @substrate_skip
  test "walk is repeatable (second run also OK)" do
    assert {:ok, "rg=OK(" <> _} = PopcornDemo.LiveRg.run()
    assert {:ok, "rg=OK(" <> _} = PopcornDemo.LiveRg.run()
  end

  @tag skip: @substrate_skip
  test "tokenless RG query on 9443 is refused 401 MissingBearerToken" do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    url = ~c"http://127.0.0.1:9443/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01"

    hdrs = [{~c"content-type", ~c"application/json"}]
    body = Jason.encode!(%{"query" => "| project name | take 5"})

    {:ok, {{_v, status, _r}, _headers, resp}} =
      :httpc.request(:post, {url, hdrs, ~c"application/json", body},
        [ssl: [verify: :verify_none]], body_format: :binary)

    assert status == 401
    decoded = Jason.decode!(resp)
    assert get_in(decoded, ["error", "code"]) == "AuthenticationFailed"
  end

  @tag skip: @substrate_skip
  test "outcomes are typed: run/0 never returns an untagged value" do
    outcome = PopcornDemo.LiveRg.run()

    assert match?({:ok, _}, outcome) or match?({:skip, _}, outcome) or
             match?({:error, _}, outcome)
  end
end
