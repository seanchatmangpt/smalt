defmodule Smalt.Amqp.ManagementRpc.LockRenew do
  @moduledoc """
  `com.microsoft:renew-lock` — extracted verbatim from the pre-split
  `Smalt.Amqp.ManagementRpc` monolith (tail-splits ticket T10); bodies
  byte-identical, `defp` promoted to `def` on the handler entry only.
  """

  alias Smalt.Amqp.ManagementRpc.Shared

  def handle(body, correlation_id, context, now) do
    lock_tokens =
      body
      |> Shared.body_field("lock-tokens")
      |> case do
        # AMQP array-of-uuid (rhea wrap_array) decodes to {:array, elements};
        # a bare list is the internal test form. Same unwrap as
        # update_disposition — List.wrap alone wraps the whole tuple as one
        # bogus token -> normalize_token/1 nil -> LockManager.renew/3
        # FunctionClauseError (uncaught wire crash).
        {:array, toks} when is_list(toks) -> toks
        other -> List.wrap(other)
      end

    cond do
      lock_tokens == [] or lock_tokens == [nil] ->
        Shared.respond(400, "LOCK_TOKEN_REQUIRED", nil, correlation_id)

      true ->
        case renew_each(lock_tokens, context, now) do
          {:ok, expirations} ->
            Shared.respond(
              200,
              "OK",
              %{"expirations" => Enum.map(expirations, &{:timestamp, &1})},
              correlation_id
            )

          {:error, :lock_lost} ->
            Shared.respond(410, "MESSAGE_LOCK_LOST", nil, correlation_id)
        end
    end
  end

  def renew_each(lock_tokens, context, now, acc \\ [])

  def renew_each([], _context, _now, acc), do: {:ok, Enum.reverse(acc)}

  def renew_each([token | rest], context, now, acc) do
    case Shared.invoke(context, :lock_manager, Smalt.Amqp.LockManager, :renew_lock, [
           Shared.resolve_token(token, context),
           now
         ]) do
      {:ok, expiry_ms} -> renew_each(rest, context, now, [expiry_ms | acc])
      {:error, _reason} -> {:error, :lock_lost}
    end
  end
end
