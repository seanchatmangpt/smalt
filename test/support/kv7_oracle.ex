defmodule SmaltTest.Kv7Oracle do
  # SLA minimal unblock (L20, disclosed in l20 receipt): `flunk/1` was
  # unimported, breaking shared test/support compile for all lanes.
  import ExUnit.Assertions, only: [flunk: 1]

  @moduledoc """
  kv7 BEAM-oracle live leg (L16, v26.11.5): wire client + posh translate-face
  driver for the live cross-check.

  The BEAM data plane (8443, real HTTP) is the ORACLE; the posh kv7
  sub-dialect translate face is compared against it: same keys, same
  sequence, and the posh face's (status, body) must agree with the BEAM wire
  answers (key sets + scalars).

  Legs:

  - BEAM face: real HTTP with the KD-15 challenge handshake (tokenless 401 +
    WWW-Authenticate, then bearer resend); readiness via a bounded TCP-dial
    poll (SmaltTest.AssertEventually - no sleeps).
  - posh face: a runtime-generated `go run` driver (`.kv7-oracle-l16/` under
    the posh module root, deleted on exit) speaking line-delimited JSON over
    stdin/stdout to the posh delegation bindings (azure.Kv7TranslateFor).
    ONE driver port, lazily started, held in :persistent_term.

  Substrate down: loud typed skip (ExUnit.SkipError) - never a fake pass.
  """

  import SmaltTest.AssertEventually, only: [assert_eventually: 2]

  @host "127.0.0.1"
  @data_port 8443
  @arm_port 9443
  @ready_timeout 30_000
  @wire_timeout 15_000

  # -- substrate readiness (bounded poll, no sleeps) --------------------------

  @doc "Bounded TCP-dial poll until both planes listen; loud skip otherwise."
  @spec require_substrate!() :: :ok
  def require_substrate! do
    up? =
      assert_eventually(
        fn -> tcp_open?(@data_port) and tcp_open?(@arm_port) end,
        timeout: @ready_timeout,
        interval: 250
      )

    unless up? do
      raise ExUnit.SkipError,
            "SKIP LOUD: smalt substrate (ARM :#{@arm_port} / data :#{@data_port}) not " <>
              "listening within #{div(@ready_timeout, 1000)}s - substrate down; never a fake pass"
    end

    :ok
  end

  defp tcp_open?(port) do
    match?({:ok, _}, :gen_tcp.connect(~c"127.0.0.1", port, [], 500))
  end

  # -- bearer mint (the live ARM plane's own OAuth face) ----------------------

  @doc """
  Mints a real bearer from the live ARM OAuth face
  (/organizations/oauth2/v2.0/token) - the same mint the acceptance probe
  consumes. The court never bypasses the claims law with a locally-signed
  token.
  """
  @spec mint_token() :: String.t()
  def mint_token do
    form =
      "grant_type=client_credentials&client_id=kv7-oracle-court" <>
        "&client_secret=kv7-oracle-court&scope=https://vault.azure.net/.default"

    {200, %{"access_token" => token}} =
      wire_call(:post, arm_base() <> "/organizations/oauth2/v2.0/token", form, nil,
        content_type: "application/x-www-form-urlencoded"
      )

    token
  end

  def arm_base, do: "http://#{@host}:#{@arm_port}"

  # -- BEAM wire face ---------------------------------------------------------

  @doc """
  One BEAM kv7 call. Returns {status, decoded-body}. `token: nil` is the
  KD-15 tokenless leg (the 401 challenge); the court asserts the challenge
  header via `challenge?/0` after the tokenless call.
  """
  @spec beam_call(atom, String.t(), String.t() | nil, String.t() | nil) ::
          {non_neg_integer(), map()}
  def beam_call(method, path, body \\ nil, token \\ nil) do
    wire_call(method, data_base() <> path, body, token)
  end

  def data_base, do: "http://#{@host}:#{@data_port}"

  @doc "True when the most recent wire response carried WWW-Authenticate."
  @spec challenge?() :: boolean()
  def challenge?, do: :persistent_term.get({__MODULE__, :challenge}, false)

  # -- raw HTTP/1.1 wire transport (curl-free, transport failures typed) ------

  defp wire_call(method, url, body, token, opts \\ []) do
    method_bin = :erlang.atom_to_binary(method)

    headers =
      [
        {"accept", "application/json"},
        {"connection", "close"}
      ]

    headers =
      case body do
        nil -> headers
        _ -> [{"content-type", Keyword.get(opts, :content_type, "application/json")} | headers]
      end

    headers =
      case token do
        nil -> headers
        t -> [{"authorization", "Bearer " <> t} | headers]
      end

    uri = URI.parse(url)
    port = uri.port || 80
    path_query = if uri.query, do: uri.path <> "?" <> uri.query, else: uri.path
    payload = body || ""

    request =
      "#{method_bin} #{path_query} HTTP/1.1\r\n" <>
        "host: #{uri.host}:#{port}\r\n" <>
        Enum.map_join(headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end) <>
        "content-length: #{byte_size(payload)}\r\n\r\n" <> payload

    {:ok, sock} = :gen_tcp.connect(String.to_charlist(uri.host), port, [:binary], @wire_timeout)
    :ok = :gen_tcp.send(sock, request)
    raw = recv_all(sock, <<>>, deadline(@wire_timeout))
    :ok = :gen_tcp.close(sock)

    {status, resp_headers, resp_body} = parse_response(raw)
    record_challenge(resp_headers)
    {status, decode!(status, resp_body)}
  end

  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms

  defp recv_all(sock, buf, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      :gen_tcp.close(sock)
      raise "kv7 oracle: wire read exceeded deadline"
    end

    receive do
      {:tcp, ^sock, data} ->
        buf = buf <> data

        cond do
          response_complete?(buf) -> buf
          true -> recv_all(sock, buf, deadline)
        end

      {:tcp_closed, ^sock} ->
        buf

      {:tcp_error, ^sock, reason} ->
        raise "kv7 oracle: tcp error #{inspect(reason)}"
    after
      1_000 -> recv_all(sock, buf, deadline)
    end
  end

  defp response_complete?(buf) do
    case :binary.split(buf, "\r\n\r\n") do
      [_head, body] ->
        case content_length(buf) do
          nil ->
            # connection: close — EOF-terminated; the socket close tick
            # delivers the final {:tcp_closed, _} with whatever arrived.
            false

          n ->
            byte_size(body) >= n
        end

      _ ->
        false
    end
  end

  defp content_length(buf) do
    case :binary.split(buf, "\r\n\r\n") do
      [head, _] ->
        head
        |> String.split("\r\n")
        |> Enum.find_value(fn line ->
          case String.downcase(line) do
            "content-length: " <> n -> String.to_integer(String.trim(n))
            _ -> nil
          end
        end)

      _ ->
        nil
    end
  end

  defp parse_response(raw) do
    [head, body] = :binary.split(raw, "\r\n\r\n")
    [status_line | header_lines] = String.split(head, "\r\n")
    status = status_line |> String.split(" ") |> Enum.at(1) |> String.to_integer()

    headers =
      Map.new(header_lines, fn line ->
        [k, v] = String.split(line, ": ", parts: 2)
        {String.downcase(k), v}
      end)

    {status, headers, body}
  end

  defp record_challenge(headers) do
    if Map.has_key?(headers, "www-authenticate") do
      :persistent_term.put({__MODULE__, :challenge}, true)
    else
      :persistent_term.put({__MODULE__, :challenge}, false)
    end
  end

  defp decode!(status, body) when status in 200..299 do
    case Jason.decode(body) do
      {:ok, map} -> map
      _ -> flunk("kv7 oracle: non-JSON 2xx body: #{inspect(body)}")
    end
  end

  defp decode!(status, body) when status in [400, 401, 404] do
    case Jason.decode(body) do
      {:ok, map} -> map
      _ -> %{"raw" => body}
    end
  end

  defp decode!(_status, body), do: %{"raw" => body}

  # -- posh kv7 translate face (go driver) ------------------------------------

  @driver_rel ".kv7-oracle-l16"

  @doc """
  Renders one store row through the posh kv7 delegation binding for `op`
  (azure.Kv7TranslateFor) via a runtime-generated Go driver. Returns
  {:ok, status, body-map} or {:error, binary} exactly as the posh face
  answered.
  """
  @spec posh_translate(String.t(), map(), map()) ::
          {:ok, non_neg_integer(), map()} | {:error, String.t()}
  def posh_translate(op, row, params \\ %{}) do
    port = driver_port()

    req = Jason.encode!(%{op: op, params: params, row: row})
    Port.command(port, req <> "\n")
    resp = recv_line(port, <<>>, deadline(@wire_timeout))

    case Jason.decode(resp) do
      {:ok, %{"ok" => true, "status" => status, "body" => body}} ->
        {:ok, status, body}

      {:ok, %{"ok" => false, "error" => err}} ->
        {:error, err}

      other ->
        {:error, "posh driver: undecodable response #{inspect(other)}"}
    end
  end

  @doc "Kills the driver and removes the runtime driver tree (on_exit hook)."
  @spec stop_driver() :: :ok
  def stop_driver do
    case :persistent_term.get({__MODULE__, :driver}, nil) do
      nil -> :ok
      port -> Port.close(port)
    end

    :persistent_term.erase({__MODULE__, :driver}, nil)
    File.rm_rf(Path.join(posh_root(), @driver_rel))
    :ok
  end

  defp driver_port do
    :persistent_term.get({__MODULE__, :driver}, nil) || start_driver()
  end

  defp start_driver do
    dir = Path.join(posh_root(), @driver_rel)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "main.go"), driver_source())
    exe = Path.join(dir, "kv7_oracle_driver")

    {out, 0} =
      System.cmd("go", ["build", "-o", exe, "."],
        cd: dir,
        stderr_to_stdout: true
      )

    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :stream,
        :use_stdio,
        :exit_status,
        {:line, 262_144}
      ])

    :persistent_term.put({__MODULE__, :driver}, port)
    port
  end

  defp posh_root, do: Path.expand("../posh", __DIR__)

  defp recv_line(port, buf, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      raise "kv7 oracle: posh driver read exceeded deadline"
    end

    receive do
      {^port, {:data, data}} ->
        case :binary.split(buf <> data, "\n") do
          [line, _rest] -> String.replace_suffix(line, "\r", "")
          _ -> recv_line(port, buf <> data, deadline)
        end

      {^port, {:exit_status, code}} ->
        raise "kv7 oracle: posh driver exited #{code}"
    after
      500 -> recv_line(port, buf, deadline)
    end
  end

  # The driver is law-free: it ONLY resolves the op's delegation binding via
  # azure.Kv7TranslateFor and returns what the posh face answered - zero
  # drop-list / lifecycle / id-grammar law re-stated here (KD-03 split-brain
  # law; the posh wire court is the byte-fidelity authority).
  defp driver_source do
    ~S"""
    package main

    import (
    	"bufio"
    	"encoding/json"
    	"fmt"
    	"os"

    	"smalt.dev/posh/internal/dialect/azure"
    )

    type req struct {
    	Op     string            `json:"op"`
    	Params map[string]string `json:"params"`
    	Row    map[string]any    `json:"row"`
    }

    func main() {
    	sc := bufio.NewScanner(os.Stdin)
    	sc.Buffer(make([]byte, 1024*1024), 16*1024*1024)
    	w := bufio.NewWriter(os.Stdout)
    	defer w.Flush()
    	for sc.Scan() {
    		var r req
    		if err := json.Unmarshal(sc.Bytes(), &r); err != nil {
    			out, _ := json.Marshal(map[string]any{"ok": false, "error": fmt.Sprint(err)})
    			emit(out)
    			continue
    		}
    		h, ok := azure.Kv7TranslateFor(r.Op)
    		if !ok {
    			out, _ := json.Marshal(map[string]any{"ok": false, "error": "unbound op " + r.Op})
    			emit(out)
    			continue
    		}
    		status, body, err := h(r.Params, r.Row)
    		if err != nil {
    			out, _ := json.Marshal(map[string]any{"ok": false, "error": fmt.Sprint(err)})
    			emit(out)
    			continue
    		}
    		out, _ := json.Marshal(map[string]any{"ok": true, "status": status, "body": body})
    		emit(out)
    	}
    }

    func emit(b []byte) {
    	w := bufio.NewWriter(os.Stdout)
    	w.Write(b)
    	w.WriteByte('\n')
    	w.Flush()
    }
    """
  end
end
