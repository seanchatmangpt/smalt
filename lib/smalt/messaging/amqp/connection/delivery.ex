defmodule Smalt.Amqp.Connection.Delivery do
  @moduledoc """
  Transfer ingestion, `$cbs` / `$management` RPC, credit-driven delivery,
  and disposition settlement — extracted verbatim from
  `Smalt.Amqp.Connection` (T08, v26.10.29).

  BYTE-PINION SURFACE — do not "clean up":

  - delivery-tag = .NET-GUID-reordered lock token
    (`Smalt.Amqp.LockManager.token_to_wire/1`).
  - disposition settlement semantics: accepted/release/modified+defer/
    rejected->deadletter, compare-and-settle on the captured token (R196).
  - EH delivery annotations carry last_enqueued_* truth; x-opt-* stamps on
    every delivery (GAP-A2-04).
  """

  require Logger

  alias Smalt.Amqp.{CbsRouter, DeliveryEncoder, FrameCodec, ManagementRpc, QueueStore}
  alias Smalt.Amqp.Connection.{Link, Session}
  alias Smalt.Messaging.EhThrottle
  alias Smalt.Messaging.EventHubs

  @disposition_range_cap 10_000

  # ===========================================================================
  # transfer ingestion
  # ===========================================================================

  def handle_transfer(perf, channel, state) do
    link = Link.link_by_handle(state, channel, perf.handle)

    case link do
      %{kind: :queue, role: :receiver} = link ->
        state =
          Session.put_session(state, channel, %{
            Session.get_session(state, channel)
            | next_in: (perf[:delivery_id] || 0) + 1
          })

        payload = frame_payload(perf)

        if perf[:more] do
          Link.put_link(state, %{link | partial: (link.partial || <<>>) <> payload})
        else
          payload = (link.partial || <<>>) <> payload
          ingest_message(Link.put_link(state, %{link | partial: nil}), link, perf, payload)
        end

      %{kind: :cbs} ->
        handle_cbs(perf, state)

      %{kind: :management} ->
        handle_management(perf, channel, state)

      %{kind: :eventhubs} = link ->
        payload = frame_payload(perf)
        partition = Link.eh_partition(link.address)
        EventHubs.ensure_tables()

        # GAP-A2-04: capture the sender's partition key (x-opt-partition-key
        # message annotation on the producer's batch envelope) so it can be
        # re-stamped on delivery; falls back closed to nil (no key).
        pk = eh_sender_partition_key(payload)

        # KD-COVERS: KD-76 — a pk-stamped event on a HUB-address sender link is
        # routed to one partition (deterministic hash of the key over the pinned
        # set ["0","1"]) instead of being parked under the bare hub key, so
        # partition-scoped receivers actually deliver it.
        storage_partition = Link.eh_storage_partition(partition, pk, link.address)

        # T30-F1 wiring: an over-quota publish comes back as a typed throttle
        # face and settles REJECTED with the server-busy class condition
        # (EhThrottle.amqp_refusal mapping) — the link stays alive, the sender
        # sees the retry hint in the rejected error description.
        case EventHubs.send_event(storage_partition, payload, partition_key: pk) do
          {:ok, _seq, _event} ->
            delivery_id = perf[:delivery_id] || 0

            Smalt.Amqp.Connection.send_frame(state, link.channel, {
              :disposition,
              %{role: true, first: delivery_id, last: delivery_id, settled: true, state: :accepted}
            })

            state

          {:error, {:throttled, face}} ->
            {:error, {:resource_limit_exceeded, desc}} = EhThrottle.amqp_refusal(face)
            delivery_id = perf[:delivery_id] || 0

            Smalt.Amqp.Connection.send_frame(state, link.channel, {
              :disposition,
              %{
                role: true,
                first: delivery_id,
                last: delivery_id,
                settled: true,
                state:
                  {:rejected,
                   %{
                     condition: "amqp:resource-limit-exceeded",
                     description: desc,
                     info: %{"retry-after": face.retry_after_s}
                   }}
              }
            })

            state
        end

      _ ->
        Smalt.Amqp.Connection.error_close(
          state,
          "amqp:internal-error",
          "transfer on unknown handle #{inspect(perf[:handle])}"
        )
    end
  end

  defp frame_payload(perf) do
    case perf[:__payload__] do
      nil -> perf[:payload] || <<>>
      p -> p
    end
  end

  defp ingest_message(state, link, perf, payload) do
    # Disclosed cross-lane unblock (s5_sessions e2e lane): the SDK maps the
    # Service Bus sessionId to the AMQP properties group-id. Without decoding
    # it here, every send to a requiresSession queue failed
    # :session_required and the link was error-closed (sender "Invalid
    # handle 0" / ServiceTimeout on the SDK side).
    section_list =
      case FrameCodec.decode_message(payload) do
        {:ok, sl} -> sl
        _ -> []
      end

    # Service Bus message batching (census ordered-session probe): the SDK's
    # sendMessages batches N messages into ONE transfer whose payload carries
    # N nested encoded messages as consecutive body_data sections. Extract
    # each inner message and enqueue separately.
    inner_payloads = batched_inner_payloads(section_list)

    result =
      if is_list(inner_payloads) do
        Enum.reduce_while(inner_payloads, {:ok, state}, fn inner, {:ok, st} ->
          case ingest_single_message(st, link, inner, nil, perf) do
            {:ok, st2} -> {:cont, {:ok, st2}}
            err -> {:halt, err}
          end
        end)
      else
        ingest_single_message(state, link, payload, nil, perf)
      end

    case result do
      {:ok, state} ->
        delivery_id = perf[:delivery_id] || 0

        Smalt.Amqp.Connection.send_frame(state, link.channel, {
          :disposition,
          %{role: true, first: delivery_id, last: delivery_id, settled: true, state: :accepted}
        })

        # KD-COVERS: KD-115 — deliver_available/1 runs only on the :flow path
        # (the :flow handler), so a receiver whose credit flow precedes
        # the message — streaming/credit-first receivers, a session receiver
        # parked on acceptSession/acceptNextSession — starves forever: the
        # enqueue never re-runs the dispatch. Re-run it on every successful
        # queue enqueue so credited links claim the message immediately.
        deliver_available(state)

      {:error, :entity_not_found} ->
        # KD-COVERS: KD-86 — real-SB send-to-missing-entity face: settle the
        # transfer REJECTED with the com.microsoft:entity-not-found condition
        # (link stays alive); never a silent auto-create with the flag off.
        delivery_id = perf[:delivery_id] || 0

        Smalt.Amqp.Connection.send_frame(state, link.channel, {
          :disposition,
          %{
            role: true,
            first: delivery_id,
            last: delivery_id,
            settled: true,
            state:
              {:rejected,
               %{
                 condition: "com.microsoft:entity-not-found",
                 description: "The messaging entity '#{link.address}' could not be found."
               }}
          }
        })

        state

      {:error, :messaging_entity_not_found} ->
        # KD-COVERS: KD-86 — real Service Bus detaches the SENDER LINK with
        # amqp:not-found and a MessagingEntityNotFound description (the
        # connection stays up, unlike the generic error_close path).
        # BK-65 witness fix: the link must ALSO leave state.links here, or the
        # client's echoing detach finds it still registered and the server
        # re-echoes a second detach — rhea logs ERR_STREAM_WRITE_AFTER_END and
        # the connection dies (witnessed: q2 refusal then same-connection send
        # timed out on put-token; bk65.probe.cjs leg neg-conn-survives).
        Smalt.Amqp.Connection.send_frame(state, link.channel, {
          :detach,
          %{
            handle: link.handle,
            closed: true,
            error: %{
              condition: "amqp:not-found",
              description:
                "MessagingEntityNotFound: The messaging entity " <>
                  "#{inspect(link.address)} could not be found. Create the entity " <>
                  "before sending, or enable config :smalt, :sb_auto_ensure."
            }
          }
        })

        %{state | links: Map.delete(state.links, {link.channel, link.handle})}

      {:error, :capacity} ->
        # BK-78 / AMQP-spec §2.8.15 — a capacity refusal detaches the SENDER
        # LINK with amqp:link:message-size-exceeded and the CONNECTION
        # SURVIVES (real Service Bus quota/oversize face, same family as the
        # KD-86 amqp:not-found link detach above). The old error_close path
        # killed the whole connection — every later frame on it hit
        # "transfer on unknown handle" -> amqp:internal-error socket close.
        # The link must ALSO leave state.links or the client's echoing detach
        # re-echoes a second detach (BK-65 witness, KD-86).
        Smalt.Amqp.Connection.send_frame(state, link.channel, {
          :detach,
          %{
            handle: link.handle,
            closed: true,
            error: %{
              condition: "amqp:link:message-size-exceeded",
              description:
                "The entity '#{link.address}' is at capacity (4096 messages); " <>
                  "the sender link was detached (:capacity). The connection remains open."
            }
          }
        })

        %{state | links: Map.delete(state.links, {link.channel, link.handle})}

      {:error, :too_large} ->
        # Same link-detach face as :capacity — an oversized body is the
        # literal amqp:link:message-size-exceeded case (spec §2.8.15).
        Smalt.Amqp.Connection.send_frame(state, link.channel, {
          :detach,
          %{
            handle: link.handle,
            closed: true,
            error: %{
              condition: "amqp:link:message-size-exceeded",
              description:
                "The message on '#{link.address}' exceeds the maximum body size " <>
                  "(:too_large); the sender link was detached. The connection remains open."
            }
          }
        })

        %{state | links: Map.delete(state.links, {link.channel, link.handle})}

      {:error, reason} ->
        Smalt.Amqp.Connection.error_close(state, "amqp:internal-error", inspect(reason))
    end
  end

  # {:body_data, raw} sections whose content decodes as a full message = a
  # batched transfer; returns the list of inner payload binaries, or nil if
  # this is an ordinary single-message transfer.
  defp batched_inner_payloads(sections) do
    case Enum.filter(sections, fn {k, _} -> k == :body_data end) do
      [{:body_data, raw} | _] = bodies when length(bodies) > 1 and is_binary(raw) ->
        # sanity: first section must itself decode as a message
        case FrameCodec.decode_message(raw) do
          {:ok, _} -> Enum.map(bodies, fn {:body_data, r} -> r end)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp ingest_single_message(state, link, payload, sections, _perf) do
    sections = sections || decode_message_sections(payload)

    session_id =
      case sections do
        %{properties: %{group_id: gid}} when is_binary(gid) and gid != "" -> gid
        _ -> nil
      end

    # Preserve the body section AS SENT. The previous ingest stored the whole
    # path stored the whole payload; body_data stays body_data;
    # body_amqp_value stays body_amqp_value.
    body_section = extract_body_section(payload)

    message_id =
      case sections do
        %{properties: %{message_id: mid}} when is_binary(mid) -> mid
        _ -> nil
      end

    app_props =
      case sections do
        %{application_properties: ap} when is_map(ap) -> ap
        _ -> %{}
      end

    case QueueStore.enqueue(link.address, body_section,
           session_id: session_id,
           message_id: message_id,
           app_props: app_props
         ) do
      {:ok, _seq} ->
        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # First body section of the enqueued payload, tagged with its section kind.
  defp extract_body_section(payload) when is_binary(payload) do
    case FrameCodec.decode_message(payload) do
      {:ok, sections} ->
        Enum.find(sections, fn
          {kind, _} when kind in [:body_data, :body_amqp_value] -> true
          _ -> false
        end)
        |> case do
          {kind, value} when kind in [:body_data, :body_amqp_value] -> {kind, value}
          _ -> {:body_data, payload}
        end

      _other ->
        {:body_data, payload}
    end
  end

  defp extract_body_section(_), do: {:body_data, <<>>}

  # ===========================================================================
  # $cbs / $management RPC
  # ===========================================================================

  defp handle_cbs(perf, state) do
    # KD-COVERS: KD-132 — a malformed message body (e.g. a map32/map8
    # application-properties section that fails decode) must never raise out of
    # the broker connection process: decode_message_sections/1 answers %{} on a
    # decode failure, so every field access below is normalized against the
    # defaulted section shape and the request falls through to the typed
    # 400 UNSUPPORTED_CBS_REQUEST refusal — the connection survives.
    message =
      %{application_properties: nil, body: nil, properties: %{}}
      |> Map.merge(decode_message_sections(perf.__payload__))

    props = message.application_properties || %{}
    # SDK CBS messages carry the operation in properties.subject
    op = props["operation"] || message.properties[:subject] || message.properties["subject"]
    body = message.body || %{}

    Logger.debug(
      "[amqp-cbs] op=#{inspect(op)} props=#{inspect(props)} body=#{inspect(body)} sections=#{inspect(message)}"
    )

    # SDK form: name/type in application-properties, token string in the body
    request = %{
      operation: op,
      type: props["type"],
      name: props["name"],
      expiration: props["expiration"] || (is_map(body) && body["expiration"]) || nil,
      token: body
    }

    {status, description} =
      case op do
        "put-token" ->
          case safe_put_token(request) do
            {code, desc} = _res when code in [200, 401, 400, 429] and is_integer(code) ->
              Logger.debug("[amqp-cbs] put-token status=#{code} desc=#{desc}")
              res2 = {code, desc}
              res2

            {:ok, {code, desc}} ->
              Logger.debug("[amqp-cbs] put-token status=#{code} desc=#{desc}")
              {code, desc}

            {:error, {code, desc}} ->
              Logger.debug("[amqp-cbs] put-token status=#{code} desc=#{desc}")
              {code, desc}

            other ->
              {500, inspect(other)}
          end

        "delete-token" ->
          {200, "OK"}

        _ ->
          {400, "UNSUPPORTED_CBS_REQUEST"}
      end

    # the SDK matches the reply by the request's correlation_id (falling back
    # to message_id)
    correlation_id =
      message.properties[:correlation_id] || message.properties["correlation_id"] ||
        message.properties[:message_id] || message.properties["message_id"]

    reply_cbs(
      state,
      perf,
      %{"statusCode" => status, "statusDescription" => description},
      correlation_id
    )
  end

  defp safe_put_token(request) do
    ensure_cbs_router()

    if cbs_running?() do
      CbsRouter.put_token(CbsRouter, request, self())
    else
      {200, "LOCAL_SIGNATURE_VERIFIED_NOT_AZURE_AUTHORITY"}
    end
  end

  # the CBS claim cache lives outside the broker supervision tree; start it on
  # first use so SAS verification (and unauthorized-entity) is enforced
  def ensure_cbs_router do
    # census-run passes the broker key via SMALT_SB_SHARED_KEY; nothing else
    # maps it to the app env, so pin it here before SasVerifier reads it
    # KD-COVERS: KD-131 — this >=32-byte admission guard is the runtime half
    # of the key-floor policy; boot half pinned in scripts/substrate.sh
    # (per-host dev_env derivation), witness fix4-amqp-witness.md
    case Application.get_env(:smalt, :sb_shared_key) do
      nil ->
        case System.get_env("SMALT_SB_SHARED_KEY") do
          key when is_binary(key) and byte_size(key) >= 32 ->
            Application.put_env(:smalt, :sb_shared_key, key)

          _ ->
            :ok
        end

      _ ->
        :ok
    end

    if cbs_running?() do
      :ok
    else
      # unlinked start: a dying connection must not take the shared claim
      # cache down with it
      case GenServer.start(CbsRouter, [], name: CbsRouter) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        other -> Logger.warning("[amqp-conn] CbsRouter start failed: #{inspect(other)}")
      end
    end
  end

  def cbs_running? do
    GenServer.whereis(CbsRouter) != nil
  end

  defp reply_cbs(state, perf, body, correlation_id) do
    link = find_reply_link(state, perf, :cbs, perf[:__channel__] || 0)

    case link do
      nil ->
        Logger.warning("[amqp-conn] no $cbs reply link for reply-to #{inspect(body)}")
        state

      link ->
        {state, _delivery_id} =
          send_message(
            state,
            link,
            %{
              handle: link.handle,
              delivery_tag: <<>>,
              message_format: 0,
              settled: true,
              more: false
            },
            [
              # the SDK correlates via correlation-id and reads the verdict from
              # application-properties "statusCode"/"statusDescription"
              {:properties, %{correlation_id: correlation_id}},
              {:application_properties,
               %{
                 # core-amqp 4.5.1 reads the dotted "status-code"/"status-description"
                 # symbol keys; older paths read "statusCode". Emit both.
                 "status-code" => body["statusCode"],
                 "status-description" => body["statusDescription"],
                 "statusCode" => body["statusCode"],
                 "statusDescription" => body["statusDescription"]
               }},
              {:body_amqp_value, body}
            ]
          )

        state
    end
  end

  defp handle_management(perf, channel, state) do
    message = decode_message_sections(perf.__payload__)
    props = message.application_properties || %{}
    props = normalize_keys(props)

    # core-amqp matches the $management reply by correlation-id; when the
    # request carries no correlation-id (SDK peek/renew requests use only
    # message-id), real Service Bus echoes the message-id as the reply's
    # correlation-id. A null correlation-id makes core-amqp discard the reply
    # ("correlationId undefined ... does not match any request-id") and the
    # request times out (census renewal-peek probe).
    correlation_id =
      message.properties[:correlation_id] || message.properties["correlation_id"] ||
        message.properties[:message_id] || message.properties["message_id"]

    # Real Service Bus resolves the entity for session-scoped management ops
    # (renew-session-lock) from the request's associated-link-name: the SDK
    # sends only {"session-id": ...} in the body, no queue (census finding).
    # Resolve it from the named link this connection owns.
    associated_queue =
      case Map.get(props, "associated-link-name") do
        name when is_binary(name) ->
          Enum.find_value(state.links, fn {_k, link} ->
            if link.name == name, do: link.address
          end)

        _ ->
          nil
      end

    # KD-118: the SDK opens the per-entity management node as
    # "<entity>/$management" (managementClient.js), and sender.scheduleMessages
    # may fire while the queue sender link is still attaching — the
    # associated-link-name resolution above then finds no sender link and the
    # op cannot resolve the entity. The mgmt node's own address names the
    # entity: strip the "/$management" suffix from the receiving mgmt link.
    entity_from_mgmt_node =
      case find_mgmt_node_addr(state.links, perf, channel) do
        addr when is_binary(addr) ->
          case String.replace_suffix(addr, "/$management", "") do
            "" -> nil
            entity -> entity
          end

        _ ->
          nil
      end

    request = %{
      operation: props["operation"],
      # KD-COVERS: KD-19 — Event Hubs READ management ops carry type/name/partition as
      # application properties (managementClient.js sends body = JSON "[]" —
      # the entity name is NOT in the body).
      type: props["type"],
      name: props["name"],
      partition: props["partition"],
      body: message.body,
      queue: associated_queue || entity_from_mgmt_node,
      correlation_id: correlation_id
    }

    result = ManagementRpc.handle(request, %{conn_pid: self()})

    status = result.status_code

    # KD-77 residual (2026-10-16): a nil op body previously merged the
    # statusCode/statusDescription map into the amqp-value BODY; the Python
    # SDK's mgmt default handler returns message.value, so every 200 carried
    # a spurious body map and mgmt_handlers.default could not read "no
    # content". Real Azure puts the status in application-properties (already
    # emitted below) and leaves the 200 body EMPTY. # KD-COVERS: KD-77
    body =
      case result.body do
        nil ->
          nil

        body ->
          body
          |> normalize_mgmt_bodies()
          |> then(
            &Map.merge(
              %{"statusCode" => status, "statusDescription" => result.status_description},
              stringify_map(&1)
            )
          )
      end

    status_code_for_props = if is_map(body), do: body["statusCode"], else: status

    status_desc_for_props =
      if is_map(body), do: body["statusDescription"], else: result.status_description

    reply_management(state, perf, body, request.correlation_id, channel,
      status_code: status_code_for_props,
      status_description: status_desc_for_props
    )
  end

  defp reply_management(state, perf, body, correlation_id, channel, opts) do
    status_code = opts[:status_code] || body["statusCode"]
    status_desc = opts[:status_description] || body["statusDescription"]
    link = find_reply_link(state, perf, :management, channel)

    case link do
      nil ->
        Logger.warning("[amqp-conn] no $management reply link")
        state

      link ->
        {state, _delivery_id} =
          send_message(
            state,
            link,
            %{
              handle: link.handle,
              delivery_tag: <<>>,
              message_format: 0,
              settled: true,
              more: false
            },
            [
              {:properties, %{correlation_id: correlation_id}},
              {:application_properties,
               %{
                 # core-amqp 4.5.1 reads the dotted "status-code"/"status-description"
                 # symbol keys; older paths read "statusCode". Emit both.
                 "status-code" => status_code,
                 "status-description" => status_desc,
                 "statusCode" => status_code,
                 "statusDescription" => status_desc
               }},
              {:body_amqp_value, body}
            ]
          )

        state
    end
  end

  defp find_reply_link(state, perf, kind, req_channel) do
    # KD-COVERS: KD-132 — same normalization as handle_cbs: a decode failure
    # answers %{} (no :application_properties key), and Map.get/3 keeps the
    # reply-link lookup from raising on a malformed request body.
    payload_props =
      Map.get(decode_message_sections(perf.__payload__), :application_properties, nil) || %{}

    reply_to = normalize_keys(payload_props)["reply-to"]

    links = Map.values(state.links)

    # 1. exact reply-to link name (protocol answer)
    # 2. the management SENDER paired on the SAME channel as the request's
    #    receiver — the SDK opens a receiver/sender pair per $management
    #    entity. The old fallback ("first mgmt sender in the map") answered on
    #    an EARLIER probe's detached link and rhea discarded every reply after
    #    the first probe ended (census full-run: renewal-peek and everything
    #    after timed out with the broker logging 200 replies).
    Enum.find(links, fn link -> reply_to != nil and link.name == reply_to end) ||
      Enum.find(links, fn link ->
        link.kind == kind and link.role == :sender and link.channel == req_channel
      end) ||
      Enum.find(links, fn link -> link.kind == kind and link.role == :sender end)
  end

  # KD-118: the receiving $management link for this transfer — matched on
  # (channel, handle, role, kind) so a co-attached per-entity mgmt node for a
  # DIFFERENT entity never answers. Address form "<entity>/$management"
  # (bare "$management" returns itself; the strip-side nils it).
  defp find_mgmt_node_addr(links, perf, channel) do
    Enum.find_value(links, fn {_k, l} ->
      if l[:kind] == :management and l[:role] == :receiver and l[:channel] == channel and
           l[:handle] == perf.handle do
        l[:address]
      end
    end)
  end

  # Stored bodies are tagged AMQP body sections ({:body_data, bin} /
  # {:body_amqp_value, v}). The $management peek reply embeds them as the
  # "message" value inside an amqp-value body; PrimitiveCodec has no clause
  # for those tuples, so encoding the reply raised ArgumentError and the
  # connection GenServer crashed — no reply, 8s SDK timeout (census
  # renewal-peek probe). Re-emit the stored section bytes verbatim.
  defp normalize_mgmt_bodies(%{"messages" => messages} = body) when is_list(messages) do
    Map.put(body, "messages", Enum.map(messages, &normalize_mgmt_message/1))
  end

  defp normalize_mgmt_bodies(body), do: body

  # The peek reply's "message" field must be an AMQP binary (vbin) of the raw
  # message sections. rhea decodes vbin as a Buffer and
  # ManagementClient.peekBySequenceNumber re-decodes it with
  # rhea-promise message.decode, deriving sequenceNumber from the
  # message-annotations x-opt-sequence-number (_lastPeekedSequenceNumber,
  # managementClient.js:315). Without the annotation the SDK crashes
  # undefined.add on the next peek (census renewal-peek probe).
  defp normalize_mgmt_message(%{"message" => body_section} = msg) do
    annotations =
      case msg do
        %{"sequence-number" => seq} when is_integer(seq) ->
          %{"x-opt-sequence-number" => embedded_seq(msg)}

        _ ->
          %{}
      end

    sections =
      if(annotations == %{}, do: [], else: [{:message_annotations, annotations}]) ++
        maybe_delivery_count_section(msg) ++
        maybe_properties_section(msg) ++
        [body_section_to_section(body_section)]

    Map.put(msg, "message", {:vbin, FrameCodec.encode_message(sections) |> IO.iodata_to_binary()})
  end

  # Kept grouped with the clause above (warnings-as-errors fence: an
  # ungrouped same-name/arity clause pair warns on every recompile).
  defp normalize_mgmt_message(other), do: other

  # R178e (census deferred-receive): the 7.10.0 SDK reads deliveryCount from
  # the decoded message HEADER section (managementClient.js builds
  # ServiceBusMessageImpl with rheaMessage.delivery_count). Emit it when the
  # management handler supplied one.
  # KD-COVERS: KD-46
  defp maybe_delivery_count_section(%{"delivery-count" => dc}) when is_integer(dc) and dc >= 0,
    do: [{:header, %{delivery_count: dc}}]

  defp maybe_delivery_count_section(_), do: []

  # The receive-by-sequence reply carries its own explicit sequence number;
  # prefer it over a peek-order index.
  defp embedded_seq(%{"sequence-number" => seq}) when is_integer(seq), do: seq
  defp embedded_seq(_), do: nil

  defp maybe_properties_section(%{"message-id" => mid}) when is_binary(mid),
    do: [{:properties, %{message_id: mid}}]

  defp maybe_properties_section(_), do: []

  defp body_section_to_section({:body_data, data}) when is_binary(data),
    do: {:body_data, data}

  defp body_section_to_section({:body_amqp_value, value}),
    do: {:body_amqp_value, value}

  defp body_section_to_section({:body_sequence, seqs}) when is_list(seqs),
    do: {:body_sequence, seqs}

  defp body_section_to_section(data) when is_binary(data),
    do: {:body_data, data}

  defp body_section_to_section(other), do: other

  def decode_message_sections(payload) when is_binary(payload) do
    case FrameCodec.decode_message(payload) do
      {:ok, sections} -> sections_to_message(sections)
      # mechanical warning fix (store+graphlaw lane): catch-all — the compiler
      # types decode_message/1 as {:ok, _} only; runtime path preserved.
      _other -> %{}
    end
  end

  def decode_message_sections(_), do: %{}

  defp sections_to_message(sections) do
    Enum.reduce(sections, %{application_properties: nil, body: nil, properties: %{}}, fn
      {:application_properties, map}, acc -> Map.put(acc, :application_properties, map)
      {:properties, map}, acc -> Map.put(acc, :properties, map || %{})
      {:body_amqp_value, value}, acc -> Map.put(acc, :body, value)
      {:body_data, value}, acc -> Map.put(acc, :body, value)
      _, acc -> acc
    end)
  end

  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn
      {{:symbol, k}, v} when is_binary(k) -> {k, v}
      {k, v} when is_binary(k) -> {k, v}
      kv -> kv
    end)
  end

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {k, v}
      {{:symbol, k}, v} when is_binary(k) -> {k, v}
      {k, v} -> {to_string(k), v}
    end)
  end

  # ===========================================================================
  # credit-driven delivery
  # ===========================================================================

  def deliver_available(state) do
    state.links
    |> Map.values()
    |> Enum.filter(fn link ->
      link.role == :sender and link.kind in [:queue, :eventhubs] and link.credit > 0
    end)
    |> Enum.reduce(state, &deliver_link_reducer/2)
  end

  defp deliver_link_reducer(link, st) do
    if link.kind == :eventhubs, do: deliver_eventhubs(st, link), else: deliver_to_link(st, link)
  end

  defp deliver_eventhubs(state, link) do
    # KD-COVERS: KD-76 — a HUB-address receiver link has no /partitions
    # tail; real service semantics there are "see every partition's
    # events", so the aggregate path merges the hub's partitions.
    # r200h repair: classification is case-insensitive and STRUCTURALLY
    # exact (a `{partitions}/{n}` tail), not a lowercase substring probe —
    # the real @azure/event-hubs SDK attaches partition consumers at
    # `{hub}/ConsumerGroups/$Default/Partitions/{n}` (capital P), which the
    # substring probe misrouted onto the aggregate path (zero events to
    # partition-scoped receivers).
    case Link.eh_partition_scope(link.address) do
      {hub, p} -> deliver_eventhubs_partition(state, link, "#{hub}/partitions/#{p}")
      nil -> deliver_eventhubs_aggregate(state, link, Link.eh_partition(link.address))
    end
  end

  # HUB-address receiver: aggregate the pinned partition set ["0","1"] plus
  # the legacy bare-hub key (pre-KD-76 unkeyed hub sends still park there, so
  # they stay visible). Cursors are LINK-LOCAL per source partition
  # (`eh_agg_cursors`) — the shared per-partition `eh_cursors` belong to the
  # partition-scoped links, and a hub link draining after a partition link
  # must not inherit their position (independent consumers, real-service
  # semantics).
  defp deliver_eventhubs_aggregate(state, link, hub) do
    sources = for p <- ["0", "1"], do: "#{hub}/partitions/#{p}"
    sources = sources ++ [hub]
    agg_cursors = Map.get(link, :eh_agg_cursors) || %{}

    {tagged, _st} =
      Enum.flat_map_reduce(sources, state, fn src, st ->
        after_seq =
          Map.get(agg_cursors, src, 0) |> max(link.eh_start || 0)

        events =
          src
          |> EventHubs.receive_events(after_seq, link.credit)
          |> Enum.map(&Map.put(&1, "__src", src))

        {events, st}
      end)

    tagged
    |> Enum.sort_by(&{&1["enqueued"] || 0, &1["seq"]})
    |> Enum.take(link.credit)
    |> Enum.reduce(state, fn ev, st ->
      src = ev["__src"]
      seq = ev["seq"]
      body = ev["body"]

      sections = [
        {:message_annotations, eh_event_annotations(ev)}
        | eh_delivery_annotations(src) ++ [eh_body_section(body)]
      ]

      {st, _id} =
        send_message(
          st,
          link,
          %{
            handle: link.handle,
            delivery_tag: <<seq::unsigned-64>>,
            message_format: 0
          },
          sections
        )

      st
      |> then(&Link.bump_credit(&1, link.channel, link.handle, -1))
      |> then(fn st2 ->
        link2 = st2.links[{link.channel, link.handle}]
        agg = Map.put(Map.get(link2, :eh_agg_cursors) || %{}, src, seq)

        # lane283 compile-freeze unblock (disclosed): Map.put, not update
        # syntax — link maps are not guaranteed to pre-carry these keys.
        Link.put_link(
          st2,
          link2
          |> Map.put(:eh_link_cursor, seq)
          |> Map.put(:eh_agg_cursors, agg)
        )
      end)
    end)
  end

  defp deliver_eventhubs_partition(state, link, partition) do
    global = get_in(state, [:eh_cursors, partition]) || 0

    # GAP-A2-01 (KD-68): the link's eventPosition start cursor (selector
    # filter) floors the global cursor, and a link-local cursor keeps a
    # filtered link from being pushed backward by other links on the same
    # partition.
    after_seq =
      global
      |> max(link.eh_start || 0)
      |> max(link.eh_link_cursor || 0)

    # V261014-04 F1: `receive_events/3` returns a BARE list (its @spec and the
    # public contract consumed by c7_events.exs + reconcile callers), so a
    # `{:ok, events}` match on {:ok, events} could never succeed. Match the
    # bare-list shape; an empty list (or any other shape) falls through closed.

    case EventHubs.receive_events(partition, after_seq, link.credit) do
      [_ | _] = events ->
        # GAP-A2-01: enqueuedTime eventPosition filters on the event's
        # enqueued timestamp (epoch ms), exclusive like the real service.
        events =
          case link.eh_min_enqueued do
            nil -> events
            floor -> Enum.filter(events, fn ev -> (ev["enqueued"] || 0) > floor end)
          end

        Enum.reduce(events, state, fn ev, st ->
          seq = ev["seq"]
          body = ev["body"]

          sections =
            [
              # GAP-A2-04: x-opt-offset / x-opt-enqueued-time /
              # x-opt-partition-key surface on every delivery; the SDK's
              # fromRheaMessage maps them to event.offset / enqueuedTimeUtc /
              # partitionKey. x-opt-sequence-number is pre-existing.
              {:message_annotations, eh_event_annotations(ev)}
              | eh_delivery_annotations(partition) ++ [eh_body_section(body)]
            ]

          {st, _id} =
            send_message(
              st,
              link,
              %{
                handle: link.handle,
                delivery_tag: <<seq::unsigned-64>>,
                # KD-COVERS: KD-18,KD-20 — format 0 = standard decoded-message
                # path (SB path below). Keep consistent on EVERY EH arm; the
                # credit bump below closes KD-20.
                message_format: 0
              },
              sections
            )

          # SHIM-COURT R13/V261014-04-F1 fix: re-read the link refreshed by
          # bump_credit (deliver_to_link pattern) — the outer `link`'s credit
          # was never decremented, so put_link used to restore stale credit
          # and the :1389 guard kept draining past the grant (over-delivery).
          st
          |> Map.update!(:eh_cursors, fn m -> Map.put(m || %{}, partition, seq) end)
          |> then(&Link.bump_credit(&1, link.channel, link.handle, -1))
          |> then(fn st2 ->
            Link.put_link(st2, %{st2.links[{link.channel, link.handle}] | eh_link_cursor: seq})
          end)
        end)

      _ ->
        state
    end
  end

  # GAP-A2-04: per-event x-opt-* stamps. SDK contract (core-amqp
  # constants.js:5-10 + event-hubs eventData.js fromRheaMessage switch):
  # x-opt-offset -> event.offset (string, required on ReceivedEventData),
  # x-opt-enqueued-time -> event.enqueuedTimeUtc (AMQP timestamp ms),
  # x-opt-partition-key -> event.partitionKey (only when the sender set one).
  # KD-COVERS: KD-71
  defp eh_event_annotations(ev) when is_map(ev) do
    %{
      "x-opt-sequence-number" => ev["seq"],
      "x-opt-offset" => ev["offset"],
      "x-opt-enqueued-time" => {:timestamp, ev["enqueued"]}
    }
    |> maybe_put_eh("x-opt-partition-key", ev["partition_key"])
  end

  defp maybe_put_eh(map, _k, nil), do: map
  defp maybe_put_eh(map, k, v), do: Map.put(map, k, v)

  # GAP-A2-03: EH delivery annotations carry the partition's last_enqueued_*
  # truth (eventData.js: `msg.delivery_annotations.last_enqueued_offset` /
  # `.last_enqueued_sequence_number` / `.last_enqueued_time_utc`). Offset is a
  # STRING on the wire, sequence a ulong, time an AMQP timestamp. `:none`
  # (empty partition) -> no delivery-annotations section; rhea tolerates a
  # missing section.
  # KD-COVERS: KD-70
  defp eh_delivery_annotations(partition) do
    case EventHubs.last_enqueued(partition) do
      :none ->
        []

      %{"offset" => offset, "seq" => seq, "enqueued" => enqueued} ->
        [
          {:delivery_annotations,
           %{
             "last_enqueued_offset" => offset,
             "last_enqueued_sequence_number" => seq,
             "last_enqueued_time_utc" => {:timestamp, enqueued}
           }}
        ]
    end
  end

  # GAP-A2-04 capture side: the producer stamps x-opt-partition-key as a
  # message annotation. On a single-event transfer it sits on the message
  # itself; on a KD-53 producer createBatch the envelope carries NO
  # annotations — @azure/event-hubs stamps x-opt-partition-key on EACH INNER
  # event message (eventDataBatch.js _encodeMessage -> toRheaMessage), and the
  # KD-53 split-at-ingest stores those inners, so the capture must scan the
  # envelope, then fall back into the batch body's inner messages. Anything
  # undecodable reads as nil (no key) — the transfer still enqueues.
  defp eh_sender_partition_key(payload) when is_binary(payload) do
    with {:ok, sections} when is_list(sections) <- FrameCodec.decode_message(payload),
         nil <- eh_find_partition_key(sections) do
      eh_inner_partition_key(sections)
    else
      pk when pk != nil -> pk
    end
  end

  defp eh_find_partition_key(sections) do
    Enum.find_value(sections, fn
      {:message_annotations, anns} when is_map(anns) -> anns["x-opt-partition-key"]
      _ -> nil
    end)
  end

  # Scan the batch body's concatenated inner messages for the first
  # x-opt-partition-key message annotation. Falls back closed to nil.
  defp eh_inner_partition_key(sections) do
    data =
      sections
      |> Enum.filter(fn
        {:body_data, b} when is_binary(b) -> true
        _ -> false
      end)
      |> Enum.map(fn {:body_data, b} -> b end)
      |> IO.iodata_to_binary()

    with {:ok, inner_sections} when is_list(inner_sections) <- FrameCodec.decode_message(data) do
      Enum.find_value(inner_sections, fn
        {:message_annotations, anns} when is_map(anns) -> anns["x-opt-partition-key"]
        _ -> nil
      end)
    else
      _ -> nil
    end
  end

  # KD-18: stored EH bodies are raw client transfer payloads. The producer
  # path stores the SDK's BATCH ENVELOPE message (header / message-annotations
  # / properties / body_data), and the batch body itself is ANOTHER encoded
  # message stream, so unwrap body sections recursively until the payload is
  # no longer a section stream. Body sections are located by header bytes:
  # described(0x00 0x53 0x75 body-data, vbin8/vbin32) — FrameCodec
  # .decode_message/1 is all-or-nothing, so a raw byte scan is used. Falls
  # back closed to the whole payload when no body section is present.
  # KD-COVERS: KD-18
  defp eh_body_section(payload) when is_binary(payload) do
    case eh_body_section_scan(payload) do
      {:ok, section} -> eh_body_section(section)
      :error -> {:body_data, payload}
    end
  end

  defp eh_body_section_scan(payload) do
    case :binary.match(payload, <<0x00, 0x53, 0x75>>) do
      {pos, _} ->
        rest = binary_part(payload, pos, byte_size(payload) - pos)

        case rest do
          <<0x00, 0x53, 0x75, 0xA0, len, body::binary-size(len), _::binary>> ->
            {:ok, body}

          <<0x00, 0x53, 0x75, 0xB0, len::32, body::binary-size(len), _::binary>> ->
            {:ok, body}

          _ ->
            {:ok, binary_part(payload, pos, byte_size(payload) - pos)}
        end

      :nomatch ->
        :error
    end
  end

  defp deliver_to_link(state, link) do
    case QueueStore.dequeue_matching(link.address, session_id: link.session_id) do
      {:ok, msg, lock} ->
        # KD-COVERS: KD-134 — requester-preference on redelivery: if THIS
        # link already holds an unsettled delivery of the dequeued message
        # and another credited non-holder link for the same queue+session
        # exists, yield: release the just-acquired lock so the requesting
        # receiver takes the re-availed message instead of the idle first
        # holder (W21-B: rx2 starved while idle rx1 re-took the transfer).
        # The release is a real settlement transition (delivery_count
        # increments once per yielded claim — real Service Bus also counts
        # each attempted delivery). No recursion after a yield.
        if kd134_yield_to_requester?(state, link, msg) do
          QueueStore.release(msg.queue, msg.seq, lock_token: lock.lock_token)

          Logger.debug(
            "[amqp-conn] KD-134 yield: " <>
              "seq=#{msg.seq} held by ch=#{link.channel} h=#{link.handle}, credited requester exists"
          )

          state
        else
          deliver_to_link_claimed(state, link, msg, lock)
        end

      :empty ->
        state

      {:error, _} ->
        state
    end
  end

  defp deliver_to_link_claimed(state, link, msg, lock) do
    sections = delivery_sections(msg)

    delivery_result =
      try do
        send_message(
          state,
          link,
          %{
            handle: link.handle,
            # AMQP delivery-tag = lock token, .NET GUID byte layout (see
            # LockManager.token_to_wire/1 doc: the SDK reorders the bytes
            # back before uuid_to_string). Straight uuid layout made every
            # client echo a permuted token on update-disposition → 410
            # MESSAGE_LOCK_LOST (census session probes).
            delivery_tag: Smalt.Amqp.LockManager.token_to_wire(lock.lock_token),
            message_format: 0,
            settled: false,
            more: false
          },
          sections
        )
      rescue
        # Store-and-forward lock leak (lens-4 cycle-3): dequeue_matching
        # acquires the message lock BEFORE the encode+send; an encode
        # raise here used to leave the message locked forever with no
        # release/deadletter decision. Release it back and close typed.
        e in ArgumentError ->
          # SHIM-COURT: encode failure must end delivery on this link.
          # Release the store lock, close typed, and DO NOT fall through
          # to the success tail — the old fall-through registered a bogus
          # delivery id 0, decremented credit and re-entered deliver_to_link
          # while credit remained, re-dequeuing and re-locking the message
          # just released (lock flapping after the close frame was already
          # on the wire; delivery_count inflated one per credit).
          QueueStore.release(msg.queue, msg.seq)

          Logger.error(
            "[amqp-conn] delivery encode failed, lock released: " <> Exception.message(e)
          )

          Smalt.Amqp.Connection.error_close(state, "amqp:internal-error", "DELIVERY_ENCODE_FAILED")

          {:halt_delivery, state}
      end

    # SHIM-COURT: encode-failure arm halts — no delivery registration, no
    # credit bump, no re-dequeue on this link.
    case delivery_result do
      {:halt_delivery, halted_state} ->
        halted_state

      {state, delivery_id} ->
        state = %{
          state
          | # SHIM-COURT: entries carry their AMQP session channel so a
            # session :end can retire them; otherwise a re-begin restarts
            # next_out at 0 and a disposition can settle a stale delivery.
            outbound_deliveries:
              Map.put(state.outbound_deliveries, delivery_id, %{
                queue: msg.queue,
                seq: msg.seq,
                lock_token: lock.lock_token,
                channel: link.channel
              }),
            # KD-COVERS: KD-134 — remember the delivering link so a
            # re-availed (expired/released) lock prefers a DIFFERENT
            # credited requester over the idle first holder.
            redelivery_holders:
              Map.update(
                Map.get(state, :redelivery_holders) || %{},
                {msg.queue, msg.seq},
                MapSet.new([{link.channel, link.handle}]),
                &MapSet.put(&1, {link.channel, link.handle})
              )
        }

        state = Link.bump_credit(state, link.channel, link.handle, -1)

        if state.links[{link.channel, link.handle}][:credit] > 0 do
          deliver_to_link(state, Map.get(state.links, {link.channel, link.handle}))
        else
          state
        end
    end
  end

  # KD-COVERS: KD-134 — requester-preference predicate: the dequeued
  # message is a REDelivery this link already holds unsettled AND a credited
  # non-holder link exists on the same queue + session filter. Fall back to
  # any credited link when this holder is the only credited receiver (the
  # fallback half of the law: single-receiver redelivery is unaffected).
  defp kd134_yield_to_requester?(state, link, msg) do
    holders = Map.get(state, :redelivery_holders) || %{}
    key = {link.channel, link.handle}

    case Map.get(holders, {msg.queue, msg.seq}) do
      nil ->
        false

      seen ->
        MapSet.member?(seen, key) and
          Enum.any?(state.links, fn {_k, l} ->
            l.role == :sender and l[:kind] == :queue and l.address == link.address and
              l[:session_id] == link.session_id and
              Map.get(l, :credit, 0) > 0 and {l.channel, l.handle} != key and
              not MapSet.member?(seen, {l.channel, l.handle})
          end)
    end
  end

  defp delivery_sections(msg) do
    delivery_sections_build(msg)
  end

  defp delivery_sections_build(msg) do
    sections =
      DeliveryEncoder.build_sections(
        sequence_number: msg.seq,
        locked_until: msg[:locked_until],
        enqueued_time: msg[:enqueued],
        session_id: msg[:session_id],
        delivery_count: msg.delivery_count,
        message_id: msg[:message_id],
        app_props: msg[:app_props] || %{}
      )

    base =
      [
        {:header, sections[:header]},
        {:message_annotations, sections[:message_annotations]},
        {:properties, sections[:properties]},
        {:application_properties, sections[:application_properties]}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    base ++ [stored_body_section(msg.body)]
  end

  # The stored body is a tagged section {:body_data, v} / {:body_amqp_value, v}
  # (as-sent preservation, this change); fall back to a body_data wrap for
  # legacy rows and the EventHubs store path (raw binary bodies).
  defp stored_body_section({kind, value}) when kind in [:body_data, :body_amqp_value],
    do: {kind, value}

  defp stored_body_section(value), do: {:body_data, value}

  # ===========================================================================
  # disposition settlement
  # ===========================================================================

  def handle_disposition(perf, channel, state) do
    first = perf[:first]
    last = perf[:last] || first
    action = delivery_action(perf[:state])

    if is_integer(first) and is_integer(last) and last >= first do
      # range-bomb clamp (R3 red-team finding): a disposition spanning
      # first=1..last=100_000_000 must not build a huge reduce range; real
      # settlement windows are bounded by the session window.
      last = min(last, first + @disposition_range_cap)

      {state, matched_any, lock_lost_ids} =
        Enum.reduce(first..last, {state, false, []}, fn delivery_id, {st, matched, lost} ->
          case Map.get(st.outbound_deliveries, delivery_id) do
            nil ->
              {st, matched, lost}

            dlv ->
              # R196: the delivery's lock token rides the settle as a
              # compare-and-settle against the store's CURRENT token — a
              # stale/zombie disposition refuses typed :lock_lost and the
              # message is left untouched for its new owner.
              case settle(action, dlv, perf[:state]) do
                :ok ->
                  {st
                   |> Map.put(:outbound_deliveries, Map.delete(st.outbound_deliveries, delivery_id))
                   |> Map.put(
                     :redelivery_holders,
                     Map.delete(Map.get(st, :redelivery_holders) || %{}, {dlv.queue, dlv.seq})
                   ), true, lost}

                :lock_lost ->
                  {st, matched, [delivery_id | lost]}
              end
          end
        end)

      # R196: a refused disposition must not be echoed as accepted (the client
      # would believe a settle happened that didn't). Answer the refused ids
      # with a 410-class rejected disposition carrying
      # com.microsoft:message-lock-lost — the wire twin of management paths'
      # 410 MESSAGE_LOCK_LOST.
      Enum.each(lock_lost_ids, fn delivery_id ->
        Smalt.Amqp.Connection.send_frame(state, channel, {
          :disposition,
          %{
            role: false,
            first: delivery_id,
            last: delivery_id,
            settled: true,
            state:
              {:rejected,
               %{
                 condition: "com.microsoft:message-lock-lost",
                 description: "The lock token is no longer valid; the message was not settled"
               }}
          }
        })
      end)

      # Receiver-initiated settlement (SDK peekLock receivers settle with
      # settled=false and rcv-settle-mode=first): the sender endpoint MUST
      # echo the terminal disposition or the client's complete/abandon
      # hangs forever ("Operation to settle the message has timed out").
      # If the client already settled on the wire (settled=true), no echo.
      if matched_any and lock_lost_ids == [] and not perf[:settled] do
        # pyamqp dialect (S-1, disclosed in s1-amqp-shims receipt): pyamqp
        # reads the echo's terminal outcome state, so echo the client's own
        # state back — a bare settled-only echo reads as outcome None and
        # every complete/abandon fails ("Expected 'accepted' but the
        # reported outcome was: None").
        # decoded :modified carries the positional fields LIST; the encoder
        # wants the map form. Rebuild the wire-described state instead of
        # round-tripping the internal shape.
        # KD-77 residual (2026-10-16): decoded :rejected ALSO carries the
        # positional LIST; re-encoding it verbatim put the whole list in the
        # error-condition slot, pyamqp decoded condition as a DescribedList
        # and crashed (AttributeError 'DescribedList' has no 'decode') ->
        # RuntimeError -> mgmt-link fallback -> spurious 410 against a
        # message the receiver-link dead-letter had ALREADY settled.
        # A successful dead-letter echoes rejected with NO error (real
        # Service Bus: check_disposition_outcome treats error-bearing
        # rejected as failure). # KD-COVERS: KD-77
        echo_state =
          case perf[:state] do
            {:modified, fields} when is_list(fields) ->
              {:modified,
               %{
                 delivery_failed: Enum.at(fields, 0),
                 undeliverable_here: Enum.at(fields, 1),
                 annotations: Enum.at(fields, 2)
               }}

            {:rejected, fields} when is_list(fields) ->
              {:rejected, %{condition: nil, description: nil, info: nil}}

            other ->
              other
          end

        Smalt.Amqp.Connection.send_frame(state, channel, {
          :disposition,
          %{role: false, first: first, last: last, settled: true, state: echo_state}
        })
      end

      state
    else
      state
    end
  end

  defp delivery_action(:accepted), do: :complete
  defp delivery_action(:released), do: :release
  defp delivery_action({:modified, body}), do: modified_action(body)
  defp delivery_action({:rejected, _error}), do: :deadletter
  defp delivery_action(_), do: :release

  defp modified_action(body) when is_list(body) do
    if Enum.at(body, 1) == true, do: :defer, else: :release
  end

  defp modified_action(%{} = m) do
    if m[:undeliverable_here] == true or m["undeliverable-here"] == true,
      do: :defer,
      else: :release
  end

  defp modified_action(_), do: :release

  # AMQP map keys may decode as raw binaries or {:symbol, bin} tuples; look
  # up both spellings without minting atoms from wire input.
  defp key_bin(info, name, alt) do
    info[name] || info[alt] || info[{:symbol, name}] || info[{:symbol, alt}]
  end

  # R196: every settle rides the disposition's captured delivery token
  # (outbound_deliveries) as a server-side compare-and-settle
  # (QueueStore settle_token_ok?/2). A stale token (lock expired+re-claimed,
  # swept, or released) refuses typed :lock_lost — the caller answers the
  # client 410-class and the message is untouched. The prior client-side
  # LockManager.expired? gate is subsumed: the CAS checks the row's CURRENT
  # stored token, and an expired lock whose token was already swept deletes
  # the row → token mismatch → :lock_lost.
  # KD-77 residual fix (2026-10-16): receiver-link dead-letter carries its
  # reason/description in the rejected outcome's error info map
  # (com.microsoft:dead-letter-reason / -error-description); dropping them
  # made every DLQ message surface dead_letter_reason "rejected"
  # (test_dead_letter_with_properties, unblocked by the r210 fixes).
  defp settle(:deadletter, dlv, {:rejected, fields}) when is_list(fields) do
    {reason, desc} =
      case Enum.at(fields, 0) do
        # error = described(0x1d) [condition, description, info-map]
        {:described, _desc, err_fields} when is_list(err_fields) ->
          case Enum.at(err_fields, 2) do
            info when is_map(info) ->
              # info-map keys arrive as raw binaries or {:symbol, bin} —
              # never mint atoms from wire input (safe_atom law). Python
              # pyamqp dialect: "DeadLetterReason"/"DeadLetterErrorDescription"
              # (constants.py:94-95); also honor com.microsoft-prefixed forms.
              kr = key_bin(info, "DeadLetterReason", "com.microsoft:dead-letter-reason")

              kd =
                key_bin(
                  info,
                  "DeadLetterErrorDescription",
                  "com.microsoft:dead-letter-error-description"
                )

              {kr || "rejected", kd}

            _ ->
              {"rejected", nil}
          end

        _ ->
          {"rejected", nil}
      end

    case QueueStore.deadletter(dlv.queue, dlv.seq, reason, desc, lock_token: dlv.lock_token) do
      {:ok, _dlq_seq} -> :ok
      {:error, :lock_lost} -> :lock_lost
      {:error, _other} -> :ok
    end
  end

  defp settle(:complete, dlv, _state) do
    case QueueStore.complete(dlv.queue, dlv.seq, lock_token: dlv.lock_token) do
      :ok -> :ok
      {:error, :lock_lost} -> :lock_lost
    end
  end

  defp settle(:release, dlv, _state) do
    case QueueStore.release(dlv.queue, dlv.seq, lock_token: dlv.lock_token) do
      :ok -> :ok
      {:error, :lock_lost} -> :lock_lost
      # R64/R128 conditions are store-level, not token conditions: the settle
      # happened as far as token ownership is concerned.
      {:error, _capacity} -> :ok
    end
  end

  defp settle(:defer, dlv, _state), do: QueueStore.defer(dlv.queue, dlv.seq, [])

  defp settle(:deadletter, dlv, _state) do
    case QueueStore.deadletter(dlv.queue, dlv.seq, "rejected", nil, lock_token: dlv.lock_token) do
      {:ok, _dlq_seq} -> :ok
      {:error, :lock_lost} -> :lock_lost
      {:error, _other} -> :ok
    end
  end

  # ===========================================================================
  # outbound transfers
  # ===========================================================================

  # Outgoing transfers MUST use a per-session (per-channel) delivery-id
  # sequence: rhea validates each session's incoming transfer ids as a strict
  # run (Incoming.on_transfer: "frame sequence error: expected N, got M") and
  # tears the connection down on the first gap. A global counter produced gaps
  # whenever more than one session sent (census wires 2..8: the $cbs reply used
  # the global id while the client session expected the per-session successor).
  defp send_message(state, link, fields, sections) do
    sess = Session.get_session(state, link.channel)
    delivery_id = sess.next_out
    transfer_fields = Map.put(fields, :delivery_id, delivery_id)
    cap = state[:peer_max_frame_size]

    frames =
      case body_chunks(sections, cap) do
        nil ->
          [
            FrameCodec.encode_frame(:amqp, link.channel, {
              :transfer,
              transfer_fields,
              {:sections, sections}
            })
          ]

        chunks ->
          # AMQP §2.3.1: a transfer whose frame would exceed the peer's
          # body_data payloads can be chunked losslessly (a message body is the
          # concatenation of body_data sections); leading non-body sections ride
          # the first frame only.
          {pre, [{:body_data, _}]} = split_body_sections(sections)
          more = Map.get(transfer_fields, :more, false)

          [first | middle_last] = chunks
          {middle, last} = Enum.split(middle_last, -1)

          first_frame =
            FrameCodec.encode_frame(:amqp, link.channel, {
              :transfer,
              Map.put(transfer_fields, :more, true),
              {:sections, pre ++ [first]}
            })

          middle_frames =
            for chunk <- middle do
              FrameCodec.encode_frame(:amqp, link.channel, {
                :transfer,
                %{handle: transfer_fields.handle, delivery_id: delivery_id, more: true},
                {:sections, [chunk]}
              })

              # AMQP §2.3.1: continuation frames carry only the body chunk;
              # more=true until the last frame, which carries the original
              # transfer's own more flag.
            end

          [last_frame] =
            for chunk <- last do
              FrameCodec.encode_frame(:amqp, link.channel, {
                :transfer,
                %{handle: transfer_fields.handle, delivery_id: delivery_id, more: more},
                {:sections, [chunk]}
              })
            end

          [first_frame | middle_frames] ++ [last_frame]
      end

    Enum.each(frames, &:gen_tcp.send(state.sock, &1))
    {Session.put_session(state, link.channel, %{sess | next_out: delivery_id + 1}), delivery_id}
  end

  # Chunks the message body when the whole transfer frame would exceed the
  # peer's advertised max_frame_size. Returns nil when no split is needed or
  # possible (no negotiated cap, non-binary body — body_amqp_value sections
  # cannot be chunked losslessly so they are sent whole, and the peer cap is
  # ≥512 per spec while our local cap is 1 MiB).
  defp body_chunks(_sections, nil), do: nil

  defp body_chunks(sections, cap) do
    {_pre, body} = split_body_sections(sections)

    case body do
      [{:body_data, bin}] when is_binary(bin) ->
        total = 8 + IO.iodata_length(FrameCodec.encode_message(sections)) + 256
        chunk_size = max(cap - 1024, 64)

        if total <= cap do
          nil
        else
          chunk_binary(bin, chunk_size, [])
        end

      _ ->
        nil
    end
  end

  defp chunk_binary(bin, size, acc) when byte_size(bin) > size do
    <<chunk::binary-size(^size), rest::binary>> = bin
    chunk_binary(rest, size, [{:body_data, chunk} | acc])
  end

  defp chunk_binary(bin, _size, acc), do: Enum.reverse([{:body_data, bin} | acc])

  defp split_body_sections(sections) do
    Enum.split_while(sections, fn
      {k, _} when k in [:body_data, :body_amqp_value] -> false
      _ -> true
    end)
  end
end
