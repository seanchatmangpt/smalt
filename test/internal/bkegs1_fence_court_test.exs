defmodule Smalt.BKEGS1.FenceCourtTest do
  # BK-EGS1 (F-EGS1 repair, EXPL9-R2) — crash-fence fault-guard court.
  #
  # Witnesses, over REAL Bandit HTTP (template rigs whose handle_errors/2 is
  # copied VERBATIM from the subject routers, per the BK-EGSKEP audit method):
  #
  #   LEG 1  egress guarded handler, healthy error_xml  -> 500 Storage XML
  #          envelope + fresh x-ms-request-id (fence works normally)
  #   LEG 2  OLD unguarded handler + faulting error_xml (SHIM-COURT mutation
  #          inside the rig) -> NAKED 500 (empty body, no x-ms-request-id) —
  #          the F-EGS1 defect class, witnessed live
  #   LEG 3  NEW guarded handler + the SAME faulting error_xml -> well-formed
  #          constant fallback envelope + static request id (the flip; a court
  #          that cannot flip is FAIL)
  #   LEG 4  ARM guarded handler, healthy helpers -> 500 ARM envelope + rid
  #   LEG 5  ARM guarded handler + faulting rid generator -> fallback ARM JSON
  #          envelope + static rid
  #   LEG 6  MCP guarded handler, healthy helpers -> 500 JSON-RPC error
  #          envelope + rid; faulting generator -> fallback JSON + static rid
  #   LEG 7  BK-XPRIF: typed plug_status < 500 exception (malformed JSON ->
  #          Plug.Parsers.ParseError 400) renders the TYPED 400 — the fence
  #          skips, the 500 envelope is absent (the regression flip)
  #
  # No mocks; every probe is a real HTTP request.

  use ExUnit.Case, async: false

  @fallback_rid "00000000-0000-4000-8000-000000000000"

  @egress_fallback_body "<?xml version=\"1.0\" encoding=\"utf-8\"?><Error><Code>InternalServerError</Code><Message>Internal server error.</Message></Error>"
  @arm_fallback_body "{\"error\":{\"code\":\"InternalServerError\",\"message\":\"Internal server error.\",\"innererror\":{}}}"
  @mcp_fallback_body "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Internal server error.\"},\"id\":null}"

  # ---------------------------------------------------------------------------
  # Rigs. Each handler is copied VERBATIM from its subject router (helpers
  # module-qualified onto the subject's own public API where the subject uses
  # in-module public functions). Boom rigs carry the SHIM-COURT mutation: a
  # fallible helper raises.
  # ---------------------------------------------------------------------------

  defmodule EgressNormalRig do
    use Plug.Router
    use Plug.ErrorHandler
    require Logger

    plug(:match)
    plug(:dispatch)

    # VERBATIM BK-EGS1 Smalt.EgressRouter handle_errors/2; error_xml/2 and
    # generate_request_id/0 are the SUBJECT's own public functions.
    defp handle_errors(conn, %{kind: kind, reason: reason, stack: stack}) do
      # BK-XPRIF: exceptions carrying a typed plug_status < 500 are NOT
      # 500-class crashes — skip the fence so Plug.ErrorHandler's re-raise
      # reaches the adapter, which renders the exception's own typed status.
      if kind == :error and Plug.Exception.status(reason) < 500 do
        Logger.error(
          "bkegs1_fence_court rig typed plug-status crash (fence skipped): " <>
            Exception.format(kind, reason, stack)
        )

        :ok
      else
        try do
          Logger.error("egress_router crash 500: #{Exception.format(kind, reason, stack)}")

          if conn.state in [:unset, :set] do
            conn
            |> put_resp_header("x-ms-request-id", Smalt.EgressRouter.generate_request_id())
            |> put_resp_content_type("application/xml")
            |> send_resp(
              500,
              Smalt.EgressRouter.error_xml("InternalServerError", "Internal server error.")
            )
          end

          :ok
        rescue
          secondary ->
            Logger.error(
              "egress_router handle_errors itself FAULTED (F-EGS1 fallback engaged): " <>
                Exception.format(:error, secondary, __STACKTRACE__)
            )

            fegs1_fallback_send(conn, secondary)
        end
      end
    end

    @fegs1_fallback_request_id "00000000-0000-4000-8000-000000000000"
    @fegs1_fallback_body "<?xml version=\"1.0\" encoding=\"utf-8\"?><Error><Code>InternalServerError</Code><Message>Internal server error.</Message></Error>"

    defp fegs1_fallback_send(conn, _secondary) do
      if conn.state in [:unset, :set] do
        conn
        |> put_resp_header("x-ms-request-id", @fegs1_fallback_request_id)
        |> put_resp_header("content-type", "application/xml; charset=utf-8")
        |> send_resp(500, @fegs1_fallback_body)
      end

      :ok
    end

    get "/boom" do
      raise("bkegs1 raise-in-route (egress normal rig)")
    end

    get "/ok" do
      send_resp(conn, 200, "fine")
    end
  end

  # OLD (pre-BK-EGS1) unguarded handler + SHIM-COURT faulting error_xml/2 —
  # witnesses the naked-500 defect class (BEFORE).
  defmodule EgressBoomRig do
    use Plug.Router
    use Plug.ErrorHandler
    require Logger

    plug(:match)
    plug(:dispatch)

    get "/boom" do
      raise("bkegs1 raise-in-route (egress boom rig)")
    end

    # VERBATIM pre-BK-EGS1 (HEAD) Smalt.EgressRouter handle_errors/2 — NO guard.
    defp handle_errors(conn, %{kind: kind, reason: reason, stack: stack}) do
      Logger.error("egress_router crash 500: #{Exception.format(kind, reason, stack)}")

      if conn.state in [:unset, :set] do
        conn
        |> put_resp_header("x-ms-request-id", Smalt.EgressRouter.generate_request_id())
        |> put_resp_content_type("application/xml")
        |> send_resp(500, poisoned_error_xml("InternalServerError", "Internal server error."))
      end

      :ok
    end

    # SHIM-COURT: error_xml/2 faults — the F-EGS1 trigger class.
    defp poisoned_error_xml(_code, _msg) do
      raise("SHIM-COURT F-EGS1: error_xml/2 faulted")
    end
  end

  # NEW guarded handler + the SAME SHIM-COURT faulting error_xml/2 — the flip.
  defmodule EgressGuardedBoomRig do
    use Plug.Router
    use Plug.ErrorHandler
    require Logger

    plug(:match)
    plug(:dispatch)

    get "/boom" do
      raise("bkegs1 raise-in-route (egress guarded boom rig)")
    end

    # VERBATIM BK-EGS1 Smalt.EgressRouter handle_errors/2 with the real
    # error_xml/2 call site swapped for the SHIM-COURT faulting variant.
    defp handle_errors(conn, %{kind: kind, reason: reason, stack: stack}) do
      # BK-XPRIF: exceptions carrying a typed plug_status < 500 are NOT
      # 500-class crashes — skip the fence so Plug.ErrorHandler's re-raise
      # reaches the adapter, which renders the exception's own typed status.
      if kind == :error and Plug.Exception.status(reason) < 500 do
        Logger.error(
          "bkegs1_fence_court rig typed plug-status crash (fence skipped): " <>
            Exception.format(kind, reason, stack)
        )

        :ok
      else
        try do
          Logger.error("egress_router crash 500: #{Exception.format(kind, reason, stack)}")

          if conn.state in [:unset, :set] do
            conn
            |> put_resp_header("x-ms-request-id", Smalt.EgressRouter.generate_request_id())
            |> put_resp_content_type("application/xml")
            |> send_resp(500, poisoned_error_xml("InternalServerError", "Internal server error."))
          end

          :ok
        rescue
          secondary ->
            Logger.error(
              "egress_router handle_errors itself FAULTED (F-EGS1 fallback engaged): " <>
                Exception.format(:error, secondary, __STACKTRACE__)
            )

            fegs1_fallback_send(conn, secondary)
        end
      end
    end

    @fegs1_fallback_request_id "00000000-0000-4000-8000-000000000000"
    @fegs1_fallback_body "<?xml version=\"1.0\" encoding=\"utf-8\"?><Error><Code>InternalServerError</Code><Message>Internal server error.</Message></Error>"

    defp fegs1_fallback_send(conn, _secondary) do
      if conn.state in [:unset, :set] do
        conn
        |> put_resp_header("x-ms-request-id", @fegs1_fallback_request_id)
        |> put_resp_header("content-type", "application/xml; charset=utf-8")
        |> send_resp(500, @fegs1_fallback_body)
      end

      :ok
    end

    # SHIM-COURT: error_xml/2 faults — the F-EGS1 trigger class.
    defp poisoned_error_xml(_code, _msg) do
      raise("SHIM-COURT F-EGS1: error_xml/2 faulted")
    end
  end

  defmodule ArmNormalRig do
    use Plug.Router
    use Plug.ErrorHandler
    require Logger

    plug(:match)
    plug(:dispatch)

    # VERBATIM BK-EGS1 Smalt.ArmGateway.Router handle_errors/2 (local helpers).
    defp handle_errors(conn, %{kind: kind, reason: reason, stack: stack}) do
      # BK-XPRIF: exceptions carrying a typed plug_status < 500 are NOT
      # 500-class crashes — skip the fence so Plug.ErrorHandler's re-raise
      # reaches the adapter, which renders the exception's own typed status.
      if kind == :error and Plug.Exception.status(reason) < 500 do
        Logger.error(
          "bkegs1_fence_court rig typed plug-status crash (fence skipped): " <>
            Exception.format(kind, reason, stack)
        )

        :ok
      else
        try do
          Logger.error("arm_gateway crash 500: #{Exception.format(kind, reason, stack)}")

          if conn.state in [:unset, :set] do
            rid = conn.private[:arm_request_id] || generate_uuid()

            send_arm_error(
              put_resp_header(conn, "x-ms-request-id", rid),
              500,
              "InternalServerError",
              "Internal server error.",
              conn.request_path
            )
          end

          :ok
        rescue
          secondary ->
            Logger.error(
              "arm_gateway handle_errors itself FAULTED (F-EGS1 fallback engaged): " <>
                Exception.format(:error, secondary, __STACKTRACE__)
            )

            fegs1_fallback_send(conn, secondary)
        end
      end
    end

    @fegs1_fallback_request_id "00000000-0000-4000-8000-000000000000"
    @fegs1_fallback_body "{\"error\":{\"code\":\"InternalServerError\",\"message\":\"Internal server error.\",\"innererror\":{}}}"

    defp fegs1_fallback_send(conn, _secondary) do
      if conn.state in [:unset, :set] do
        conn
        |> put_resp_header("x-ms-request-id", @fegs1_fallback_request_id)
        |> put_resp_header("content-type", "application/json; charset=utf-8")
        |> send_resp(500, @fegs1_fallback_body)
      end

      :ok
    end

    defp send_arm_error(conn, status, code, message, target) do
      body =
        Jason.encode!(%{
          "error" => %{
            "code" => code,
            "message" => message,
            "target" => target,
            "innererror" => %{}
          }
        })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, body)
    end

    defp generate_uuid do
      <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

      :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [
        a,
        b,
        :erlang.band(c, 0x0FFF) + 0x4000,
        :erlang.band(d, 0x3FFF) + 0x8000,
        e
      ])
      |> IO.iodata_to_binary()
    end

    get "/boom" do
      raise("bkegs1 raise-in-route (arm normal rig)")
    end
  end

  # ARM guarded handler + SHIM-COURT faulting rid generator — a fault inside
  # handle_errors (generate_uuid raises since no private id is stashed).
  defmodule ArmBoomRig do
    use Plug.Router
    use Plug.ErrorHandler
    require Logger

    plug(:match)
    plug(:dispatch)

    get "/boom" do
      raise("bkegs1 raise-in-route (arm boom rig)")
    end

    # VERBATIM BK-EGS1 ArmGateway handle_errors/2.
    defp handle_errors(conn, %{kind: kind, reason: reason, stack: stack}) do
      # BK-XPRIF: exceptions carrying a typed plug_status < 500 are NOT
      # 500-class crashes — skip the fence so Plug.ErrorHandler's re-raise
      # reaches the adapter, which renders the exception's own typed status.
      if kind == :error and Plug.Exception.status(reason) < 500 do
        Logger.error(
          "bkegs1_fence_court rig typed plug-status crash (fence skipped): " <>
            Exception.format(kind, reason, stack)
        )

        :ok
      else
        try do
          Logger.error("arm_gateway crash 500: #{Exception.format(kind, reason, stack)}")

          if conn.state in [:unset, :set] do
            rid = conn.private[:arm_request_id] || generate_uuid()

            send_arm_error(
              put_resp_header(conn, "x-ms-request-id", rid),
              500,
              "InternalServerError",
              "Internal server error.",
              conn.request_path
            )
          end

          :ok
        rescue
          secondary ->
            Logger.error(
              "arm_gateway handle_errors itself FAULTED (F-EGS1 fallback engaged): " <>
                Exception.format(:error, secondary, __STACKTRACE__)
            )

            fegs1_fallback_send(conn, secondary)
        end
      end
    end

    @fegs1_fallback_request_id "00000000-0000-4000-8000-000000000000"
    @fegs1_fallback_body "{\"error\":{\"code\":\"InternalServerError\",\"message\":\"Internal server error.\",\"innererror\":{}}}"

    defp fegs1_fallback_send(conn, _secondary) do
      if conn.state in [:unset, :set] do
        conn
        |> put_resp_header("x-ms-request-id", @fegs1_fallback_request_id)
        |> put_resp_header("content-type", "application/json; charset=utf-8")
        |> send_resp(500, @fegs1_fallback_body)
      end

      :ok
    end

    defp send_arm_error(conn, status, code, message, target) do
      body =
        Jason.encode!(%{
          "error" => %{
            "code" => code,
            "message" => message,
            "target" => target,
            "innererror" => %{}
          }
        })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, body)
    end

    # SHIM-COURT: generate_uuid/0 faults — the F-EGS1 trigger class (no
    # stashed private id on this rig, so the || arm is on the crash path).
    defp generate_uuid do
      raise("SHIM-COURT F-EGS1: generate_uuid/0 faulted")
    end
  end

  defmodule McpNormalRig do
    use Plug.Router
    use Plug.ErrorHandler
    require Logger

    plug(:match)
    plug(:dispatch)

    # VERBATIM BK-EGS1 Smalt.Mcp.Router handle_errors/2 (local helpers).
    defp handle_errors(conn, %{kind: kind, reason: reason, stack: stack}) do
      # BK-XPRIF: exceptions carrying a typed plug_status < 500 are NOT
      # 500-class crashes — skip the fence so Plug.ErrorHandler's re-raise
      # reaches the adapter, which renders the exception's own typed status.
      if kind == :error and Plug.Exception.status(reason) < 500 do
        Logger.error(
          "bkegs1_fence_court rig typed plug-status crash (fence skipped): " <>
            Exception.format(kind, reason, stack)
        )

        :ok
      else
        try do
          Logger.error("mcp_router crash 500: #{Exception.format(kind, reason, stack)}")

          if conn.state in [:unset, :set] do
            conn
            |> put_resp_header("x-ms-request-id", generate_uuid())
            |> put_resp_content_type("application/json")
            |> send_resp(
              500,
              Jason.encode!(%{
                "jsonrpc" => "2.0",
                "error" => %{"code" => -32_603, "message" => "Internal server error."},
                "id" => nil
              })
            )
          end

          :ok
        rescue
          secondary ->
            Logger.error(
              "mcp_router handle_errors itself FAULTED (F-EGS1 fallback engaged): " <>
                Exception.format(:error, secondary, __STACKTRACE__)
            )

            fegs1_fallback_send(conn, secondary)
        end
      end
    end

    @fegs1_fallback_request_id "00000000-0000-4000-8000-000000000000"
    @fegs1_fallback_body "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Internal server error.\"},\"id\":null}"

    defp fegs1_fallback_send(conn, _secondary) do
      if conn.state in [:unset, :set] do
        conn
        |> put_resp_header("x-ms-request-id", @fegs1_fallback_request_id)
        |> put_resp_header("content-type", "application/json; charset=utf-8")
        |> send_resp(500, @fegs1_fallback_body)
      end

      :ok
    end

    defp generate_uuid do
      <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

      :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [
        a,
        b,
        :erlang.band(c, 0x0FFF) + 0x4000,
        :erlang.band(d, 0x3FFF) + 0x8000,
        e
      ])
      |> IO.iodata_to_binary()
    end

    get "/boom" do
      raise("bkegs1 raise-in-route (mcp normal rig)")
    end
  end

  # MCP guarded handler + SHIM-COURT faulting rid generator.
  defmodule McpBoomRig do
    use Plug.Router
    use Plug.ErrorHandler
    require Logger

    plug(:match)
    plug(:dispatch)

    get "/boom" do
      raise("bkegs1 raise-in-route (mcp boom rig)")
    end

    # VERBATIM BK-EGS1 Mcp.Router handle_errors/2.
    defp handle_errors(conn, %{kind: kind, reason: reason, stack: stack}) do
      # BK-XPRIF: exceptions carrying a typed plug_status < 500 are NOT
      # 500-class crashes — skip the fence so Plug.ErrorHandler's re-raise
      # reaches the adapter, which renders the exception's own typed status.
      if kind == :error and Plug.Exception.status(reason) < 500 do
        Logger.error(
          "bkegs1_fence_court rig typed plug-status crash (fence skipped): " <>
            Exception.format(kind, reason, stack)
        )

        :ok
      else
        try do
          Logger.error("mcp_router crash 500: #{Exception.format(kind, reason, stack)}")

          if conn.state in [:unset, :set] do
            conn
            |> put_resp_header("x-ms-request-id", generate_uuid())
            |> put_resp_content_type("application/json")
            |> send_resp(
              500,
              Jason.encode!(%{
                "jsonrpc" => "2.0",
                "error" => %{"code" => -32_603, "message" => "Internal server error."},
                "id" => nil
              })
            )
          end

          :ok
        rescue
          secondary ->
            Logger.error(
              "mcp_router handle_errors itself FAULTED (F-EGS1 fallback engaged): " <>
                Exception.format(:error, secondary, __STACKTRACE__)
            )

            fegs1_fallback_send(conn, secondary)
        end
      end
    end

    @fegs1_fallback_request_id "00000000-0000-4000-8000-000000000000"
    @fegs1_fallback_body "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Internal server error.\"},\"id\":null}"

    defp fegs1_fallback_send(conn, _secondary) do
      if conn.state in [:unset, :set] do
        conn
        |> put_resp_header("x-ms-request-id", @fegs1_fallback_request_id)
        |> put_resp_header("content-type", "application/json; charset=utf-8")
        |> send_resp(500, @fegs1_fallback_body)
      end

      :ok
    end

    # SHIM-COURT: generate_uuid/0 faults — the F-EGS1 trigger class.
    defp generate_uuid do
      raise("SHIM-COURT F-EGS1: generate_uuid/0 faulted")
    end
  end

  # BK-XPRIF: parse-400 rig — a typed plug_status < 500 exception
  # (Plug.Parsers.ParseError -> 400) must NOT be swallowed by the fence's 500
  # envelope. Handler is the CURRENT BK-XPRIF Smalt.EgressRouter
  # handle_errors/2, verbatim.
  defmodule EgressParseRig do
    use Plug.Router
    use Plug.ErrorHandler
    require Logger

    plug(Plug.Parsers,
      parsers: [:json],
      pass: ["application/json"],
      json_decoder: Jason
    )

    plug(:match)
    plug(:dispatch)

    post "/ingest" do
      send_resp(conn, 200, "ingested")
    end

    defp handle_errors(conn, %{kind: kind, reason: reason, stack: stack}) do
      if kind == :error and Plug.Exception.status(reason) < 500 do
        Logger.error(
          "egress_router typed plug-status crash (fence skipped, adapter renders typed status): " <>
            Exception.format(kind, reason, stack)
        )

        :ok
      else
        try do
          Logger.error("egress_router crash 500: #{Exception.format(kind, reason, stack)}")

          if conn.state in [:unset, :set] do
            conn
            |> put_resp_header("x-ms-request-id", Smalt.EgressRouter.generate_request_id())
            |> put_resp_content_type("application/xml")
            |> send_resp(
              500,
              Smalt.EgressRouter.error_xml("InternalServerError", "Internal server error.")
            )
          end

          :ok
        rescue
          secondary ->
            Logger.error(
              "egress_router handle_errors itself FAULTED (F-EGS1 fallback engaged): " <>
                Exception.format(:error, secondary, __STACKTRACE__)
            )

            fegs1_fallback_send(conn, secondary)
        end
      end
    end

    @fegs1_fallback_request_id "00000000-0000-4000-8000-000000000000"
    @fegs1_fallback_body "<?xml version=\"1.0\" encoding=\"utf-8\"?><Error><Code>InternalServerError</Code><Message>Internal server error.</Message></Error>"

    defp fegs1_fallback_send(conn, _secondary) do
      if conn.state in [:unset, :set] do
        conn
        |> put_resp_header("x-ms-request-id", @fegs1_fallback_request_id)
        |> put_resp_header("content-type", "application/xml; charset=utf-8")
        |> send_resp(500, @fegs1_fallback_body)
      end

      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Real-Bandit harness (deadline recv via :httpc — no sleeps).
  # ---------------------------------------------------------------------------

  defp start_bandit(rig) do
    {:ok, ref} =
      Bandit.start_link(
        plug: rig,
        ip: {127, 0, 0, 1},
        port: 0,
        thousand_island_options: [read_timeout: 15_000]
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(ref)
    %{ref: ref, port: port}
  end

  defp http_get(port, path) do
    url = 'http://127.0.0.1:#{port}#{path}'

    case :httpc.request(:get, {url, []}, [timeout: 15_000, connect_timeout: 15_000], []) do
      {:ok, {{_v, status, _p}, headers, body}} ->
        headers = for {k, v} <- headers, do: {String.downcase(to_string(k)), to_string(v)}
        {:ok, status, headers, to_string(body)}

      other ->
        {:error, other}
    end
  end

  defp http_post(port, path, body, content_type) do
    url = 'http://127.0.0.1:#{port}#{path}'

    request = {
      url,
      [],
      String.to_charlist(content_type),
      String.to_charlist(body)
    }

    case :httpc.request(:post, request, [timeout: 15_000, connect_timeout: 15_000], []) do
      {:ok, {{_v, status, _p}, headers, resp}} ->
        headers = for {k, v} <- headers, do: {String.downcase(to_string(k)), to_string(v)}
        {:ok, status, headers, to_string(resp)}

      other ->
        {:error, other}
    end
  end

  defp rid(headers) do
    case List.keyfind(headers, "x-ms-request-id", 0) do
      {_, v} -> v
      nil -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Legs
  # ---------------------------------------------------------------------------

  @tag :bkegs1_fence_court
  test "LEG1 egress guarded handler renders the Storage envelope on a route crash" do
    srv = start_bandit(EgressNormalRig)

    assert {:ok, 200, _h, "fine"} = http_get(srv.port, "/ok")

    {:ok, 500, headers, body} = http_get(srv.port, "/boom")
    assert body =~ "<Code>InternalServerError</Code>"
    assert r = rid(headers)
    refute r == @fallback_rid
    assert r != @fallback_rid
  end

  @tag :bkegs1_fence_court
  test "LEG2 OLD unguarded handler + faulting error_xml renders the NAKED 500 (F-EGS1 defect witnessed)" do
    srv = start_bandit(EgressBoomRig)

    {:ok, 500, headers, body} = http_get(srv.port, "/boom")
    assert body == ""
    assert is_nil(rid(headers))
  end

  @tag :bkegs1_fence_court
  test "LEG3 guarded handler + the SAME faulting error_xml renders the constant fallback envelope (the flip)" do
    srv = start_bandit(EgressGuardedBoomRig)

    {:ok, 500, headers, body} = http_get(srv.port, "/boom")
    assert body == @egress_fallback_body
    assert rid(headers) == @fallback_rid
  end

  @tag :bkegs1_fence_court
  test "LEG4 ARM guarded handler renders the ARM envelope on a route crash" do
    srv = start_bandit(ArmNormalRig)

    {:ok, 500, headers, body} = http_get(srv.port, "/boom")
    assert body =~ "\"code\":\"InternalServerError\""
    assert r = rid(headers)
    refute r == @fallback_rid
    assert r != @fallback_rid
  end

  @tag :bkegs1_fence_court
  test "LEG5 ARM guarded handler + faulting rid generator renders the fallback ARM envelope" do
    srv = start_bandit(ArmBoomRig)

    {:ok, 500, headers, body} = http_get(srv.port, "/boom")
    assert body == @arm_fallback_body
    assert rid(headers) == @fallback_rid
  end

  @tag :bkegs1_fence_court
  test "LEG6 MCP guarded handler renders the JSON-RPC envelope; faulting generator flips to the fallback" do
    srv = start_bandit(McpNormalRig)
    {:ok, 500, headers, body} = http_get(srv.port, "/boom")
    assert body =~ "\"code\":-32603"
    assert r = rid(headers)
    refute r == @fallback_rid
    assert r != @fallback_rid

    boom = start_bandit(McpBoomRig)
    {:ok, 500, headers2, body2} = http_get(boom.port, "/boom")
    assert body2 == @mcp_fallback_body
    assert rid(headers2) == @fallback_rid
  end

  @tag :bkegs1_fence_court
  test "LEG7 BK-XPRIF: malformed-JSON parse error renders the TYPED 400, never the 500 fence envelope" do
    srv = start_bandit(EgressParseRig)

    malformed = ~s({"format": )

    {:ok, 400, headers, body} =
      http_post(srv.port, "/ingest", malformed, "application/json")

    # typed 400 face: Bandit renders the status with an EMPTY body (the exact
    # pre-fence parse-error face) — the load-bearing assert is the ABSENCE of
    # the fence's 500 envelope
    assert body == ""
    refute body =~ "<Code>InternalServerError</Code>"
    assert body != @egress_fallback_body
    # the fence's 500 face must be ABSENT: no envelope, no x-ms-request-id
    assert is_nil(rid(headers))

    # control: well-formed JSON still reaches the route
    assert {:ok, 200, _h, "ingested"} =
             http_post(srv.port, "/ingest", "{\"a\": 1}", "application/json")
  end
end
