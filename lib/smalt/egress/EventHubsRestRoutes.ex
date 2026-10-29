defmodule Smalt.Egress.EventHubsRestRoutes do
  @moduledoc """
  EH-REST lane: Microsoft-documented Event Hubs REST producer face.

  Wire shape (learn.microsoft.com "Event Hubs REST — Publish Events", the
  legacy producer endpoint):

      POST https://{ns}.eventhubs.azure.net/{hub}/messages?api-version=2014-01
      Authorization: SharedAccessSignature sr=..&sig=..&se=..&skn=..
      x-ms-partition-key: <key>
      <body up to 1 MB>

  Contract:

    * SAS verification reuses the normalized verifier law
      (`Smalt.Amqp.SasVerifier`, KD-S5) — bad/missing token is a typed 401
      (`Unauthorized`).
    * `x-ms-partition-key` routes into the SAME partition store the AMQP lane
      uses, under the same pk-partition law as
      `Smalt.Amqp.Connection.eh_pk_partition/1` (KD-76: md5(pk) first byte
      rem 2 over the pinned partition set ["0", "1"]) — so an event published
      REST and its AMQP-published twin for the same key meet in one partition.
    * Body over 1 MiB is a typed 413 (`RequestEntityTooLarge`); exactly-1 MiB
      is admitted.
    * 201 with an EMPTY body on success (real Azure returns 201 empty).
    * Unknown hub is a typed 404 (`HubNotFound`) when the namespace is pinned
      with `config :smalt, :eh_hubs`.
  """
  use Plug.Router
  import Smalt.EgressRouter, except: [match: 2, match: 3, dispatch: 2]
  plug :match
  plug :dispatch

  alias Smalt.Amqp.SasVerifier
  alias Smalt.Messaging.EventHubs

  @max_body_bytes 1_048_576
  @pinned_partitions 2

  post "/:hub/messages" do
    conn
    |> eh_messages_arm(hub)
    |> halt_if_sent()
  end

  # The POST /{hub}/messages wire arm, factored out so the route body can
  # pass through the same sent-response guard the other delegators run
  # (kd07 class: a sent response that returns un-halted falls through to the
  # main router's blob splat and AlreadySentErrors there — witnessed).
  defp eh_messages_arm(conn, hub) do
    if :ets.info(:smalt_eh_partitions) == :undefined do
      route_not_ready(conn)
    else
      with :ok <- verify_sas(conn),
           :ok <- hub_known?(hub),
           {:ok, body} <- read_capped_body(conn),
           {:ok, pk} <- partition_key(conn) do
        publish(conn, hub, body, pk)
      else
        {:resp, status, code, message} -> send_error(conn, status, code, message)
      end
    end
  end

  # Same guard as Smalt.Egress.SqlIngestRoutes.halt_if_sent/1: the moment a
  # response is on the wire, halt — a mounted fallthrough chain must never
  # hand a sent conn to the next router.
  defp halt_if_sent(conn) do
    if conn.state in [:sent, :chunked] or conn.halted do
      Plug.Conn.halt(conn)
    else
      conn
    end
  end

  match _ do
    conn
  end

  # -- SAS verification (KD-S5 law reuse) ------------------------------------

  # The token's `sr` audience is checked against THIS request's authority
  # (both the sb:// and https:// resource forms real SDKs mint), so a token
  # signed for another namespace host is a typed 401.
  defp verify_sas(conn) do
    # W-close (divergence-elimination): real EH REST clients carry the SAS in
    # `Authorization`, but the athena differential runner must dual-face it on
    # `ServiceBusAuthorization` exactly like the SB REST lane — the egress
    # bearer plug owns `authorization` (enforce mode). Same token, same
    # verifier; only the header face widens.
    sas_header =
      case get_req_header(conn, "servicebusauthorization") do
        [token] -> [token]
        [] -> get_req_header(conn, "authorization")
      end

    case sas_header do
      [token] ->
        do_verify_sas(String.trim(token), conn)

      _ ->
        {:resp, 401, "Unauthorized", "missing SharedAccessSignature authorization"}
    end
  end

  defp do_verify_sas("SharedAccessSignature " <> _rest = token, conn) do
    host = conn.host
    port = conn.port || URI.default_port(to_string(conn.scheme || :http))
    now = System.system_time(:second)

    # sb:// form: SasVerifier's sb audience clause is host-scoped (a loopback
    # configured host admits any loopback sr host). https:// form is
    # host+port exact. Either admission proves the token was signed with the
    # shared key this namespace verifies with.
    configs = ["sb://#{host}:#{port}", "https://#{host}:#{port}"]

    result =
      Enum.reduce_while(configs, :no_admit, fn cfg, acc ->
        case SasVerifier.verify(token, cfg, now) do
          {:ok, _claims} ->
            {:halt, :ok}

          {:error, {400, msg}} ->
            {:halt, {:resp, 400, "InvalidAuthorization", msg}}

          {:error, {401, _}} ->
            {:cont, acc}
        end
      end)

    case result do
      :ok ->
        :ok

      {:resp, _, _, _} = resp ->
        resp

      _no_admit ->
        {:resp, 401, "Unauthorized", "INVALID_LOCAL_SAS"}
    end
  end

  defp do_verify_sas(_other, _conn) do
    {:resp, 401, "Unauthorized", "authorization must be a SharedAccessSignature token"}
  end

  # -- hub admission -----------------------------------------------------------

  # Hubs are lazily provisioned (matching the AMQP lane, which auto-provisions
  # on first send). An operator may pin the namespace with
  # `config :smalt, :eh_hubs, [...]`; when the pin is set, a hub outside it is
  # a typed 404 HubNotFound (real Azure semantics for a missing entity).
  defp hub_known?(hub) do
    case Application.get_env(:smalt, :eh_hubs) do
      hubs when is_list(hubs) ->
        if hub in hubs do
          :ok
        else
          {:resp, 404, "HubNotFound", "event hub '#{hub}' does not exist"}
        end

      _ ->
        :ok
    end
  end

  # -- body + partition key ----------------------------------------------------

  # 1 MiB cap: read_body with the exact max admits exactly-1MiB bodies;
  # {:more, _, _} (or :error) is over-cap -> typed 413.
  defp read_capped_body(conn) do
    case read_body(conn, length: @max_body_bytes) do
      {:ok, body, _conn} ->
        if body == "" do
          {:resp, 400, "InvalidBody", "empty request body"}
        else
          {:ok, body}
        end

      {:more, _, _} ->
        {:resp, 413, "RequestEntityTooLarge", "message body exceeds the 1 MB producer limit"}

      {:error, _} ->
        {:resp, 400, "InvalidBody", "request body could not be read"}
    end
  end

  defp partition_key(conn) do
    case get_req_header(conn, "x-ms-partition-key") do
      [pk] ->
        {:ok, pk}

      [] ->
        {:ok, nil}

      _multi ->
        {:resp, 400, "InvalidPartitionKey", "multiple x-ms-partition-key headers"}
    end
  end

  # -- publish -----------------------------------------------------------------

  defp publish(conn, hub, body, pk) do
    partition = storage_partition(hub, pk)

    case EventHubs.send_event(partition, body, partition_key: pk) do
      {:ok, _seq, _event} ->
        conn
        |> put_resp_header("x-ms-request-id", generate_request_id())
        |> send_resp(201, "")

      {:error, {:throttled, face}} ->
        conn
        |> put_resp_header("retry-after", "1")
        |> send_error(429, "ServerBusy", "publish throttled: #{inspect(face)}")
    end
  end

  # KD-76 (reuse, never re-derive): the pk-partition rule is the SAME law the
  # AMQP lane runs (`Smalt.Amqp.Connection.eh_pk_partition/1`): first byte of
  # md5(pk), integer remainder over the pinned partition set ["0", "1"].
  # Non-binary keys hash their term encoding.
  defp storage_partition(hub, pk) when pk != nil do
    "#{hub}/partitions/#{pk_partition(pk)}"
  end

  defp storage_partition(hub, _pk), do: hub

  defp pk_partition(pk) do
    bin = if is_binary(pk), do: pk, else: :erlang.term_to_binary(pk)
    <<first::unsigned-8, _::binary>> = :erlang.md5(bin)
    Integer.to_string(rem(first, @pinned_partitions))
  end

  # -- error rendering ---------------------------------------------------------

  defp send_error(conn, status, code, message) do
    send_json(conn, status, %{"error" => %{"code" => code, "message" => message}})
  end
end
