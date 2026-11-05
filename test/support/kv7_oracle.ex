defmodule SmaltTest.Kv7Oracle do
  @moduledoc """
  kv7 BEAM-oracle live leg (L16, v26.11.5): wire client + posh translate-face
  driver for the live cross-check.

  The BEAM data plane (8443, real HTTP, real stores) is the ORACLE; the posh
  kv7 sub-dialect translate face is pinned against it on the same keys: the
  same sequence, and the posh face's (status, body) must agree with the BEAM
  wire answers (key sets + scalars).

  BEAM leg auth: the data plane's documented dev admission law (KD-114
  SharedKey scheme - per-account key base64(sha256(account <> "smalt-dev-sb")),
  2021-12-02 StringToSign) - the WO-32 cordon removed the BEAM 9443 STS mint
  face, so SharedKey is the lawful data-plane client credential this window.
  Tokenless first touch = the KD-15 challenge leg.

  posh leg: a runtime-generated Go driver (kv7-oracle-l16-driver/ under the posh
  module root, deleted on exit) speaking line-delimited JSON over stdio to
  the posh delegation bindings (azure.Kv7TranslateFor). ONE driver port,
  lazily started, held in :persistent_term.

  Substrate down: loud typed skip - never a fake pass. No sleeps: readiness
  is a bounded TCP-dial poll (SmaltTest.AssertEventually).
  """

  import SmaltTest.AssertEventually, only: [assert_eventually: 2]

  # C9 SLA minimal unblock (disclosed in the C9 receipt; owner L16 supersedes
  # on landing): `flunk/1` is referenced at line 321 but unimported — this
  # breaks the shared test/support compile for every lane's gates.
  import ExUnit.Assertions, only: [flunk: 1]

  @host "127.0.0.1"
  @data_port 8443
  @ready_timeout 30_000
  @wire_timeout 15_000
  @account "kv7oracle"

  # -- substrate readiness --------------------------------------------------

  @doc "Bounded TCP-dial poll until the data plane listens; loud skip otherwise."
  @spec require_substrate!() :: :ok
  def require_substrate! do
    up? =
      assert_eventually(
        fn -> port_open?() end,
        timeout: @ready_timeout,
        interval: 250
      )

    unless up? do
      raise ExUnit.SkipError,
            "SKIP LOUD: smalt data plane :#{@data_port} not listening within " <>
              "#{div(@ready_timeout, 1000)}s - substrate down; never a fake pass"
    end

    :ok
  end

  defp port_open? do
    match?({:ok, _}, :gen_tcp.connect(~c"127.0.0.1", @data_port, [], 500))
  end

  # -- BEAM wire face ---------------------------------------------------------

  @doc "The SharedKey account this court authenticates as."
  def account, do: @account

  @doc """
  One BEAM kv7 call with SharedKey admission. Returns {status, body-map}.
  `tokenless: true` drops the Authorization header (the KD-15 challenge leg).
  """
  @spec beam_call(atom, String.t(), String.t() | nil, keyword) :: {non_neg_integer(), map()}
  def beam_call(method, path, body \\ nil, opts \\ []) do
    uri = URI.parse("http://#{@host}:#{@data_port}" <> path)
    payload = body || ""
    tokenless? = Keyword.get(opts, :tokenless, false)
    xms_date = ms_date()
    ctype = if body, do: "application/json", else: ""

    # Smalt.Auth.SharedKey.string_to_sign/2 legs (2021-12-02 shape), rebuilt
    # from the headers the request actually carries on the wire.
    clen = if payload == "", do: "", else: payload |> byte_size() |> Integer.to_string()

    date_leg =
      if tokenless?,
        do: "",
        else: ""

    method_bin = String.upcase(to_string(method))

    standard = [
      method_bin,
      "",
      "",
      clen,
      "",
      ctype,
      date_leg,
      "",
      "",
      "",
      "",
      ""
    ]

    xms =
      if tokenless? do
        []
      else
        [{"x-ms-date", xms_date}, {"x-ms-version", "2021-12-02"}]
      end

    xms_canon =
      xms
      |> Enum.sort(fn {a, _}, {b, _} -> a <= b end)
      |> Enum.map_join("", fn {k, v} -> k <> ":" <> v <> "\n" end)

    canon_resource = "/" <> @account <> uri.path <> query_part(uri.query || "")

    sts =
      Enum.join(standard, "\n") <> "\n" <> xms_canon <> canon_resource

    request_headers =
      xms ++
        (if body, do: [{"content-type", "application/json"}], else: []) ++
        (if tokenless?,
          do: [],
          else: [{"authorization", shared_key(method, sts)}]
        )

    request =
      "#{method_bin} #{uri.path}" <>
        if(uri.query, do: "?" <> uri.query, else: "") <>
        " HTTP/1.1\r\n" <>
        "host: #{@host}:#{@data_port}\r\n" <>
        "connection: close\r\n" <>
        Enum.map_join(request_headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end) <>
        "content-length: #{byte_size(payload)}\r\n\r\n" <> payload

    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", @data_port, [:binary], @wire_timeout)
    :ok = :gen_tcp.send(sock, request)
    raw = recv_response(sock, <<>>, deadline())
    :ok = :gen_tcp.close(sock)

    {status, headers, resp_body} = parse_response(raw)
    :persistent_term.put({__MODULE__, :challenge}, Map.has_key?(headers, "www-authenticate"))
    {status, decode!(status, resp_body)}
  end

  # Wire twin of Smalt.Auth.SharedKey.canonicalized_resource/2 (raw query
  # values, name lowercased, each "\nname:value", sorted case-insensitively).
  defp query_part("" = _qs), do: ""
  defp query_part(qs) when is_binary(qs) do
    qs
    |> String.split("&", trim: true)
    |> Enum.map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [n] -> {n, ""}
        [n, v] -> {n, v}
      end
    end)
    |> Enum.sort(fn {a, _}, {b, _} -> String.downcase(a) <= String.downcase(b) end)
    |> Enum.map(fn {n, v} -> "\n" <> String.downcase(n) <> ":" <> v end)
    |> Enum.join()
  end

  defp shared_key(_method, sts) do
    key = :crypto.hash(:sha256, @account <> "smalt-dev-sb")
    sig = Base.encode64(:crypto.mac(:hmac, :sha256, key, sts))
    "SharedKey #{@account}:#{sig}"
  end

  defp ms_date do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
  end

  @doc "True when the most recent wire response carried WWW-Authenticate."
  @spec challenge?() :: boolean()
  def challenge?, do: :persistent_term.get({__MODULE__, :challenge}, false)

  # -- raw HTTP/1.1 transport -------------------------------------------------

  defp deadline, do: System.monotonic_time(:millisecond) + @wire_timeout

  defp recv_response(sock, buf, dl) do
    if System.monotonic_time(:millisecond) >= dl do
      :gen_tcp.close(sock)
      raise "kv7 oracle: wire read exceeded deadline"
    end

    receive do
      {:tcp, ^sock, data} ->
        buf2 = buf <> data
        if response_complete?(buf2), do: buf2, else: recv_response(sock, buf2, dl)

      {:tcp_closed, ^sock} ->
        buf

      {:tcp_error, ^sock, reason} ->
        raise "kv7 oracle: tcp error #{inspect(reason)}"
    after
      1_000 -> recv_response(sock, buf, dl)
    end
  end

  defp response_complete?(buf) do
    case :binary.split(buf, "\r\n\r\n") do
      [_head, body] ->
        case content_length(buf) do
          nil -> false
          n -> byte_size(body) >= n
        end

      _ ->
        false
    end
  end

  def chunked?(_buf), do: false

  defp content_length(buf) do
    case :binary.split(buf, "\r\n\r\n") do
      [head, _] ->
        head
        |> String.split("\r\n")
        |> Enum.find_value(fn line ->
          case String.downcase(line) do
            "content-length: " <> n ->
              String.to_integer(String.trim(n))

            _ ->
              nil
          end
        end)

      _ ->
        nil
    end
  end

  defp parse_response(raw) do
    [head, body] = :binary.split(raw, "\r\n\r\n")
    [status_line | header_lines] = String.split(head, "\r\n")

    status =
      status_line
      |> String.split(" ")
      |> Enum.at(1)
      |> String.to_integer()

    headers =
      Map.new(header_lines, fn line ->
        [k, v] = String.split(line, ": ", parts: 2)
        {String.downcase(k), v}
    end)

    {status, headers, body}
  end

  defp decode!(status, body) do
    case Jason.decode(body) do
      {:ok, map} -> map
      _ -> %{"raw" => body}
    end
  end

  # -- posh translate face (Go driver) ---------------------------------------

  @driver_rel "kv7-oracle-l16-driver"

  @doc """
  Renders one store row through the posh kv7 delegation binding for op
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
    resp = recv_line(port, <<>>, deadline())

    case Jason.decode(resp) do
      {:ok, %{"ok" => true, "status" => status, "body" => body}} ->
        {:ok, status, body}

      {:ok, %{"ok" => false, "error" => err}} ->
        {:error, err}

      other ->
        {:error, "posh driver: undecodable response #{inspect(other)}"}
    end
  end

  @doc "Kills the driver and removes the runtime tree (on_exit hook)."
  @spec stop_driver() :: :ok
  def stop_driver do
    case :persistent_term.get({__MODULE__, :driver}, nil) do
      nil -> :ok
      port ->
        try do
          Port.close(port)
        catch
          :error, _ -> :ok
        end
    end

    :persistent_term.erase({__MODULE__, :driver})
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

    {out, rc} =
      System.cmd("go", ["build", "-o", exe, "."], cd: dir, stderr_to_stdout: true)

    if rc != 0 do
      flunk("kv7 oracle: posh driver build failed: #{out}")
    end

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

  defp posh_root, do: Path.expand("../../posh", __DIR__)

  defp recv_line(port, buf, dl) do
    if System.monotonic_time(:millisecond) >= dl do
      raise "kv7 oracle: posh driver read exceeded deadline"
    end

    receive do
      {^port, {:data, {:eol, line}}} ->
        String.trim_trailing(line, "\r\n")

      {^port, {:data, data}} when is_binary(data) ->
        case :binary.split(buf <> data, "\n") do
          [line, _] -> String.trim_trailing(line, "\r\n")
          _ -> recv_line(port, buf <> data, dl)
        end

      {^port, {:exit_status, code}} ->
        raise "kv7 oracle: posh driver exited #{code}"
    after
      500 -> recv_line(port, buf, dl)
    end
  end
  # The driver is law-free: it ONLY resolves the op's delegation binding via
  # azure.Kv7TranslateFor and returns what the posh face answered - zero
  # kv7 law re-stated here (KD-03 split-brain law; the posh wire court is
  # the byte-fidelity authority).
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
    	for sc.Scan() {
    		var r req
    		if err := json.Unmarshal(sc.Bytes(), &r); err != nil {
    			emit(marshal(map[string]any{"ok": false, "error": fmt.Sprint(err)}))
    			continue
    		}
    		h, ok := azure.Kv7TranslateFor(r.Op)
    		if !ok {
    			emit(marshal(map[string]any{"ok": false, "error": "unbound op " + r.Op}))
    			continue
    		}
    		status, body, err := h(r.Params, r.Row)
    		if err != nil {
    			emit(marshal(map[string]any{"ok": false, "error": fmt.Sprint(err)}))
    			continue
    		}
    		emit(marshal(map[string]any{"ok": true, "status": status, "body": body}))
    	}
    }

    func marshal(v any) []byte {
    	b, _ := json.Marshal(v)
    	return b
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
