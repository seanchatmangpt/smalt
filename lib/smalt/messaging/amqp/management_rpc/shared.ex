defmodule Smalt.Amqp.ManagementRpc.Shared do
  @moduledoc """
  Internals shared by the `$management` operation family modules (the
  `Smalt.Amqp.ManagementRpc` split, tail-splits ticket T10). Extracted
  verbatim from the pre-split monolith's `Internals` fence; bodies are
  byte-identical with `defp` promoted to `def` (sibling call surface only —
  the wire-visible API remains `Smalt.Amqp.ManagementRpc.handle/2`).
  """

  @default_lock_manager Smalt.Amqp.LockManager
  @default_queue_store Smalt.Amqp.QueueStore

  # Fail-closed store gate for the session/batch ops: when the Store tables are
  # not materialized, refuse typed (404 NOT_FOUND at the call sites) instead of
  # letting a badarg escape the management dispatch. The gate consults the
  # effective queue_store collaborator's tables_ready?/0 (real store in prod,
  # injectable double in unit tests). Normalizes the store's :error (absent
  # key) into {:error, :not_found}.
  def store_call(context, name, args) do
    target = Map.get(context, :queue_store, @default_queue_store)

    ready =
      cond do
        is_atom(target) and function_exported?(target, :tables_ready?, 0) ->
          target.tables_ready?()

        is_atom(target) ->
          @default_queue_store.tables_ready?()

        # anonymous-fun collaborators (unit-test form): gate not observable.
        true ->
          true
      end

    if ready do
      case invoke(context, :queue_store, @default_queue_store, name, args) do
        :ok -> :ok
        {:ok, _} = ok -> ok
        :error -> {:error, :not_found}
        {:error, _} = err -> err
        other -> {:error, other}
      end
    else
      {:error, :no_table}
    end
  end

  # Context fields may be modules (apply/3) or plain functions.
  def invoke(context, key, default, name, args) do
    target = Map.get(context, key, default)

    case target do
      fun when is_function(fun, length(args)) -> apply(fun, args)
      fun when is_function(fun) -> raise ArgumentError, "bad arity for #{key}: #{inspect(fun)}"
      mod when is_atom(mod) -> apply(mod, name, args)
    end
  end

  def respond(status_code, status_description, body, correlation_id) do
    %{
      status_code: status_code,
      status_description: status_description,
      body: body,
      correlation_id: correlation_id
    }
  end

  def body_field(body, key) when is_map(body), do: Map.get(body, key)

  def body_field(_body, _key), do: nil

  # Present-but-nil is invalid (400); absent falls back to the default.
  def fetch_or(body, key, default) when is_map(body) do
    if Map.has_key?(body, key), do: Map.get(body, key), else: default
  end

  def fetch_or(_body, _key, default), do: default

  # Wire tokens are raw 16-byte AMQP uuid values; the lock store keys them as
  # dashed lowercase strings (LockManager.new_token/0). rhea string_to_uuid
  # round-trips the delivered token, so normalize before lookup.
  # Wire lock tokens arrive as raw uuid values the SDK already reordered
  # .NET-GUID style (LockManager.token_to_wire/1, shouldReorderLockToken: true).
  # The reorder is an involution, so applying it once more restores the raw
  # layout before format_uuid; straight-formatting the delivered bytes minted
  # a permuted store key and 410s on every live-lock settle/renew.
  def normalize_token({:uuid, <<b0, b1, b2, b3, b4, b5, b6, b7, rest::binary-size(8)>>}) do
    Smalt.Amqp.LockManager.format_uuid(<<b3, b2, b1, b0, b5, b4, b7, b6, rest::binary>>)
  end

  def normalize_token(token) when is_binary(token), do: token
  def normalize_token(token) when is_integer(token), do: token
  def normalize_token(_other), do: nil

  # R178e (census replay witness, @azure/service-bus 7.10.0): the SDK echoes
  # lock tokens in TWO wire dialects. Non-session receivers format the
  # delivered tag straight (rhea uuid_to_string) and echo the .NET-GUID
  # permuted bytes; session-dialect receivers run the tag through
  # reorderLockToken first (serviceBusMessage.js shouldReorderLockToken), so
  # their management echo carries the STRAIGHT bytes of the store key.
  # Unconditional unpermutation (normalize_token) made exactly one family
  # miss the lock store on every settle/renew -> 410 MESSAGE_LOCK_LOST
  # cascades. Resolution is disjunctive and store-adjudicated: try the
  # unpermuted key first (legacy contract + unit-test dialect), fall back to
  # the straight-formatted bytes; only a key actually present in the lock
  # store wins.
  def resolve_token(token, context) do
    primary = normalize_token(token)
    alt = straight_token(token)

    cond do
      is_nil(alt) -> primary
      lock_row_exists?(primary, context) -> primary
      true -> alt
    end
  end

  def straight_token({:uuid, <<_::binary-size(16)>> = uuid}) do
    Smalt.Amqp.LockManager.format_uuid(uuid)
  end

  def straight_token(_other), do: nil

  # Store-backed existence probe through the same seam the settle path uses,
  # so context-injected test stubs keep adjudicating.
  def lock_row_exists?(raw, context) do
    match?({:ok, _}, invoke(context, :lock_manager, @default_lock_manager, :get, [raw]))
  end

  def coerce_long(n) when is_integer(n), do: n
  def coerce_long(n) when is_float(n), do: trunc(n)

  def coerce_long(binary) when is_binary(binary) do
    case Integer.parse(binary) do
      {n, ""} -> n
      _ -> :error
    end
  end

  def coerce_long(_), do: :error

  # since-updated-time: AMQP timestamp section ({:timestamp, ms}) or raw
  # integer ms; absent/nil -> nil (no filter). Anything else is :error (400).
  def coerce_since(nil), do: nil
  def coerce_since({:timestamp, ms}) when is_integer(ms), do: ms
  def coerce_since(ms) when is_integer(ms), do: ms
  def coerce_since(_), do: :error

  # R135 (W5-17): management ops that resolve an entity by name must accept
  # URI-form queue fields ("amqps://host:5671/q") the same way link attach
  # addresses already normalize via Connection.bare_entity/1 (R96/R129).
  # Local copy because that function is private to connection.ex; keep the
  # two in sync. Deliberately not applied to $management request dispatch
  # itself — only to entity resolution inside individual op handlers.
  def bare_entity(address) when is_binary(address) do
    case String.split(address, "://", parts: 2) do
      [scheme, rest] when scheme in ["amqp", "amqps", "sb"] ->
        case String.split(rest, "/", parts: 2) do
          [_host, entity] when is_binary(entity) and entity != "" ->
            case String.trim_trailing(entity, "/") do
              "" -> address
              bare -> bare
            end

          _ ->
            address
        end

      _ ->
        # R178c (R129 sync): BARE entity names take the same gate — "q/" is a
        # shadow namespace of "q" and used to slip past the scheme-form
        # stripping (no "://" -> pass through). Trim trailing slashes so
        # "q/" normalizes to "q"; empty-after-strip ("/") keeps the address
        # unchanged, still failing closed.
        case String.trim_trailing(address, "/") do
          "" -> address
          bare -> bare
        end
    end
  end

  def bare_entity(other), do: other

  def blank?(nil), do: true
  def blank?(""), do: true
  def blank?(_), do: false

  # Peeked messages carry their per-queue sequence number; the SDK's
  # ManagementClient tracks _lastPeekedSequenceNumber from the embedded raw
  # message's x-opt-sequence-number annotation.
  def maybe_put_seq(map, %{seq: seq}) when is_integer(seq),
    do: Map.put(map, "sequence-number", seq)

  def maybe_put_seq(map, _), do: map

  # Peek envelope surfaces the row's settlement state for non-live rows
  # (still-deferred rows read `delivery-state: deferred`); live rows are
  # stateless from the SDK's perspective and stay unlabeled.
  def maybe_put_delivery_state(map, %{state: :deferred}),
    do: Map.put(map, "delivery-state", "deferred")

  def maybe_put_delivery_state(map, %{state: :dead}),
    do: Map.put(map, "delivery-state", "suspended")

  def maybe_put_delivery_state(map, _), do: map

  # R178e: the receive-by-sequence reply must carry the message HEADER
  # delivery-count (the SDK reads deliveryCount from the decoded header, not
  # from the envelope) and the lock-token uuid (the SDK uses it as the
  # delivery tag for later settle). Normalized into wire sections by
  # Connection.normalize_mgmt_message/1. (Merged duplicate clause blocks,
  # lane 243: wire form kept — {:uuid, LockManager.token_to_wire/1} — string
  # raw-token form removed as unreachable.)
  def maybe_put_delivery_count(map, %{delivery_count: dc}) when is_integer(dc),
    do: Map.put(map, "delivery-count", dc)

  def maybe_put_delivery_count(map, _), do: map

  def maybe_put_lock_token(map, %{lock_token: t}) when is_binary(t),
    do: Map.put(map, "lock-token", {:uuid, Smalt.Amqp.LockManager.token_to_wire(t)})

  def maybe_put_lock_token(map, _), do: map

  def message_body(%{body: body}), do: body
  def message_body(%{"body" => body}), do: body
  def message_body(binary) when is_binary(binary), do: binary
  def message_body(other), do: other
end
