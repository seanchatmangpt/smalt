# T07 (v26.10.29, L07) — hoisted verbatim from Smalt.EgressRouter
# (docs/jira/v26.10.29/tickets/T07-egress-router-split.md): the embedded
# `defmodule Peers` moves to its own file. Module name is UNCHANGED
# (`Smalt.EgressRouter.Peers`) — the armstrong idiom court
# (test/internal/armstrong_idiom_court_test.exs) and the KD-124 crash-face
# court (test/integration/namespace_put_test.exs) pin the module by name, and
# lib/smalt/arm_gateway/plug/resource_providers.ex calls
# Smalt.EgressRouter.Peers.emit_resource_write_success/2 directly. Bodies,
# attrs, docs and specs are byte-identical to the pre-hoist embedded module.
defmodule Smalt.EgressRouter.Peers do
    @moduledoc """
    AZB-10 cross-plane wiring primitives (loopback-only, zero egress):

    - `resolve/1` — config-driven peer endpoints (`config :smalt, :peers`,
      sourced from `config/env/az_prod_*.exs`). No in-process short-circuit:
      callers always reach peers over the wire at the resolved endpoint.
    - `guard/1` — egress guard: any non-loopback / non-peer outbound endpoint
      is refused typed with `R_missing_authority`, counted, and instrumented
      (`[:smalt, :egress, :refused]` telemetry, metadata carries the reason).
    - `refused_connects/0` — suite-level counter of refused non-loopback
      connects (the Accept gate reads a delta of 0 over the cross-plane wire
      legs).
    - `emit_resource_write_success/2` — control-plane resource PUT emits the
      Event Grid `Microsoft.Resources.ResourceWriteSuccess` event to the
      integration plane (Event Grid topic fan-out + Service Bus bridge
      enqueue). Never raises into the PUT response path.

    Same-node peers are reached over real sockets (wire fidelity, AZB-10
    falsifier: an in-process resolution is a defect). Emission helpers live
    here so the control-plane router carries a single call site.
    """

    @loopback_hosts ~w(127.0.0.1 localhost ::1)
    @counter_table :smalt_egress_guard
    @sb_bridge_queue "resourcewritesuccess"

    # -- peer resolution ---------------------------------------------------------

    @doc "Config-driven peer endpoint for `plane` (nil when unconfigured)."
    @spec resolve(atom()) :: String.t() | nil
    def resolve(plane) when is_atom(plane) do
      case Application.get_env(:smalt, :peers) do
        kw when is_list(kw) -> Keyword.get(kw, plane)
        _other -> nil
      end
    end

    # -- egress guard ------------------------------------------------------------

    @doc """
    Egress guard for an outbound endpoint URL. Loopback hosts and endpoints
    matching a configured peer prefix are allowed (:ok); any other host is
    refused typed (`{:refused, :R_missing_authority}`), counted, and
    instrumented. Fail-closed: an unparseable URL refuses.
    """
    @spec guard(String.t()) :: :ok | {:refused, :R_missing_authority}
    def guard(url) when is_binary(url) do
      host = URI.parse(url).host

      cond do
        is_nil(host) ->
          refuse(url, nil)

        loopback?(host) or peer_endpoint?(url) ->
          :ok

        true ->
          refuse(url, host)
      end
    end

    @doc "Count of refused non-loopback outbound connects (monotone)."
    @spec refused_connects :: non_neg_integer()
    def refused_connects do
      ensure_table()
      :ets.lookup_element(@counter_table, :refused, 2)
    end

    defp refuse(url, host) do
      ensure_table()
      :ets.update_counter(@counter_table, :refused, {2, 1})

      :telemetry.execute(
        [:smalt, :egress, :refused],
        %{count: 1},
        %{host: host, url: url, reason: :R_missing_authority}
      )

      {:refused, :R_missing_authority}
    end

    defp loopback?(host), do: host in @loopback_hosts

    defp peer_endpoint?(url) do
      case Application.get_env(:smalt, :peers) do
        kw when is_list(kw) ->
          Enum.any?(kw, fn
            {plane, ep} when plane != :self and is_binary(ep) ->
              String.starts_with?(url, ep)

            _ ->
              false
          end)

        _ ->
          false
      end
    end

    defp ensure_table do
      if :ets.info(@counter_table) == :undefined do
        # Named public table; races on first-touch are benign (both arms
        # create the same shape; loser's :error is ignored).
        try do
          :ets.new(@counter_table, [:named_table, :public, :set, write_concurrency: true])
          :ets.insert(@counter_table, {:refused, 0})
        catch
          _, _ -> :ok
        end
      end
    end

    # -- control-plane resource-write emission ----------------------------------

    @doc """
    Emits the Event Grid `Microsoft.Resources.ResourceWriteSuccess` event for a
    successful control-plane resource PUT: fan-out on the Event Grid topic
    `resources` to every subscriber (integration-plane bridge), plus a Service
    Bus bridge enqueue on queue `#{@sb_bridge_queue}` (the integration plane's
    AMQP surface). Never raises into the PUT response path.
    """
    @spec emit_resource_write_success(map(), map()) :: :ok
    def emit_resource_write_success(record, meta) when is_map(record) and is_map(meta) do
      event = build_event(record, meta)

      # Event Grid fan-out (integration plane subscribers get redelivery
      # semantics from the engine itself).
      try do
        Smalt.Messaging.EventGrid.publish("resources", event)
      catch
        _, _ -> :ok
      end

      # Service Bus bridge: the event body enqueued on the integration plane's
      # queue so an AMQP/QueueStore subscriber receives ResourceWriteSuccess.
      try do
        Smalt.Amqp.QueueStore.enqueue(@sb_bridge_queue, Jason.encode!(event))
      catch
        _, _ -> :ok
      end

      :ok
    end

    # Public (def, defp->def): re-landed from the pre-undock source (95d4243d) —
    # the armstrong idiom court calls Peers.build_event/2 directly and the
    # undock demoted it to private.
    @doc false
    @spec build_event(map(), map()) :: map()
    def build_event(record, meta) do
      res_id = Map.get(record, "id")

      %{
        id: "rgw-" <> resource_uri_digest(res_id),
        event_type: "Microsoft.Resources.ResourceWriteSuccess",
        subject: res_id,
        topic: "resources",
        event_time: DateTime.utc_now() |> DateTime.to_iso8601(),
        data: %{
          "resourceUri" => res_id,
          "operationName" =>
            "#{Map.get(record, "type", "Microsoft.Resources")}/write",
          # ARMSTRONG fix 3 (re-landed from 95d4243d): the fallback is minted
          # PER EVENT (make_ref), not deterministic per resource — a digest-based
          # fallback made every event on a resource share one correlationId,
          # destroying correlation.
          "correlationId" => Map.get(meta, :correlation_id, "azb10-" <> inspect(make_ref())),
          "subscription" => Map.get(meta, :subscription)
        }
      }
    end

    defp resource_uri_digest(res_id) do
      res_id
      |> :erlang.phash2()
      |> Integer.to_string()
    end
end
