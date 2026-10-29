# guideline_recorded_test.exs — Z2 leg, guideline testing-8 (recorded tests
# pinned per-service api-version, refreshed on service-team notification).
#
# Chicago: the collaborators are the REAL recording file on disk and the REAL
# smalt substrate. The recorded pattern already exists as tooling
# (azurite-spike/recorded/recorder.mjs + recorded-test.mjs +
# recordings/blob-roundtrip.json); this test executable-izes its laws:
#
#   1. recording schema — `recorded-test/v1`, per-tx
#      {name, request{method,url,headers,body}, response{status,headers,body}}
#   2. api-version pin — every recorded request carries
#      `x-ms-version: 2021-12-02` (testing-8's core: the pin is explicit,
#      machine-checked, not folklore)
#   3. replay against the live substrate — every recorded STATUS still matches
#      (smalt honors the recorded contract), with fresh per-run container
#      names via URL substitution (standard replay shape)
#   4. mutation (in-test non-vacuity) — bumping one recorded response status
#      makes the replay assertion FAIL; a replay that cannot fail proves
#      nothing
#
# Context: solo (live substrate leg, host-side :httpc via
# PopcornDemo.Transport.Httpc).

defmodule PopcornDemo.GuidelineRecordedTest do
  use ExUnit.Case, async: false

  alias PopcornDemo.Transport.Httpc

  @recording_path Path.expand("../azurite-spike/recorded/recordings/blob-roundtrip.json", __DIR__)
  @pinned_version "2021-12-02"
  @base "http://127.0.0.1:8443"
  @sts "http://127.0.0.1:9443"
  @tenant "smalt-tenant"

  defp recording,
    do: @recording_path |> File.read!() |> Jason.decode!()

  # -- shared replay engine ----------------------------------------------------
  # Replays every transaction against the live substrate with a fresh
  # per-run container substituted for the recorded one; returns
  # %{pass: n, total: n, failures: [{name, [diff, ...]}]}. Status-only
  # contract (the pinion under test: smalt honors the recorded statuses);
  # recorded Authorization is stale by construction — a fresh bearer is
  # substituted so the replay rides the live token path.

  defp replay(recording) do
    {:ok, token} = token()

    recorded_container = derive_recorded_container(recording)
    container = fresh_container()
    Enum.reduce(recording["transactions"], %{pass: 0, total: 0, failures: []}, fn tx, acc ->
      url = String.replace(tx["request"]["url"], "/" <> recorded_container, "/" <> container)

      headers =
        Enum.flat_map(tx["request"]["headers"] || [], fn {k, v} ->
          if String.downcase(k) == "authorization",
            do: [{"Authorization", "Bearer " <> token}],
            else: [{k, v}]
        end)

      body = tx["request"]["body"] || ""

      {:ok, %{status: status}} = Httpc.request(%{method: tx["request"]["method"], url: url, headers: headers, body: body})

      recorded_status = tx["response"]["status"]

      # Disjunctive law for the delete arms: the delete outcome is
      # environment-dependent (a WORM-locked container answers 409
      # ContainerLocked; a fresh unlocked container answers 202 Accepted —
      # same LiveBlob "-cleaned|-worm-retained" precedent). Either wire
      # outcome honors the recorded contract; neither is masked.
      acceptable =
        if String.starts_with?(tx["name"], "delete-"),
          do: [recorded_status, if(recorded_status == 409, do: 202, else: 409)],
          else: [recorded_status]

      if status in acceptable do
        %{acc | pass: acc.pass + 1, total: acc.total + 1}
      else
        %{
          acc
          | total: acc.total + 1,
            failures: acc.failures ++ [{tx["name"], "status recorded=#{recorded_status} actual=#{status}"}]
        }
      end
    end)
  end

  defp derive_recorded_container(recording) do
    account = recording["account"]
    first_url = recording["transactions"] |> hd() |> get_in(["request", "url"])

    case Regex.run(~r/#{account}\/([^\/?]+)/, first_url) do
      [_, container] -> container
      _ -> flunk("cannot derive recorded container from #{first_url}")
    end
  end

  defp fresh_container,
    do: "z2rec" <> Integer.to_string(System.system_time(:millisecond)) <>
          "-" <> Integer.to_string(:erlang.unique_integer([:positive]))

  defp token do
    req = %{
      method: "POST",
      url: @sts <> "/#{@tenant}/oauth2/v2.0/token",
      headers: [{"content-type", "application/x-www-form-urlencoded"}],
      body: "grant_type=client_credentials&client_id=guideline-recorded&client_secret=not-checked"
    }

    case Httpc.request(req) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"access_token" => tok}} when is_binary(tok) -> {:ok, tok}
          _ -> flunk("STS token response has no access_token")
        end

      {:ok, %{status: st, body: body}} ->
        flunk("STS token mint failed http-#{st}: #{body}")

      {:error, reason} ->
        flunk("STS unreachable (substrate down?) #{inspect(reason)}")
    end
  end

  # -- 1. schema -----------------------------------------------------------------

  describe "recording schema (recorded-test/v1)" do
    test "top-level schema tag, endpoint, account, apiVersion, recordedAt, transactions" do
      rec = recording()

      assert rec["schema"] == "recorded-test/v1"
      assert is_binary(rec["endpoint"]) and rec["endpoint"] != ""
      assert is_binary(rec["account"]) and rec["account"] != ""
      assert rec["apiVersion"] == @pinned_version
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(rec["recordedAt"])
      assert is_list(rec["transactions"]) and rec["transactions"] != []
    end

    test "every transaction has name + full request/response envelope" do
      for tx <- recording()["transactions"] do
        assert is_binary(tx["name"]) and tx["name"] != ""

        assert %{"method" => m, "url" => u} = tx["request"]
        assert m in ["GET", "PUT", "DELETE", "POST", "HEAD"]
        assert u =~ "http://127.0.0.1:8443/"

        assert is_map(tx["request"]["headers"])

        assert %{"status" => s, "headers" => _, "body" => _} = tx["response"]
        assert is_integer(s) and s in 200..599
      end
    end

    test "the six expected blob roundtrip transactions, in order" do
      names = Enum.map(recording()["transactions"], & &1["name"])

      assert names == [
               "create-container",
               "put-blob",
               "get-blob",
               "get-container-properties",
               "delete-blob",
               "delete-container"
             ]
    end
  end

  # -- 2. api-version pin --------------------------------------------------------

  describe "api-version pin (testing-8 core)" do
    test "every recorded request carries x-ms-version: 2021-12-02" do
      for tx <- recording()["transactions"] do
        headers = Map.new(tx["request"]["headers"], fn {k, v} -> {String.downcase(k), v} end)

        assert headers["x-ms-version"] == @pinned_version,
               "transaction #{tx["name"]} missing/incorrect x-ms-version pin: #{inspect(headers["x-ms-version"])}"
      end
    end
  end

  # -- 3. live replay --------------------------------------------------------------

  describe "live replay against smalt (recorded contract honored)" do
    test "every recorded status matches the live substrate" do
      rec = recording()
      # Loud precondition, never a fake pass: the substrate must be up.
      assert rec["endpoint"] == @base
      %{pass: pass, total: total, failures: failures} = replay(rec)

      assert failures == [],
             "replay diverged from recording: #{inspect(failures, limit: :infinity)}"

      assert pass == total and total == length(rec["transactions"])
    end
  end

  # -- 4. mutation (non-vacuity, in-test) -------------------------------------------

  describe "mutation: a bumped recorded status makes the replay fail" do
    test "create-container 201 -> 200 flips the replay to FAIL" do
      rec = recording()

      mutated =
        put_in(rec, ["transactions", Access.at(0), "response", "status"], 200)

      assert mutated != rec

      %{failures: failures} = replay(mutated)

      assert failures != [],
             "mutation non-vacuity violated: replay passed with a corrupted recording"

      assert {"create-container", _} =
               Enum.find(failures, fn {name, _} -> name == "create-container" end)
    end
  end
end
