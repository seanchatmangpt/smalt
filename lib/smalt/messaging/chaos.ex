defmodule Smalt.Messaging.Chaos do
  @moduledoc """
  T-12 — broker-internal, deterministic, bounded AMQP chaos injectors
  (Topaz v1.13 parity: link detach injection, credit starvation, session
  timeout injection).

  Three typed flags behind `:smalt` application-env keys, set via the
  boot-eval `Application.put_env` discipline (read with
  `Application.get_env/2` at the connection hook sites — never runtime
  module patching). Each flag defaults to off and fails closed on any
  value that is not a typed arm:

  | flag (`:sb_*` / `:eh_*` twin)                    | armed value    | effect |
  |--------------------------------------------------|----------------|--------|
  | `:sb_chaos_detach_after` / `:eh_chaos_detach_after`     | positive integer N | the link force-detaches after the Nth delivery with the retryable `amqp:link:detach-forced` error shape (the same face clients see during Azure maintenance events) |
  | `:sb_chaos_starve_credits` / `:eh_chaos_starve_credits` | `true` or `"on"`   | inbound flow credit grants are withheld; deliveries stall while armed and resume when the flag is off |
  | `:sb_chaos_session_timeout_ms` / `:eh_chaos_session_timeout_ms` | positive integer ms | sessions close at the injected timeout, exercising the client's session/connection recreation path |

  The `:eh_*` trio namespaces the same shared machinery for Event Hubs
  links (the namespace is resolved from the link kind at the hook site);
  the session layer is common to both namespaces, so `session_timeout/0`
  honors whichever namespace is armed (the shortest bound wins).

  Deterministic and bounded: no randomness, no probabilistic modes, and
  **zero `Process.sleep` anywhere** (NO_SLEEP_DOCTRINE — the one timer in
  this feature is a `Process.send_after` SCHEDULING timer inside the
  connection, the doctrine's lawful lib form). Every fired injection
  emits typed telemetry under `[:smalt, :chaos, ...]`:

    - `[:smalt, :chaos, :link_detach]`       — measurements `%{deliveries: n}`
    - `[:smalt, :chaos, :credit_starved]`    — measurements `%{withheld_credit: c}`
    - `[:smalt, :chaos, :session_timeout]`   — measurements `%{timeout_ms: ms}`

  with metadata carrying the namespace, channel, handle and address.
  """

  @typedoc "Resolved injector bound: off, or armed with a positive bound."
  @type bound :: :infinity | pos_integer()
  @typedoc "Injector namespace: `:sb` (Service Bus queue links) or `:eh` (Event Hubs links)."
  @type namespace :: :sb | :eh

  @namespaces [:sb, :eh]

  @detach_key %{sb: :sb_chaos_detach_after, eh: :eh_chaos_detach_after}
  @starve_key %{sb: :sb_chaos_starve_credits, eh: :eh_chaos_starve_credits}

  @session_timeout_key %{sb: :sb_chaos_session_timeout_ms, eh: :eh_chaos_session_timeout_ms}

  @doc """
  Full resolved chaos config — the court/receipt view of the flags
  (defaults: `:infinity` / `"off"` / `:infinity`).
  """
  @spec config :: %{namespace() => %{detach_after: bound(), starve_credits: boolean(), session_timeout_ms: bound()}}
  def config do
    Map.new(@namespaces, fn ns ->
      {ns,
       %{
         detach_after: detach_after(ns),
         starve_credits: starve?(ns),
         session_timeout_ms: session_timeout(ns)
       }}
    end)
  end

  @doc "`:sb_chaos_detach_after` / `:eh_chaos_detach_after` — N, or `:infinity` (off)."
  @spec detach_after(namespace) :: bound()
  def detach_after(ns \\ :sb)
  def detach_after(ns) when ns in @namespaces, do: read_bound(@detach_key[ns])
  def detach_after(_), do: :infinity

  @doc """
  Pure detach predicate the broker calls on every delivery: true iff the
  injector is armed with N and `delivery_count` has REACHED the Nth
  delivery (1-based, counting the delivery being decided). Never fires
  before N — the court pins `false` for every count below N and `true`
  exactly from N on.
  """
  @spec should_detach?(pos_integer(), namespace) :: boolean()
  def should_detach?(delivery_count, ns \\ :sb)

  def should_detach?(delivery_count, ns)
      when is_integer(delivery_count) and delivery_count >= 1 and ns in @namespaces do
    case detach_after(ns) do
      n when is_integer(n) -> delivery_count >= n
      _ -> false
    end
  end

  def should_detach?(_, _), do: false

  @doc """
  True iff the detach injector is armed at all for `ns`. The connection
  uses this to skip its per-link chaos counter entirely when the flags
  are off (the anti-vacuity witness: flags off = zero interference with
  the link state).
  """
  @spec detach_armed?(namespace) :: boolean()
  def detach_armed?(ns \\ :sb)

  def detach_armed?(ns) when ns in @namespaces do
    case detach_after(ns) do
      n when is_integer(n) -> true
      _ -> false
    end
  end

  def detach_armed?(_), do: false

  @doc "`:sb_chaos_starve_credits` / `:eh_chaos_starve_credits` — true while flow credit grants are withheld."
  @spec starve?(namespace) :: boolean()
  def starve?(ns \\ :sb)

  def starve?(ns) when ns in @namespaces do
    case Application.get_env(:smalt, @starve_key[ns]) do
      flag when flag in [true, "on", :on] -> true
      _ -> false
    end
  end

  def starve?(_), do: false

  @doc "`:sb_chaos_session_timeout_ms` / `:eh_chaos_session_timeout_ms` — injected session close timeout in ms, or `:infinity` (off)."
  @spec session_timeout(namespace) :: bound()
  def session_timeout(ns \\ :sb)
  def session_timeout(ns) when ns in @namespaces, do: read_bound(@session_timeout_key[ns])
  def session_timeout(_), do: :infinity

  @doc """
  Shared session-layer close bound: the session machinery is common to
  both namespaces, so the SHORTEST armed timeout governs (`:infinity`
  when neither namespace arms a session timeout).
  """
  @spec session_timeout :: bound()
  def session_timeout do
    @namespaces
    |> Enum.map(&session_timeout/1)
    |> Enum.reject(&(&1 == :infinity))
    |> case do
      [] -> :infinity
      bounds -> Enum.min(bounds)
    end
  end

  @doc """
  The typed, retryable detach error emitted on a chaos detach — the same
  wire shape the broker uses for service-forced detaches
  (`amqp:link:detach-forced` is the condition @azure/service-bus maps to
  a retryable error during Azure maintenance events).
  """
  @spec detach_error(pos_integer()) :: %{condition: String.t(), description: String.t()}
  def detach_error(n) when is_integer(n) do
    %{
      condition: "amqp:link:detach-forced",
      description: "SMALT_CHAOS_DETACH_FORCED (chaos_detach_after=#{n})"
    }
  end

  @doc "Typed telemetry for every fired injection: `[:smalt, :chaos, event]`."
  @spec emit(atom, map, map) :: :ok
  def emit(event, measurements, metadata) when is_atom(event) do
    :telemetry.execute([:smalt, :chaos, event], measurements, metadata)
  end

  # Fail-closed typed resolution: a positive integer arms the injector;
  # unset, :infinity, 0, negatives and any other value read as OFF.
  defp read_bound(key) do
    case Application.get_env(:smalt, key) do
      n when is_integer(n) and n > 0 -> n
      _ -> :infinity
    end
  end
end
