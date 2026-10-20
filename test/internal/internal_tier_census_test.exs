# Residual internal tier (WO-10): the Non-Duplication guard.
#
# Pure file-read court over test/internal — no application state, no
# subprocesses, no network. Enforces the tier's composition:
#
#   (a) population fence — exactly the six owned files, nothing else;
#   (b) forbidden-token scan (zero expected hits): unaudited pacing
#       outside the poll helper, raw Erlang HTTP clients, ad-hoc HTTP
#       client modules, test-only test-connection helpers, JSON decoders,
#       HTTP-status literals co-occurring with assert on the same line,
#       ARM path literals;
#   (c) observables allowlist — every `Smalt.`-prefixed module reference
#       in the tier must be inside the closed set of lib/ modules this
#       tier is allowed to observe.
#
# A gate that cannot exit 1 is the failure: every scan below is written
# so a violation produces a named, typed failure with file+line.
defmodule InternalTier.CensusTest do
  use ExUnit.Case, async: true

  @dir __DIR__
  @helper "poll_helper.exs"

  @owned_files MapSet.new([
                 "plane_blast_radius_test.exs",
                 "vm_zero_growth_test.exs",
                 "wasm_nif_lifecycle_test.exs",
                 "dets_mirror_recovery_test.exs",
                 "event_hubs_consumer_groups_test.exs",
                 "certificates_kd104_witness_test.exs",
                 "internal_tier_census_test.exs",
                 @helper
               ])

  # Closed observable set (WO-10 contract): the lib/ modules the residual
  # internal tier may reference. Any other reference fails. Longest
  # allowlisted prefix wins (a call like Smalt.Store.insert_new/3 is a
  # Smalt.Store reference).
  @observables MapSet.new([
                 "Smalt.Store",
                 "Smalt.StoreTables",
                 "Smalt.Store.DetsMirror",
                 "Smalt.Planes",
                 "Smalt.Plane.DataSupervisor",
                 "Smalt.Plane.ControlSupervisor",
                 "Smalt.Plane.IntegrationSupervisor",
                 "Smalt.Plane.IdentitySupervisor",
                 "Smalt.AmqpBroker",
                 "Smalt.AmqpBroker.ConnSup",
                 "Smalt.Amqp.QueueStore",
                 "Smalt.Amqp.CbsRouter",
                 "Smalt.Messaging.EventGrid",
                 "Smalt.Messaging.EventHubs",
                 "Smalt.DataPlane.Certificates",
                 "Smalt.Test.Internal.CertificatesKd104WitnessTest",
                 "Smalt.Internal.EventHubsConsumerGroupsTest",
                 "Smalt.Security.LedgerWriter",
                 "Smalt.Affidavit.WasmEngine",
                 "Smalt.Affidavit.WasmEngine.Supervisor",
                 "Smalt.Config"
               ])

  # -- (a) population fence ---------------------------------------------------

  test "population fence: test/internal contains exactly the owned files" do
    on_disk = MapSet.new(File.ls!(@dir))
    assert MapSet.equal?(on_disk, @owned_files),
           "test/internal population drifted: on_disk=#{inspect(MapSet.to_list(on_disk))}"
  end

  # -- (b) forbidden-token scans ------------------------------------------------

  test "no unaudited pacing token outside the audited poll helper" do
    pattern = sleep_pattern()
    violations = scan_all_but_helper(&Regex.match?(pattern, &1))
    assert violations == [], "unaudited pacing outside the helper: #{inspect(violations)}"
  end

  test "no raw HTTP client / test-only conn helpers / JSON decoder tokens" do
    patterns = client_patterns()

    violations =
      scan_all_files(fn line -> Enum.any?(patterns, &Regex.match?(&1, line)) end)

    assert violations == [], "forbidden client tokens: #{inspect(violations)}"
  end

  test "no HTTP status literal co-occurs with assert on the same line" do
    pattern = status_pattern()
    violations = scan_lines_all_files(fn line -> Regex.match?(pattern, line) end)

    assert violations == [], "status-literal asserts: #{inspect(violations)}"
  end

  test "no ARM path literals" do
    violations =
      scan_lines_all_files(fn line ->
        Regex.match?(~r/\/subscriptions\//, line) or Regex.match?(~r/\/providers\//, line)
      end)

    assert violations == [], "ARM path literals: #{inspect(violations)}"
  end

  # -- (c) observables allowlist -------------------------------------------------

  test "every Smalt-prefixed module reference is inside the closed allowlist" do
    violations =
      all_files_with_content()
      |> Enum.flat_map(fn {name, content} ->
        # Strip the tier's own helper namespace before scanning.
        content = String.replace(content, "SmaltTest", " ")

        tokens =
          Regex.scan(~r/Smalt\.[A-Za-z0-9_.]+/, content)
          |> Enum.map(fn [tok] -> tok end)
          |> Enum.map(&longest_allowlisted_prefix/1)

        tokens
        |> Enum.reject(&MapSet.member?(@observables, &1))
        |> Enum.map(&{name, &1})
      end)

    assert violations == [], "off-allowlist module references: #{inspect(violations)}"
  end

  # -- helpers -----------------------------------------------------------------

  # Built from parts so this file's own pattern text never trips the scan
  # (the census file is included in every scan — honest self-scan).
  # All scan patterns are built from concatenated parts so this file's
  # own pattern text and this comment never trip the honest self-scan.
  defp client_patterns do
    [
      Regex.compile!(":" <> "ht" <> "tpc"),
      Regex.compile!("Req" <> "[.]"),
      Regex.compile!("Fin" <> "ch"),
      Regex.compile!("Plug" <> "[.]Te" <> "st"),
      Regex.compile!("Jas" <> "on[.]dec" <> "ode")
    ]
  end

  defp sleep_pattern do
    Regex.compile!("Pro" <> "cess[.]s" <> "leep")
  end

  defp status_pattern do
    # Matches an assert line that carries one of the pinned status codes.
    Regex.compile!(
      "asse" <> "rt[^\\n]*\\b(200|201|204|400|401|403|404|409|412|500|503)\\b"
    )
  end

  defp scan_all_but_helper(pred) do
    for {name, content} <- all_files_with_content(),
        name != @helper,
        line <- lines(content),
        pred.(line),
        do: {name, line}
  end

  defp scan_all_files(pred) do
    for {name, content} <- all_files_with_content(),
        line <- lines(content),
        pred.(line),
        do: {name, line}
  end

  defp scan_lines_all_files(pred) do
    scan_all_files(pred)
  end

  defp lines(content) do
    content |> String.split(["\r\n", "\n"])
  end

  defp all_files_with_content do
    @dir
    |> File.ls!()
    |> Enum.sort()
    |> Map.new(fn name ->
      {name, File.read!(Path.join(@dir, name))}
    end)
  end

  defp longest_allowlisted_prefix(token) do
    @observables
    |> Enum.filter(fn allowed -> String.starts_with?(token, allowed) end)
    |> Enum.max_by(&String.length/1, fn -> "" end)
    |> case do
      "" -> token
      allowed -> allowed
    end
  end
end
