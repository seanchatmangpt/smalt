defmodule Smalt.PubSubGrpc.Plug do
  @moduledoc """
  gRPC face for the Pub/Sub subset over Bandit (lane K-GC, v26.11.6).

  Routes (real pubsub.proto method paths): Publisher/{Publish,GetTopic,
  CreateTopic}, Subscriber/{Pull,Acknowledge,ModifyAckDeadline,
  GetSubscription}, StreamingPull is UNIMPLEMENTED(12) (F-P5, graded
  deferral).

  gRPC framing: 1-byte compressed flag (must be 0, else 13 INTERNAL) +
  4-byte BE length, bounded ceiling. Errors are Trailers-Only: HTTP 200,
  content-type application/grpc, grpc-status + grpc-message in the
  response HEADERS, no body (the F-P2-gated shape). Success: HEADERS with
  grpc-status: 0 + DATA.
  """

  use Plug.Router

  alias Smalt.PubSubGrpc.Engine
  alias Smalt.PubSubGrpc.Wire

  plug :match
  plug :dispatch

  @grpc_invalid_argument 3
  @grpc_not_found 5
  @grpc_unimplemented 12
  @grpc_internal 13
  @grpc_unauthenticated 16

  defp max_message_bytes, do: 4 * 1024 * 1024

  # Success shape: HEADERS carrying grpc-status: 0 + DATA (5-byte gRPC
  # prefix + protobuf payload). The F-P2 gate decides whether grpcio
  # accepts grpc-status in the initial HEADERS before DATA.
  defp ok_response(conn, payload) do
    body = <<0::size(8), byte_size(payload)::size(32)>> <> payload

    conn
    |> Plug.Conn.put_resp_content_type("application/grpc")
    |> Plug.Conn.send_resp(200, body)
  end

  # Trailers-Only error shape.
  defp trailers_only(conn, status, message) do
    conn
    |> Plug.Conn.put_resp_content_type("application/grpc")
    |> Plug.Conn.put_resp_header("grpc-status", Integer.to_string(status))
    |> Plug.Conn.put_resp_header("grpc-message", URI.encode_www_form(message))
    |> Plug.Conn.send_resp(200, <<>>)
  end

  # ── request reading ────────────────────────────────────────────────

  defp read_message(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    case body do
      <<0::size(8), len::size(32), payload::binary-size(len)>> ->
        if byte_size(payload) > max_message_bytes() do
          {:error, @grpc_internal, "message exceeds ceiling"}
        else
          {:ok, payload, conn}
        end

      <<flag::size(8), _len::size(32), _rest::binary>> when flag != 0 ->
        {:error, @grpc_internal, "compressed-flag must be 0"}

      _ ->
        {:error, @grpc_internal, "truncated gRPC frame"}
    end
  end

  # ── auth ───────────────────────────────────────────────────────────

  # Config :smalt, :pubsub_api_key unset → anonymous; set + missing/wrong
  # credential → UNAUTHENTICATED(16) Trailers-Only (F-P6 auth law).
  defp authorize(conn) do
    case Application.get_env(:smalt, :pubsub_api_key) do
      nil ->
        :ok

      expected ->
        got =
          Enum.find_value(conn.req_headers, fn {k, v} ->
            if k in ["x-api-key", "authorization"], do: v
          end)

        bearer =
          case got do
            <<"Bearer ", rest::binary>> -> String.trim(rest)
            other -> other
          end

        if is_binary(bearer) and Plug.Crypto.secure_compare(bearer, expected) do
          :ok
        else
          {:error, @grpc_unauthenticated, "missing or invalid API key"}
        end
    end
  end

  # ── dispatch wrapper ───────────────────────────────────────────────

  defp grpc(conn, handler) do
    with :ok <- authorize(conn),
         {:ok, payload, _conn} <- read_message(conn) do
      case handler.(payload) do
        {:ok, resp_payload} -> ok_response(conn, resp_payload)
        {:error, code, msg} -> trailers_only(conn, code, msg)
      end
    else
      {:error, code, msg} -> trailers_only(conn, code, msg)
    end
  end

  # ── routes ─────────────────────────────────────────────────────────

  post "/google.pubsub.v1.Publisher/Publish" do
    grpc(conn, fn payload ->
      case Wire.decode_publish_request(payload) do
        {:ok, req, _} ->
          case Engine.publish(req.topic, req.messages) do
            {:ok, ids} -> {:ok, Wire.encode_publish_response(ids)}
            {:grpc_error, code, msg} -> {:error, code, msg}
          end

        {:error, :bad_varint} ->
          {:error, @grpc_internal, "malformed PublishRequest (bad varint)"}
      end
    end)
  end

  post "/google.pubsub.v1.Subscriber/Pull" do
    grpc(conn, fn payload ->
      case Wire.decode_pull_request(payload) do
        {:ok, req} ->
          args = [req.subscription, req.max_messages, req.return_immediately]
          apply(Engine, :pull, args) |> handle_engine()

        {:error, :bad_varint} ->
          {:error, @grpc_internal, "malformed PullRequest (bad varint)"}
      end
    end)
  end

  post "/google.pubsub.v1.Subscriber/Acknowledge" do
    grpc(conn, fn payload ->
      case Wire.decode_acknowledge_request(payload) do
        {:ok, req} ->
          case Engine.acknowledge(req.subscription, req.ack_ids) do
            :ok -> {:ok, <<>>}
            {:grpc_error, code, msg} -> {:error, code, msg}
          end

        {:error, :bad_varint} ->
          {:error, @grpc_internal, "malformed AcknowledgeRequest (bad varint)"}
      end
    end)
  end

  post "/google.pubsub.v1.Subscriber/ModifyAckDeadline" do
    grpc(conn, fn payload ->
      case Wire.decode_modify_ack_deadline_request(payload) do
        {:ok, req} ->
          args = [req.subscription, req.ack_ids, req.ack_deadline_seconds]
          apply(Engine, :modify_ack_deadline, args) |> handle_engine_empty()

        {:error, :bad_varint} ->
          {:error, @grpc_internal, "malformed ModifyAckDeadlineRequest (bad varint)"}
      end
    end)
  end

  post "/google.pubsub.v1.Publisher/CreateTopic" do
    grpc(conn, fn payload ->
      case Wire.decode_topic_request(payload) do
        {:ok, req} ->
          case Engine.create_topic(req.topic) do
            {:ok, topic} -> {:ok, Wire.encode_topic(topic)}
            {:grpc_error, code, msg} -> {:error, code, msg}
          end

        {:error, :bad_varint} ->
          {:error, @grpc_internal, "malformed TopicRequest (bad varint)"}
      end
    end)
  end

  post "/google.pubsub.v1.Publisher/GetTopic" do
    grpc(conn, fn payload ->
      case Wire.decode_topic_request(payload) do
        {:ok, req} ->
          case Engine.get_topic(req.topic) do
            {:ok, topic} -> {:ok, Wire.encode_topic(topic)}
            {:grpc_error, code, msg} -> {:error, code, msg}
          end

        {:error, :bad_varint} ->
          {:error, @grpc_internal, "malformed TopicRequest (bad varint)"}
      end
    end)
  end

  post "/google.pubsub.v1.Subscriber/GetSubscription" do
    grpc(conn, fn payload ->
      case Wire.decode_topic_request(payload) do
        {:ok, req} ->
          case Engine.get_subscription(req.topic) do
            {:ok, sub} -> {:ok, Wire.encode_subscription(sub)}
            {:grpc_error, code, msg} -> {:error, code, msg}
          end

        {:error, :bad_varint} ->
          {:error, @grpc_internal, "malformed GetSubscriptionRequest (bad varint)"}
      end
    end)
  end

  post "/google.pubsub.v1.Publisher/StreamingPull" do
    trailers_only(conn, @grpc_unimplemented, "StreamingPull is not implemented")
  end

  post "/google.pubsub.v1.Subscriber/StreamingPull" do
    trailers_only(conn, @grpc_unimplemented, "StreamingPull is not implemented")
  end

  # Empty-response engine handlers.
  defp handle_engine_empty(result) do
    case result do
      :ok -> {:ok, <<>>}
      {:grpc_error, code, msg} -> {:error, code, msg}
    end
  end

  defp handle_engine(result) do
    case result do
      {:ok, received} -> {:ok, Wire.encode_pull_response(received)}
      {:grpc_error, code, msg} -> {:error, code, msg}
    end
  end

  match _ do
    trailers_only(var!(conn), @grpc_unimplemented, "unknown or streaming method")
  end
end
