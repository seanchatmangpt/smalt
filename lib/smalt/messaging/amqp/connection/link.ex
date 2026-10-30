defmodule Smalt.Amqp.Connection.Link do
  @moduledoc """
  AMQP link endpoint: attach routing (queue / `$cbs` / `$management` /
  Event Hubs), detach, credit bookkeeping, EH selector-filter + epoch
  exclusivity, and the address-normalization helpers — extracted verbatim
  from `Smalt.Amqp.Connection` (T08, v26.10.29).

  BYTE-PINION SURFACE — do not "clean up":

  - attach top-level fields `<= 14`, locale fields omitted (source=8 /
    target=7 composite arity tripwires).
  - EH fixed partitions `["0", "1"]` (out-of-pin partition attach is
    refused with an echo-attach + typed detach).
  - .NET-GUID lock-token byte reordering lives in
    `Smalt.Amqp.LockManager.token_to_wire/1` (delivery-tag pinion).
  """

  alias Smalt.Amqp.CbsRouter
  alias Smalt.Amqp.Connection.{Delivery, Session}
  alias Smalt.Amqp.QueueStore
  alias Smalt.Amqp.DeliveryEncoder
  alias Smalt.Messaging.EventHubs

  @eh_selector_key "apache.org:selector-filter:string"
  @eh_epoch_key "com.microsoft:epoch"

  # ===========================================================================
  # attach
  # ===========================================================================

  def handle_attach(perf, channel, state) do
    client_role = if perf.role == true, do: :receiver, else: :sender
    # our endpoint role is the inverse of the client's
    our_role = if client_role == :sender, do: :receiver, else: :sender

    address =
      if client_role == :sender do
        address_of(perf.target)
      else
        address_of(perf.source)
      end

    # Repair lane R96: pyamqp-dialect clients attach queue links with the FULL
    # "amqps://host:port/entity" source/target, but every store key (message
    # rows {queue, seq}, session locks {queue, sid}, ARM queue settings suffix
    # "/queues/<name>", management get-message-sessions queue field) is keyed
    # by the BARE entity name. Without stripping, queue_settings missed the
    # ARM row (requiresSession never fired for real SDK attaches) and
    # get-message-sessions keyed on the bare name found nothing stored under
    # NOTE: URI-form addresses are normalized to the bare entity name AFTER
    # the authorized? gate below — the CBS token audience is keyed by the full
    # scheme://host:port/entity form, so the raw address is what authorized?
    # must see.
    kind = route(address, state.mode)

    # Fixed-partition pinion: a partition-scoped EH attach outside the pinned
    # set ["0","1"] is refused (echo-attach + typed detach — the rhea/core-amqp
    # contract needs the attach echo first). Send side pins storage to the pair
    # (eh_pk_partition), so an out-of-pin receiver could never be delivered to.
    if kind == :eventhubs and eh_partition_scope(address) == :refused do
      Smalt.Amqp.Connection.send_frame(state, channel, {
        :attach,
        %{
          name: perf.name,
          handle: perf.handle,
          role: our_role == :receiver,
          initial_delivery_count: 0
        }
      })

      Smalt.Amqp.Connection.send_frame(state, channel, {
        :detach,
        %{
          handle: perf.handle,
          closed: true,
          error: %{
            condition: "amqp:not-allowed",
            description: "partition outside the fixed set [\"0\",\"1\"]"
          }
        }
      })

      state
    else
      # rhea (core-amqp) requires the broker attach echo BEFORE any detach
      # (Session.on_attach populates remote.handles only on attach; a bare
      # detach raises "Invalid handle N" client-side). Echo attach, then
      # detach typed.
      if kind == :queue and not authorized?(address) do
        Smalt.Amqp.Connection.send_frame(state, channel, {
          :attach,
          %{
            name: perf.name,
            handle: perf.handle,
            role: our_role == :receiver,
            initial_delivery_count: 0
          }
        })

        Smalt.Amqp.Connection.send_frame(state, channel, {
          :detach,
          %{handle: perf.handle, closed: true, error: unauthorized_error()}
        })

        state
      else
        {kind, address} = normalize_dql_casing(kind, address)

        # Repair lane R96: pyamqp-dialect clients attach queue links with the
        # FULL "amqps://host:port/entity" source/target, but every store key
        # (message rows {queue, seq}, session locks {queue, sid}, ARM queue
        # settings suffix "/queues/<name>", management get-message-sessions
        # queue field) is keyed by the BARE entity name. Without stripping,
        # queue_settings missed the ARM row (requiresSession never fired for
        # real SDK attaches) and get-message-sessions keyed on the bare name
        # found nothing stored under the URI form (session receiver starved +
        # enumeration returned []). Normalization stays AFTER the authorized?
        # gate: the CBS token audience is keyed by the full scheme://host:port
        # form, so the raw address is what authorized? must see.
        address = bare_entity(address)

        link = %{
          name: Smalt.Amqp.Connection.plain(perf.name),
          handle: perf.handle,
          channel: channel,
          role: our_role,
          session_id: extract_session_filter(perf.source),
          eh_cursor: 0,
          # GAP-A2-01/02 (KD-68/KD-69): per-link EH receiver cursor state —
          # eh_start is the eventPosition the receiver attached with, eh_cursor
          # tracks what THIS link has delivered, eh_min_enqueued carries an
          # enqueuedTime filter floor (epoch ms), eh_epoch the exclusive-receiver
          # epoch (com.microsoft:epoch).
          eh_start: nil,
          eh_link_cursor: nil,
          eh_min_enqueued: nil,
          eh_epoch: nil,
          address: address,
          kind: kind,
          credit: 0,
          partial: nil
        }

        # Disclosed cross-lane unblock (s5_sessions e2e lane): the Service Bus
        # SDK derives the granted session id from the attach response's source
        # filter (com.microsoft:session-filter). Without the source echo it
        # reads undefined and fails acceptSession with "session may be locked".
        # KD-COVERS: KD-49
        base_attach = %{
          name: perf.name,
          handle: perf.handle,
          role: our_role == :receiver,
          initial_delivery_count: 0,
          # KD-49 shim: echo the client's own source/target back. pyamqp
          # `_incoming_attach` requires both descriptors ("Invalid link" ->
          # detach otherwise); rhea tolerates the omission. frame_codec trims
          # nil, so a nil side is trimmed as before. The session case below
          # Map.merge's over these keys and still wins.
          source: perf.source,
          target: perf.target
        }

        # The enriched link must escape through the case result: rebinding `link`
        # inside a case branch does NOT leak to the enclosing scope (Elixir
        # scoping — the enriched value was silently dropped here, so every EH
        # selector/epoch receiver registered with eh_start/eh_epoch = nil,
        # GAP-A2-01/02 falsifier failures R69).
        {attach_fields, state, eh_link} =
          case {kind, our_role, link.session_id} do
            {:queue, :sender, sid} when is_binary(sid) and sid != "" ->
              # R178e (census stale-handle): the session lock must ride the
              # QUEUE's configured lockDuration (ARM/ATOM record), not the
              # LockManager default — expiry lands on the created schedule or
              # a PT15S session stays locked 30s and the post-expiry re-acquire
              # is refused SessionCannotBeLocked.
              case Smalt.Amqp.LockManager.session_acquire(address, sid,
                     duration_ms: QueueStore.queue_settings(address).lock_duration_ms
                   ) do
                {:ok, slock} ->
                  fields =
                    Map.merge(base_attach, %{
                      source: %{
                        address: address,
                        filter: {:map_rhea, %{{:symbol, "com.microsoft:session-filter"} => sid}}
                      },
                      properties: %{
                        # .NET filetime (100ns ticks since 0001-01-01), not
                        # raw-microseconds: the plain *10_000 multiply misses
                        # the epoch offset (~1969 years) and every real client
                        # read a lock expiry in 1969 (docs-lane finding).
                        "com.microsoft:locked-until-utc" =>
                          DeliveryEncoder.filetime_from_ms(slock.locked_until)
                      }
                    })

                  {fields, state, link}

                {:error, :already_locked} ->
                  # rhea (core-amqp) requires the broker attach echo BEFORE any
                  # detach: Session.on_attach populates remote.handles only on
                  # the attach, and a bare detach raises "Invalid handle N",
                  # crashing the client before it can map the error (census
                  # exclusive-session probe). Echo attach, then detach typed.
                  Smalt.Amqp.Connection.send_frame(state, channel, {:attach, base_attach})

                  Smalt.Amqp.Connection.send_frame(state, channel, {
                    :detach,
                    %{
                      handle: perf.handle,
                      closed: true,
                      error: %{
                        condition: "com.microsoft:session-cannot-be-locked",
                        description: "SESSION_CANNOT_BE_LOCKED"
                      }
                    }
                  })

                  {nil, state, link}
              end

            # R129 exploit 2 (W5-17): an UNFILTERED receiver (no
            # com.microsoft:session-filter) on a requiresSession queue used to
            # fall through to the catch-all clause and register with
            # session_id: nil — claim_candidates' nil filter then matched ALL
            # messages, draining other sessions' locked messages. Real Azure
            # refuses this attach: echo the attach, then detach typed
            # (session-cannot-be-locked class). Same echo-then-detach ordering
            # as the already_locked refusal above (rhea needs the broker echo
            # before any detach). A queue that does NOT require sessions
            # (including unknown queues -> default settings) passes through to
            # the default clause unchanged.
            {:queue, :sender, sid}
            when is_nil(sid) or sid == "" ->
              cond do
                # KD-COVERS: KD-121
                # KD-121: acceptNextSession sends a session-filter attach with
                # a NULL selector. extract_session_filter reads it as nil, so
                # this attach used to fall through to the unfiltered passthrough
                # (no session-filter echo, no locked-until-utc properties) and
                # the SDK's messageSession.js threw TypeError on the missing
                # lock fields. Real broker behavior: pick the next unlocked
                # session, lock it, and echo the attach with the chosen sid +
                # lock fields; none available -> echo + typed detach (the SDK
                # surfaces the detach error as a clean translated failure).
                nil_session_filter?(perf.source) ->
                  case next_unlocked_session(address) do
                    {sid2, slock} ->
                      fields =
                        Map.merge(base_attach, %{
                          source: %{
                            address: address,
                            filter:
                              {:map_rhea, %{{:symbol, "com.microsoft:session-filter"} => sid2}}
                          },
                          properties: %{
                            "com.microsoft:locked-until-utc" =>
                              DeliveryEncoder.filetime_from_ms(slock.locked_until)
                          }
                        })

                      {fields, state, link}

                    :none ->
                      Smalt.Amqp.Connection.send_frame(state, channel, {:attach, base_attach})

                      Smalt.Amqp.Connection.send_frame(state, channel, {
                        :detach,
                        %{
                          handle: perf.handle,
                          closed: true,
                          error: %{
                            condition: "com.microsoft:session-cannot-be-locked",
                            description: "NO_UNLOCKED_SESSIONS_AVAILABLE"
                          }
                        }
                      })

                      {nil, state, link}
                  end

                # R129 exploit 2 (W5-17): an UNFILTERED receiver (no
                # com.microsoft:session-filter) on a requiresSession queue
                # falls to the catch-all clause and registered with
                # session_id: nil — claim_candidates' nil filter then matched
                # ALL messages, draining other sessions' locked messages. Real
                # Azure refuses this attach: echo the attach, then detach typed
                # (session-cannot-be-locked class). Same echo-then-detach
                # ordering as the acceptNextSession refusal above (rhea needs
                # the broker echo before any detach). A queue that does NOT
                # require sessions (including unknown queues -> default
                # settings) passes through to the default clause unchanged.
                QueueStore.queue_settings(address).requires_session ->
                  Smalt.Amqp.Connection.send_frame(state, channel, {:attach, base_attach})

                  Smalt.Amqp.Connection.send_frame(state, channel, {
                    :detach,
                    %{
                      handle: perf.handle,
                      closed: true,
                      error: %{
                        condition: "com.microsoft:session-cannot-be-locked",
                        description: "SESSION_CANNOT_BE_LOCKED"
                      }
                    }
                  })

                  {nil, state, link}

                true ->
                  {base_attach, state, link}
              end

            # GAP-A2-01/02 (KD-68/KD-69): EH receiver attach — read the
            # `apache.org:selector-filter:string` source filter as the
            # eventPosition start cursor and enforce com.microsoft:epoch
            # exclusive-receiver semantics on the partition + consumer group.
            {:eventhubs, :sender, _} ->
              partition = eh_partition(address)

              link = Map.put(link, :eh_epoch, eh_attach_epoch(perf))

              # KD-68 (r200c falsifier FIRED): a present-but-unparseable
              # selector must detach typed, never silently pass through
              # unfiltered (that is the exact vacuity the falsifier caught).
              case eh_apply_selector_filter(link, perf, partition) do
                {:ok, link} ->
                  # rhea (core-amqp) requires the broker attach echo BEFORE any
                  # detach on this session (same rule as the session-cannot-be-
                  # locked refusal above). Echo first, THEN evict/refuse by epoch.
                  Smalt.Amqp.Connection.send_frame(state, channel, {:attach, base_attach})

                  case eh_epoch_admit(link, address, state) do
                    {:ok, state} ->
                      # The echo was already sent above; the outer registration
                      # case must not echo again.
                      {:echoed, state, link}

                    {:refused, state} ->
                      Smalt.Amqp.Connection.send_frame(state, channel, {
                        :detach,
                        %{
                          handle: perf.handle,
                          closed: true,
                          error: eh_epoch_error("EPOCH_REFUSED", link.eh_epoch)
                        }
                      })

                      {nil, state, link}
                  end

                {:error, selector} ->
                  # SHIM-COURT KD-68: unsupported selector form -> attach echo
                  # then typed detach (rhea needs the echo before any detach).
                  Smalt.Amqp.Connection.send_frame(state, channel, {:attach, base_attach})

                  Smalt.Amqp.Connection.send_frame(state, channel, {
                    :detach,
                    %{
                      handle: perf.handle,
                      closed: true,
                      error: eh_selector_error(selector)
                    }
                  })

                  {nil, state, link}
              end

            _ ->
              {base_attach, state, link}
          end

        case attach_fields do
          nil ->
            # Refused attach (session-cannot-be-locked): the attach echo + typed
            # detach were already sent. The link must NOT be registered: a later
            # cleanup detach from the client for this handle would then match
            # link_by_handle and — queue+session link that it is — release the
            # session lock held by the *legitimate* receiver, killing its
            # renewSessionLock (census exclusive-session probe, wire-traced
            # 09:16:22.501→.502 detach ch=2 h=0).
            state

          :echoed ->
            # EH epoch path (GAP-A2-02): the attach echo was already sent before
            # eviction/refusal — register the link without re-echoing. EH
            # receivers get credit from the client's own flow, none is granted
            # here.
            %{state | links: Map.put(state.links, {channel, perf.handle}, eh_link)}

          _ ->
            Smalt.Amqp.Connection.send_frame(state, channel, {:attach, attach_fields})

            # grant link credit for client-sender links so peer transfers can flow.
            # delivery_count MUST be present: rhea computes sender credit as
            # `flow.delivery_count + flow.link_credit - this.delivery_count`
            # (rhea/lib/link.js Sender.prototype.on_flow); omitting it makes the
            # credit NaN and 'sendable' never fires (every send times out).
            # It must agree with the attach reply's initial_delivery_count (0).
            eh_link =
              if client_role == :sender do
                Session.send_flow(state, channel, %{
                  handle: perf.handle,
                  delivery_count: 0,
                  link_credit: 1000
                })

                %{eh_link | credit: 1000}
              else
                eh_link
              end

            %{state | links: Map.put(state.links, {channel, perf.handle}, eh_link)}
        end
      end
    end
  end

  def handle_detach(perf, ch, state) do
    case link_by_handle(state, ch, perf.handle) do
      nil ->
        state

      link ->
        # Release a held session lock when its receiver link detaches, so a
        # subsequent acceptSession can acquire it (real Service Bus parity).
        # Role note: the lock-holding link is a client-RECEIVER session link,
        # whose SERVER-side role is :sender — the previous :receiver gate
        # never matched and the lock waited out the TTL (s5 probe 6).
        if link.kind == :queue and link.role == :sender and is_binary(link.session_id) and
             link.session_id != "" do
          Smalt.Amqp.LockManager.session_release(link.address, link.session_id)
        end

        # GAP-A2-02: release this link's exclusive-receiver registration so a
        # subsequent epoch attach admits (only if it still names THIS link).
        eh_epoch_release(link)

        Smalt.Amqp.Connection.send_frame(state, link.channel, {:detach, %{handle: perf.handle, closed: true}})
        %{state | links: Map.delete(state.links, {ch, perf.handle})}
    end
  end

  # ===========================================================================
  # attach routing helpers
  # ===========================================================================

  def route(nil, _mode), do: :unknown
  def route("$cbs", _mode), do: :cbs

  def route(address, mode) when is_binary(address) do
    cond do
      # Precise management rule (replaces substring match): real SDKs attach
      # the management node as bare "$management" (CBS-style) or as the
      # per-entity node "<entity>/$management" (azure-servicebus
      # managementClient.js). A queue merely NAMED e.g. "my-management-queue"
      # must route as a queue, never :management.
      address == "$management" or String.ends_with?(address, "/$management") -> :management
      mode == :eh -> :eventhubs
      String.contains?(address, "/eventhubs/") -> :eventhubs
      true -> :queue
    end
  end

  def route(_, _), do: :unknown

  # SDKs send "$DeadLetterQueue" capitalized; the store uses lowercase.
  defp normalize_dql_casing(kind, address) when is_binary(address) do
    if kind == :queue and String.contains?(address, "$DeadLetterQueue") do
      {:queue, String.replace(address, "$DeadLetterQueue", "$deadletterqueue")}
    else
      {kind, address}
    end
  end

  defp normalize_dql_casing(kind, address), do: {kind, address}

  # com.microsoft:session-filter selector (FrameCodec decodes it as
  # {:session_filter, selector})
  defp extract_session_filter(%{
         filter: %{"com.microsoft:session-filter" => {:session_filter, selector}}
       }),
       do: selector

  defp extract_session_filter(%{filter: %{session_filter: selector}}), do: selector
  defp extract_session_filter(_), do: nil

  # KD-121: acceptNextSession attaches with the session-filter symbol PRESENT
  # but a NULL selector. extract_session_filter/1 reads that as nil — same as
  # "no filter" — so the attach used to be indistinguishable from an
  # unfiltered attach. Predicate: symbol present AND selector reads nil.
  defp nil_session_filter?(%{filter: f}) when is_map(f) do
    symbol_present? =
      Enum.any?(f, fn {k, _} ->
        key = if is_atom(k), do: Atom.to_string(k), else: k
        key == "com.microsoft:session-filter"
      end)

    symbol_present? and extract_session_filter(%{filter: f}) == nil
  end

  defp nil_session_filter?(_), do: false

  # KD-121: pick the next unlocked session for acceptNextSession. Enumerates
  # the queue's real session records (skip:0, top:100) and acquires the lock
  # on the first that yields; all locked/none -> :none.
  defp next_unlocked_session(address) do
    case QueueStore.list_sessions(address, skip: 0, top: 100, since: nil) do
      {:ok, entries} when is_list(entries) ->
        Enum.find_value(entries, :none, fn e ->
          case Smalt.Amqp.LockManager.session_acquire(address, e.session_id,
                 duration_ms: QueueStore.queue_settings(address).lock_duration_ms
               ) do
            {:ok, slock} -> {e.session_id, slock}
            {:error, _} -> nil
          end
        end)

      _ ->
        :none
    end
  end

  defp address_of(nil), do: nil
  defp address_of(%{address: a}), do: address_of(a)
  defp address_of(bin) when is_binary(bin), do: bin
  defp address_of({:symbol, s}) when is_binary(s), do: s

  defp address_of({:described, _d, fields}) when is_list(fields),
    do: address_of(Enum.at(fields, 0))

  defp address_of(_), do: nil

  # Repair lane R96: strip the "scheme://host[:port]/" prefix off an attach
  # address, leaving the bare entity name. Only fires on amqp/amqps/sb scheme
  # forms; bare names, "$cbs"/"$management" and EH path forms pass through.
  defp bare_entity(address) when is_binary(address) do
    case String.split(address, "://", parts: 2) do
      [scheme, rest] when scheme in ["amqp", "amqps", "sb"] ->
        case String.split(rest, "/", parts: 2) do
          [_host, entity] when is_binary(entity) and entity != "" ->
            # R129 exploit 1 (W5-17): "amqps://h:5671/q/" previously fell
            # through the entity != "" guard and kept the FULL URI as the
            # store key — a distinct queue namespace that bypassed the
            # requiresSession gate (enqueue to "q/" succeeded without a
            # session while "q" required one). Strip trailing slashes so
            # "q/" normalizes to "q". Empty-after-strip ("amqps://h/")
            # keeps the original guard: the address passes through
            # unchanged, still failing closed against the session gate.
            # Percent-decoding is deliberately NOT done (parked): decode
            # would alias distinct encodings onto one entity; add it only
            # with a real-SDK census receipt pinning the encoding.
            case String.trim_trailing(entity, "/") do
              "" -> address
              bare -> bare
            end

          _ ->
            address
        end

      _ ->
        # R129 exploit 1: BARE entity names take the same gate — "q/" is a
        # shadow namespace of "q" and used to slip past both the requiresSession
        # gate and the R96 scheme-form stripping (no "://" -> pass through).
        # Trim trailing slashes so "q/" normalizes to "q"; empty-after-strip
        # ("/") keeps the address unchanged, still failing closed.
        case String.trim_trailing(address, "/") do
          "" -> address
          bare -> bare
        end
    end
  end

  defp bare_entity(other), do: other

  defp unauthorized_error do
    %{condition: "amqp:unauthorized-access", description: "UNAUTHORIZED_ENTITY"}
  end

  defp authorized?(audience) do
    Delivery.ensure_cbs_router()

    cond do
      not Delivery.cbs_running?() or :ets.info(:smalt_sb_tokens) == :undefined ->
        true

      is_binary(audience) ->
        endpoint = Smalt.Amqp.SasVerifier.endpoint()

        # put-token claims are keyed by the full "sb://host:port/entity"
        # audience; the attach address is the bare entity name. pyamqp
        # dialect (S-1, disclosed in s1-amqp-shims receipt): the Python SDK
        # attaches queue links with an `amqps://` scheme while its own CBS
        # token is minted for `sb://` — try the sb-normalized form too
        # instead of refusing the entity on a scheme spelling.
        normalized =
          case String.split(audience, "://", parts: 2) do
            ["amqps", rest] -> "sb://" <> rest
            _ -> audience
          end

        CbsRouter.authorized?(CbsRouter, self(), audience) or
          CbsRouter.authorized?(CbsRouter, self(), endpoint <> "/" <> audience) or
          CbsRouter.authorized?(CbsRouter, self(), normalized)

      true ->
        true
    end
  end

  # ===========================================================================
  # GAP-A2-01/02 (KD-68/KD-69): EH selector filter + epoch exclusivity
  # ===========================================================================

  # decode_source_target normalizes the described selector filter to the
  # literal string key; the rhea map-form path yields the `:selector_filter`
  # atom key.
  # KD-COVERS: KD-68
  defp eh_apply_selector_filter(link, perf, partition) do
    clause =
      case perf.source do
        %{filter: %{@eh_selector_key => {:selector_filter, selector}}} -> selector
        %{filter: %{selector_filter: selector}} -> selector
        _ -> nil
      end

    case eh_parse_event_position(clause, partition) do
      # KD-68: no selector present is fine; a present-but-unparseable
      # selector is a typed-detach error, never silent pass-through.
      nil when is_nil(clause) -> {:ok, link}
      nil -> {:error, clause}
      {:seq, n} -> {:ok, %{link | eh_start: n}}
      {:enqueued, ms} -> {:ok, %{link | eh_min_enqueued: ms}}
    end
  end

  # The SDK eventPosition shapes (partitionReceiver.js:357-360, core-amqp):
  #   fromOffset(o)             -> "amqp.annotation.x-opt-offset > 'o'"
  #   fromSequenceNumber(n)     -> "amqp.annotation.x-opt-sequence-number > 'n'"
  #   fromEnqueuedTime(ms)      -> "amqp.annotation.x-opt-enqueued-time > 'ms'"
  #   latest() / "@latest"      -> "amqp.annotation.x-opt-offset > '@latest'"
  # Those are EXCLUSIVE (strictly greater). The 6.x SDK startingPosition
  # {sequenceNumber: n, isInclusive: true} emits the INCLUSIVE `>=` form
  # (r200c witness: "amqp.annotation.x-opt-sequence-number >= '2'"), which
  # the old exclusive-only regex dropped, so the link delivered from
  # cursor 0 unconditionally. Inclusive positions normalize to the
  # exclusive floor (n-1 / ms-1) so delivery keeps `seq > after_seq`.
  defp eh_parse_event_position(nil, _partition), do: nil
  defp eh_parse_event_position(clause, _partition) when not is_binary(clause), do: nil

  defp eh_parse_event_position(clause, partition) when is_binary(clause) do
    with [_, ann, op, raw] <-
           Regex.run(~r/\Aamqp\.annotation\.(x-opt-[a-z-]+)\s*(>=?)\s*'([^']*)'\z/, clause) do
      floor = if op == ">=", do: 1, else: 0

      case {ann, raw} do
        {"x-opt-offset", "@latest"} when floor == 0 ->
          case EventHubs.last_enqueued(partition) do
            %{"seq" => n} -> {:seq, n}
            _ -> {:seq, 0}
          end

        {"x-opt-offset", v} ->
          eh_pos(eh_int(v), floor, :seq)

        {"x-opt-sequence-number", v} ->
          eh_pos(eh_int(v), floor, :seq)

        {"x-opt-enqueued-time", v} ->
          eh_pos(eh_int(v), floor, :enqueued)

        _ ->
          nil
      end
    end
  end

  defp eh_pos(nil, _floor, _kind), do: nil
  defp eh_pos(n, floor, kind), do: eh_event_position(n - floor, kind)

  defp eh_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp eh_int(_), do: nil

  # nil inputs are filtered by eh_pos/3 above; clauses here receive ints.
  defp eh_event_position(n, :seq), do: {:seq, n}
  defp eh_event_position(ms, :enqueued), do: {:enqueued, ms}

  # --- GAP-A2-02 (KD-69): exclusive receiver (com.microsoft:epoch) -----------

  # Cross-connection epoch registry: {hub, consumer_group, partition} ->
  # {epoch, conn_pid, channel, handle}. A new attach with an equal-or-higher
  # epoch evicts the registered link (typed detach, com.microsoft:epoch-lock-
  # lost); a lower epoch is refused (echo attach + typed detach, EPOCH_REFUSED).
  defp eh_epoch_table do
    case :ets.info(:smalt_eh_epochs) do
      :undefined ->
        try do
          :ets.new(:smalt_eh_epochs, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> :smalt_eh_epochs
        end

      _ ->
        :smalt_eh_epochs
    end
  end

  def eh_address_parts(address) do
    case address |> String.split("/") |> Enum.reject(&(&1 == "")) do
      ["eventhubs", hub, cg, "Partitions", p] -> {hub, cg, p}
      ["eventhubs", hub, "partitions", p] -> {hub, "$Default", p}
      _ -> nil
    end
  end

  # Attach properties decode with raw {:symbol, k} keys on the wire path.
  defp eh_attach_epoch(perf) do
    case perf.properties do
      %{} = props ->
        Enum.find_value(props, fn
          {{:symbol, @eh_epoch_key}, v} when is_integer(v) -> v
          {@eh_epoch_key, v} when is_integer(v) -> v
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  # Admit (or refuse) an EH receiver attach by epoch. `:refused` means the new
  # link must NOT be registered; eviction of the incumbent happens BEFORE the
  # new link is registered, so the detach always precedes the new delivery.
  def eh_epoch_admit(link, _address, state) do
    case {link.eh_epoch, eh_address_parts(link.address)} do
      {nil, _} ->
        {:ok, state}

      {epoch, {hub, cg, p}} ->
        eh_epoch_table()
        key = {hub, cg, p}

        incumbent =
          case :ets.lookup(:smalt_eh_epochs, key) do
            [{^key, old_epoch, old_pid, old_ch, old_handle}] ->
              if is_pid(old_pid) and Process.alive?(old_pid) and old_epoch > epoch,
                do: {:incumbent, old_epoch, old_pid, old_ch, old_handle},
                else: nil

            _ ->
              nil
          end

        case incumbent do
          # GAP-A2-02 refusal: a strictly LOWER epoch never evicts — the
          # incumbent stays registered and the new link is refused.
          {:incumbent, _old_epoch, _old_pid, _old_ch, _old_handle} ->
            {:refused, state}

          nil ->
            # Equal-or-higher epoch (or a dead incumbent's stale entry) evicts
            # any registered link on this {consumer-group, partition} first,
            # THEN registers the new link.
            case :ets.lookup(:smalt_eh_epochs, key) do
              [{^key, old_epoch, old_pid, old_ch, old_handle}] when is_pid(old_pid) ->
                evict_error = eh_epoch_error("EPOCH_EVICTION", old_epoch)

                if old_pid == self() do
                  case link_by_handle(state, old_ch, old_handle) do
                    nil ->
                      :ok

                    _old_link ->
                      Smalt.Amqp.Connection.send_frame(state, old_ch, {
                        :detach,
                        %{handle: old_handle, closed: true, error: evict_error}
                      })
                  end

                  {:ok, %{state | links: Map.delete(state.links, {old_ch, old_handle})}}
                else
                  send(old_pid, {:eh_epoch_evict, old_ch, old_handle, evict_error})
                  {:ok, state}
                end

              _ ->
                {:ok, state}
            end
            |> then(fn
              {:ok, state} ->
                :ets.insert(:smalt_eh_epochs, {key, epoch, self(), link.channel, link.handle})
                {:ok, state}

              other ->
                other
            end)
        end

      _ ->
        {:ok, state}
    end
  end

  # Registry cleanup when an epoch-holding link goes away (client detach,
  # session end, connection close): delete the entry only if it still names
  # THIS link, never a successor's.
  def eh_epoch_release(link) do
    if link.kind == :eventhubs and is_integer(link.eh_epoch) do
      case eh_address_parts(link.address) do
        {hub, cg, p} ->
          key = {hub, cg, p}

          case :ets.lookup(:smalt_eh_epochs, key) do
            [{^key, _ep, pid, ch, handle}]
            when pid == self() and ch == link.channel and handle == link.handle ->
              :ets.delete(:smalt_eh_epochs, key)

            _ ->
              :ok
          end

        _ ->
          :ok
      end
    end
  end

  def eh_epoch_error(desc, epoch) do
    %{
      condition: "com.microsoft:epoch-lock-lost",
      description: "#{desc}: active epoch #{inspect(epoch)}"
    }
  end

  # KD-68: an unsupported selector-filter form detaches typed instead of
  # silently delivering unfiltered (r200c falsifier lesson). rhea maps
  # amqp:not-implemented to a typed SessionError; the description carries
  # the offending clause for the SDK caller.
  defp eh_selector_error(selector) do
    %{
      condition: "amqp:not-implemented",
      description: "SELECTOR_UNSUPPORTED: #{selector}"
    }
  end

  # ===========================================================================
  # EH partition identity (shared with Delivery)
  # ===========================================================================

  # KD-COVERS: KD-68 — partition identity is scoped by the EH entity (hub),
  # not the bare partition label: real Event Hubs sequence spaces are
  # per-hub, and last-segment-only keying routed every hub's events into one
  # shared row (R69: selector-filter exact-sequence courts could not hold).
  def eh_partition(address) when is_binary(address) do
    case String.split(address, "/eventhubs/") do
      [_, rest] -> String.replace_leading(rest, "/", "")
      _ -> address |> String.split("/") |> List.last()
    end
  end

  # r200h (KD-76 repair): structural, case-insensitive partition-tail
  # classifier. Returns {hub, partition} when the address ends in a
  # partitions segment + partition id (any of the wire shapes below);
  # nil means entity-level (hub) address -> aggregate delivery path.
  def eh_partition_scope(address) when is_binary(address) do
    segs = address |> String.split("/") |> Enum.reject(&(&1 == ""))

    case segs do
      # legacy emulator form: /eventhubs/{hub}/partitions/{n}
      ["eventhubs", hub, ptail, p] -> eh_scope(hub, ptail, p)
      # {hub}/Partitions/{n}
      [hub, ptail, p] -> eh_scope(hub, ptail, p)
      # {hub}/ConsumerGroups/{cg}/Partitions/{n} (real @azure/event-hubs SDK form)
      [hub, "ConsumerGroups", _cg, ptail, p] -> eh_scope(hub, ptail, p)
      # /eventhubs/{hub}/ConsumerGroups/{cg}/Partitions/{n}
      ["eventhubs", hub, "ConsumerGroups", _cg, ptail, p] -> eh_scope(hub, ptail, p)
      _ -> nil
    end
  end

  defp eh_scope(hub, ptail, p) do
    # EH fixed-partition pinion: only the pinned partitions ["0","1"] exist.
    # A partition-scoped attach outside the pin is refused — the send side
    # already pins storage to the pair (eh_pk_partition rem 2), so accepting
    # "2" would silently attach a receiver that can never be delivered to.
    # Hub-scoped and non-partition tails stay nil (aggregate path).
    cond do
      String.downcase(ptail) == "partitions" and p != "" and p in ["0", "1"] -> {hub, p}
      String.downcase(ptail) == "partitions" and p != "" -> :refused
      true -> nil
    end
  end

  # KD-COVERS: KD-76 — storage partition for an inbound EH transfer. A
  # pk-stamped event sent on a hub-address (no /partitions) sender link is
  # routed to ONE partition of the pinned set ["0","1"] by a deterministic
  # hash of the key (real service: consistent hashing over the entity's
  # partitions); the x-opt-partition-key annotation still rides the stored
  # event. Partition-scoped or unkeyed sends keep the previous key.
  def eh_storage_partition(partition, pk, address) do
    case eh_partition_scope(address) do
      {hub, p} ->
        # r200h: partition-scoped sender (any casing of the partitions
        # segment) stores under the canonical lowercase key, so a
        # {hub}/Partitions/{n} or .../ConsumerGroups/.../Partitions/{n}
        # sender and receiver meet at the same storage partition.
        "#{hub}/partitions/#{p}"

      nil when pk != nil ->
        # `partition` for a hub address is the bare hub name (eh_partition
        # strips the /eventhubs/ prefix). KD-COVERS: KD-76 — pk routing.
        "#{partition}/partitions/#{eh_pk_partition(pk)}"

      nil ->
        partition
    end
  end

  defp eh_pk_partition(pk) do
    bin = if is_binary(pk), do: pk, else: :erlang.term_to_binary(pk)
    <<first::unsigned-8, _::binary>> = :erlang.md5(bin)
    Integer.to_string(rem(first, 2))
  end

  # ===========================================================================
  # credit bookkeeping (per {channel, handle})
  # ===========================================================================

  # Credit is scoped per {channel, handle}: handle values collide across
  # sessions (every rhea session starts at handle 0), so a handle-only bump
  # granted a NEW session's flow credit to the PREVIOUS session's same-handle
  # link — that link then "stole" the delivery on the next flow (the transfer
  # went to the old, already-drained receiver and the message vanished;
  # census stale-handle probe).
  def add_credit(state, credit, ch) do
    update_links(state, fn
      {c, _h}, link ->
        if (ch == nil or c == ch) and link.kind == :queue and link.role == :sender,
          do: %{link | credit: link.credit + credit},
          else: link
    end)
  end

  def bump_credit(state, ch, handle, delta) do
    state =
      update_links(state, fn
        {c, h}, link when h == handle and (ch == nil or c == ch) ->
          %{link | credit: max(link.credit + delta, 0)}

        _key, link ->
          link
      end)

    # T-12 (a) chaos hook: bump_credit is called ONLY from the three delivery
    # paths (queue claim + both EH paths), so the delivery decrement is the
    # one counting point for every link kind.
    chaos_after_delivery(state, ch, handle, delta)
  end

  # T-12 (a) :sb_chaos_detach_after / :eh_chaos_detach_after — per-link
  # delivery count; on the Nth delivery, requeue the SAME typed detach
  # message the {:eh_epoch_evict, ...} cross-connection eviction handler
  # consumes (retryable amqp:link:detach-forced; the connection stays up so
  # the client relink is clean) and zero the link credit so the same-frame
  # delivery recursion cannot outrun the detach. Flags off = passthrough
  # (no counter writes, no state change).
  defp chaos_after_delivery(state, ch, handle, delta) when delta < 0 do
    case Map.get(state.links, {ch, handle}) do
      %{} = link ->
        ns = if link[:kind] == :eventhubs, do: :eh, else: :sb
        count = Map.get(link, :chaos_deliveries, 0) + 1

        if Smalt.Messaging.Chaos.should_detach?(count, ns) do
          Smalt.Messaging.Chaos.emit(:link_detach, %{deliveries: count}, %{
            namespace: ns,
            channel: ch,
            handle: handle,
            address: link[:address]
          })

          send(self(), {:eh_epoch_evict, ch, handle, Smalt.Messaging.Chaos.detach_error(count)})
          put_link(state, %{link | credit: 0})
        else
          if Smalt.Messaging.Chaos.detach_armed?(ns) do
            put_link(state, Map.put(link, :chaos_deliveries, count))
          else
            state
          end
        end

      _ ->
        state
    end
  end

  defp chaos_after_delivery(state, _ch, _handle, _delta), do: state

  # Absolute credit assignment for inbound :flow on a specific handle
  # (SHIM-COURT flip target: BEFORE = additive bump, AFTER = absolute set).
  def set_credit(state, ch, handle, credit) do
    update_links(state, fn
      {c, h}, link when h == handle and (ch == nil or c == ch) -> %{link | credit: credit}
      _key, link -> link
    end)
  end

  def update_links(state, fun) do
    %{state | links: Map.new(state.links, fn {key, l} -> {key, fun.(key, l)} end)}
  end

  def put_link(state, link),
    do: %{state | links: Map.put(state.links, {link.channel, link.handle}, link)}

  # Links are keyed {channel, handle}: handle values collide across sessions
  # (the SDK's $cbs sender and a queue sender on another session both use
  # handle 0), and per-handle keys made one link overwrite the other.
  def link_by_handle(state, channel, handle) do
    state.links[{channel, handle}] || state.links[{state.session[:channel] || channel, handle}]
  end
end
