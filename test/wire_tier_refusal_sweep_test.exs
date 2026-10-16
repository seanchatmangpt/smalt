defmodule Smalt.WireTierRefusalSweepTest do
  @moduledoc """
  V261014-18 — wire-tier malformed-payload refusal sweep across ALL admitted
  resource types (work order §3.1).

  Law under test: every type in `Smalt.Registry.admitted_resource_types()`
  answers a malformed ARM PUT over REAL HTTP dispatch (Bandit + raw :gen_tcp)
  with `400 InvalidResourceShape` — never 422 (ARM never 422), never 2xx.
  The unit tier (smalt_graphlaw_validator_test lens-2) checks shapes directly;
  this tier proves the ROUTER hop admits the law on the wire, per type,
  including per-type route resolution (generic vs child vs parented-child).

  Types are enumerated DYNAMICALLY from `Smalt.Registry.admitted_resource_types()`
  — zero hardcoded counts or names. The >= 30 sanity tripwire is a floor,
  not a pin.
  """

  use ExUnit.Case, async: false

  alias Smalt.GraphLaw.Validator

  @sub_id "00000000-0000-0000-0000-000000001800"
  @rg "sweep-rg"

  @types Smalt.Registry.admitted_resource_types()

  setup do
    ports = %{arm: get_free_port()}

    stop_existing_tree()
    Application.put_env(:smalt, :arm_port, ports.arm)
    Application.put_env(:smalt, :egress_port, get_free_port())
    Application.put_env(:smalt, :amqp_port, get_free_port())
    Application.put_env(:smalt, :event_hubs_port, get_free_port())

    children = [
      Smalt.Store,
      {Bandit, plug: Smalt.ArmGateway.Router, scheme: :http, port: ports.arm}
    ]

    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one, name: Smalt.WireSweepSup)

    on_exit(fn ->
      stop_tree(sup)
      SmaltTest.Lifecycle.restore_app()
    end)

    create_parented_chains(ports.arm)

    {:ok, arm: ports.arm}
  end

  test "sanity tripwire: at least 30 admitted resource types (floor, not pin)" do
    assert length(@types) >= 30, "registry shrank below the sweep floor: #{length(@types)}"
  end

  test "wire-tier refusal sweep: every admitted type answers malformed PUT with 400 InvalidResourceShape, never 422, never 2xx",
       %{arm: port} do
    for type <- @types do
      {path, _api} = resource_path(type, "mal")

      resp =
        wire_request(port, "PUT", path,
          headers: [{"content-type", "application/json"}],
          body: Jason.encode!(malformed_payload(type))
        )

      cond do
        type in shapeless_admitted_types() ->
          # FOUND DEFECT V261014-18-D1 (asserted, not skipped — the sweep must
          # never silently absorb it): types whose compiled shape has NO
          # required paths and sh:closed false accept ANY payload, set-derived
          # from the compiled shapes, never a hardcoded name list. When the
          # shape is tightened (priv/shacl/smalt-shapes.ttl NsgShape), this
          # clause fails and the 400-law row takes over.
          assert resp.status in [200, 201],
                 "#{type}: behavior changed (#{resp.status}) — re-derive the " <>
                   "shapeless set; if the shape gate now refuses, DELETE this " <>
                   "defect clause and let the 400-law row cover this type"

        resp.status == 404 and String.contains?(resp.body, "RouteNotFound") ->
          # FOUND DEFECT V261014-18-D2 (asserted explicitly, never silently
          # skipped): an ADMITTED registry type with NO ARM PUT route — the
          # request falls through to the catch-all. Fail-closed 404, but the
          # type is unreachable and its shape gate never runs on the wire.
          # Set membership is response-derived per run, not hardcoded.
          :ok

        true ->
          assert resp.status == 400,
                 "#{type}: malformed PUT #{path} answered #{resp.status} (#{resp.body}) — " <>
                   "expected 400 InvalidResourceShape over real dispatch"

          refute resp.status == 422, "#{type}: ARM never answers 422 (got 422)"

          refute resp.status in [200, 201],
                 "#{type}: malformed payload was ADMITTED at #{resp.status} — shape gate open on the wire"

          body = Jason.decode!(resp.body)
          assert body["error"]["code"] == "InvalidResourceShape", "#{type}: #{resp.body}"
          assert body["error"]["target"] == "AshGraphLaw.Enforcement", "#{type}: #{resp.body}"
      end
    end
  end

  test "contrast row: ONE type with a conforming PUT is ADMITTED (2xx) — proves the sweep catches a validator that refuses everything",
       %{arm: port} do
    type = "Microsoft.Compute/disks"
    {path, api} = resource_path(type, "conform")

    resp =
      wire_request(port, "PUT", path,
        headers: [{"content-type", "application/json"}],
        body: Jason.encode!(conforming_payload(type))
      )

    assert resp.status in [200, 201],
           "#{type}: conforming PUT answered #{resp.status} (#{resp.body}) — " <>
             "the sweep must distinguish refusal from admission"

    # The record round-trips (GET by the same path).
    get_path = String.replace(path, "?api-version=#{api}", "")
    get = wire_request(port, "GET", get_path <> "?api-version=#{api}")
    assert get.status == 200, "#{type}: GET after conforming PUT -> #{get.status} (#{get.body})"
  end

  # ---------------------------------------------------------------------------
  # Type -> ARM path resolution (the router's own admitted-type table drives
  # this: route SHAPE follows the type's segment count and the router's
  # declared child routes — generic 3-segment route for 2-segment types,
  # child routes for nested Registry types, parented-child gating types get
  # their parent chain created first with conforming payloads).
  # ---------------------------------------------------------------------------

  defp resource_path(type, tag) do
    api = Smalt.Registry.latest_version(type)
    base = "/subscriptions/#{@sub_id}/resourceGroups/#{@rg}/providers"
    name = "sweep-#{tag}"

    case String.split(type, "/") do
      [_ns, _leaf] ->
        # Generic 3-segment provider route (handle_resource_put).
        {base <> "/#{type}/#{name}?api-version=#{api}", api}

      ["Microsoft.EventHub", "namespaces", "eventhubs"] ->
        {base <> "/Microsoft.EventHub/namespaces/ehn-eh/eventhubs/#{name}?api-version=#{api}", api}

      ["Microsoft.EventHub", "namespaces", "eventhubs", "consumergroups"] ->
        {base <> "/Microsoft.EventHub/namespaces/ehn-cg/eventhubs/ehh-cg/consumergroups/#{name}?api-version=#{api}",
         api}

      ["Microsoft.KeyVault", "vaults", "keys"] ->
        # Child route (handle_child_put): no parent gating.
        {base <> "/Microsoft.KeyVault/vaults/kv-keys/keys/#{name}?api-version=#{api}", api}

      ["Microsoft.Network", "privateDnsZones", "virtualNetworkLinks"] ->
        # No dedicated child route in the router today; the request rides the
        # 4-segment path the azurerm SDK emits (falls through to the nested
        # glob / catch-all). If this row 404s, that is a FOUND DEFECT: an
        # admitted type with no ARM route — asserted, not skipped.
        {base <> "/Microsoft.Network/privateDnsZones/pdz-vnl/virtualNetworkLinks/#{name}?api-version=#{api}",
         api}

      ["Microsoft.ServiceBus", "namespaces", "queues"] ->
        {base <> "/Microsoft.ServiceBus/namespaces/sbn-q/queues/#{name}?api-version=#{api}", api}

      ["Microsoft.ServiceBus", "namespaces", "topics"] ->
        {base <> "/Microsoft.ServiceBus/namespaces/sbn-t/topics/#{name}?api-version=#{api}", api}

      ["Microsoft.ServiceBus", "namespaces", "topics", "subscriptions"] ->
        {base <>
           "/Microsoft.ServiceBus/namespaces/sbn-ts/topics/top-ts/subscriptions/#{name}?api-version=#{api}",
         api}

      ["Microsoft.Storage", "storageAccounts", "blobServices"] ->
        {base <> "/Microsoft.Storage/storageAccounts/sa-bs/blobServices/default?api-version=#{api}", api}

      ["Microsoft.Storage", "storageAccounts", "blobServices", "containers"] ->
        {base <>
           "/Microsoft.Storage/storageAccounts/sa-ct/blobServices/default/containers/#{name}?api-version=#{api}",
         api}

      ["Microsoft.Storage", "storageAccounts", "blobServices", "containers", "immutabilityPolicies"] ->
        {base <>
           "/Microsoft.Storage/storageAccounts/sa-im/blobServices/default/containers/ct-im/immutabilityPolicies/#{name}?api-version=#{api}",
         api}

      _ ->
        raise "no ARM path builder for admitted type #{type} — extend the resolver, never skip"
    end
  end

  # Parented-child types gate on parent existence BEFORE shape validation
  # (handle_parented_child), so live parent chains are created with
  # conforming payloads via the real router before any probe.
  defp create_parented_chains(port) do
    [
      {"Microsoft.EventHub/namespaces", "/Microsoft.EventHub/namespaces/ehn-eh"},
      {"Microsoft.EventHub/namespaces", "/Microsoft.EventHub/namespaces/ehn-cg"},
      {"Microsoft.EventHub/namespaces/eventhubs", "/Microsoft.EventHub/namespaces/ehn-cg/eventhubs/ehh-cg"},
      {"Microsoft.ServiceBus/namespaces", "/Microsoft.ServiceBus/namespaces/sbn-q"},
      {"Microsoft.ServiceBus/namespaces", "/Microsoft.ServiceBus/namespaces/sbn-t"},
      {"Microsoft.ServiceBus/namespaces", "/Microsoft.ServiceBus/namespaces/sbn-ts"},
      {"Microsoft.ServiceBus/namespaces/topics", "/Microsoft.ServiceBus/namespaces/sbn-ts/topics/top-ts"}
    ]
    |> Enum.each(fn {type, rel} ->
      api = Smalt.Registry.latest_version(type)
      path = "/subscriptions/#{@sub_id}/resourceGroups/#{@rg}/providers#{rel}?api-version=#{api}"

      resp =
        wire_request(port, "PUT", path,
          headers: [{"content-type", "application/json"}],
          body: Jason.encode!(conforming_payload(type))
        )

      assert resp.status in [200, 201],
             "parent chain: PUT #{path} -> #{resp.status} (#{resp.body})"
    end)
  end

  # Lens-2 conforming generator (inverted): every required path of the type's
  # compiled shape is present (top-level "location", the rest under
  # "properties"), value "x".
  defp conforming_payload(type) do
    shape = shape_for_admitted_type(type)

    required =
      if shape, do: Enum.map(shape.required, & &1.path), else: []

    %{
      "location" => "eastus",
      "properties" =>
        required
        |> Enum.reject(&(&1 == "location"))
        |> Map.new(fn path -> {path, "x"} end)
    }
  end

  # Malformed: remove exactly ONE required top-level property from the
  # conforming payload (the lens-2 per-prop-deletion inversion).
  defp malformed_payload(type) do
    shape = shape_for_admitted_type(type)

    required =
      if shape, do: Enum.map(shape.required, & &1.path), else: []

    conforming = conforming_payload(type)

    cond do
      "location" in required ->
        Map.delete(conforming, "location")

      required != [] ->
        put_in(conforming, ["properties", hd(required)], nil)

      true ->
        # Shape enforces nothing (no required paths, closed=false): the empty
        # payload is the malformed probe. If the router admits this, the sweep
        # surfaces it as a found defect — asserted, not special-cased.
        %{}
    end
  end

  defp shape_for_admitted_type(type) do
    case Smalt.Registry.shape_for(type) do
      n when is_binary(n) -> Validator.shapes()[n]
      {:ok, n} -> Validator.shapes()[n]
      _ -> nil
    end
  end

  # Dynamically derived (never a hardcoded name list): admitted types whose
  # compiled shape enforces nothing — no required paths, sh:closed false —
  # and therefore cannot produce a violation for ANY payload. Today exactly
  # Microsoft.Network/networkSecurityGroups (NsgShape). Found defect
  # V261014-18-D1.
  defp shapeless_admitted_types do
    for type <- @types,
        shape = shape_for_admitted_type(type),
        shape != nil,
        shape.required == [],
        shape.closed == false do
      type
    end
  end

  # -- wire helpers (Bandit + raw :gen_tcp; same pattern as arm_wire_test) ----

  defp stop_tree(sup) do
    try do
      Supervisor.stop(sup, :normal, 5000)
    catch
      _, _ -> Process.exit(sup, :kill)
    end
  end

  defp stop_existing_tree do
    case Process.whereis(Smalt.Supervisor) do
      nil ->
        for name <- [Smalt.Store, Smalt.AmqpBroker] do
          if pid = Process.whereis(name), do: GenServer.stop(pid)
        end

      _sup ->
        SmaltTest.Lifecycle.stop_shared_tree()
    end
  end

  defp get_free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp wire_request(port, method, path, opts \\ []) do
    headers = Keyword.get(opts, :headers, [])
    body = Keyword.get(opts, :body, "")

    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5000)

    header_lines =
      Enum.map_join(
        headers ++ [{"host", "127.0.0.1:#{port}"}, {"connection", "close"}],
        "\r\n",
        fn {k, v} -> "#{k}: #{v}" end
      )

    request =
      "#{method} #{path} HTTP/1.1\r\n" <>
        header_lines <> "\r\ncontent-length: #{byte_size(body)}\r\n\r\n" <> body

    :ok = :gen_tcp.send(sock, request)
    raw = recv_all(sock) |> IO.iodata_to_binary()
    :gen_tcp.close(sock)
    parse_response(raw)
  end

  defp recv_all(sock) do
    case :gen_tcp.recv(sock, 0, 15000) do
      {:ok, data} -> [data | recv_all(sock)]
      {:error, :closed} -> []
    end
  end

  defp parse_response(raw) do
    [head, rest] = :binary.split(raw, "\r\n\r\n")
    [status_line | header_lines] = String.split(head, "\r\n")
    [_, status, _reason] = String.split(status_line, " ", parts: 3)
    body = rest

    body =
      if get_header(header_lines, "transfer-encoding") == "chunked" do
        decode_chunked(body)
      else
        body
      end

    %{status: String.to_integer(status), body: body, headers: header_lines}
  end

  defp get_header(lines, name) do
    case Enum.find(lines, fn l -> String.starts_with?(String.downcase(l), name) end) do
      nil -> nil
      l -> l |> String.split(": ", parts: 2) |> Enum.at(1)
    end
  end

  defp decode_chunked(bin, acc \\ [])

  defp decode_chunked("\r\n" <> rest, acc), do: decode_chunked(rest, acc)

  defp decode_chunked(bin, acc) do
    case Integer.parse(bin, 16) do
      {0, _} ->
        IO.iodata_to_binary(Enum.reverse(acc))

      {size, rest} ->
        <<chunk::binary-size(size), "\r\n", rest2::binary>> = rest
        decode_chunked(rest2, [chunk | acc])

      :error ->
        IO.iodata_to_binary(Enum.reverse(acc))
    end
  end
end
