defmodule PopcornDemo.Transport do
  @moduledoc """
  Transport behaviour + two REAL implementations (no mocks).

  - `PopcornDemo.Transport.Fetch` — browser `fetch()` via `Popcorn.Fetch`.
  - `PopcornDemo.Transport.Httpc` — real `:httpc`, http://127.0.0.1 only.

  Chicago school: Httpc is a real degraded collaborator (real sockets, real
  substrate responses), not a test double.
  """

  @type req :: %{
          required(:method) => String.t(),
          required(:url) => String.t(),
          optional(:headers) => [{String.t(), String.t()}],
          optional(:body) => binary
        }

  @type header :: {String.t(), String.t()}

  @type resp :: %{:status => pos_integer(), :body => binary(), optional(:headers) => [header()]}

  @callback request(req()) :: {:ok, resp()} | {:error, term()}
end

defmodule PopcornDemo.Transport.Fetch do
  @moduledoc """
  Browser transport — delegates to `Popcorn.Fetch.request/1`. Only functional
  inside a browser VM (JS bridge); on host it returns `{:error, _}`.
  """

  @behaviour PopcornDemo.Transport

  @impl true
  def request(req) do
    if Code.ensure_loaded?(Popcorn.Fetch) do
      case Popcorn.Fetch.request(req) do
        {:ok, %{status: _, body: _, headers: _}} = ok -> ok
        {:error, _} = err -> err
        other -> {:error, {:fetch_unexpected, other}}
      end
    else
      {:error, :popcorn_fetch_unavailable}
    end
  end
end

defmodule PopcornDemo.Transport.Httpc do
  @moduledoc """
  Real `:httpc` transport. Hard-refuses any host other than loopback
  (degraded alternative, not a mock).

  Loopback guard accepts both `127.0.0.1` and `localhost`: `localhost`
  resolves to loopback on every supported host and no test or caller relies
  on refusing it (the refusal test uses a public host, `example.com`);
  tightening to the literal IP would buy nothing while breaking
  human-typed URLs. Non-loopback hosts are still hard-refused.

  Content-type (ERRC-E2 close): a body-carrying request honors the caller's
  `content-type` header when one is present in the request headers;
  `application/x-www-form-urlencoded` is the default only when the caller
  sent none. Empty-body requests stay bodyless (no content-type at all), so
  content-length behavior on PUT/GET with no body is unchanged.
  """

  @behaviour PopcornDemo.Transport

  @default_ct ~c"application/x-www-form-urlencoded"

  @impl true
  def request(%{method: method, url: url} = req) do
    with {:ok, _} <- loopback_only(url),
         :ok <- ensure_started() do
      headers = headers_to_charlists(Map.get(req, :headers, []))
      body = Map.get(req, :body)

      request_spec =
        if body in [nil, ""] do
          {String.to_charlist(url), headers}
        else
          {String.to_charlist(url), headers, content_type(req.headers), body}
        end

      case :httpc.request(method_atom(method), request_spec, [ssl: [verify: :verify_none], timeout: 10_000], body_format: :binary) do
        {:ok, {{_version, status, _reason}, resp_headers, resp_body}} ->
          {:ok, %{status: status, headers: resp_headers_lc(resp_headers), body: resp_body}}

        {:error, reason} ->
          {:error, {:httpc, reason}}
      end
    end
  end

  defp loopback_only(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "http", host: host}} = ok when host in ["127.0.0.1", "localhost"] ->
        ok

      {:ok, %URI{}} ->
        {:error, {:httpc_refused, "PopcornDemo.Transport.Httpc serves http://127.0.0.1 only"}}

      {:error, _} = err ->
        err
    end
  end

  # Caller-set content-type wins; the form default applies only when the
  # caller sent no content-type header at all.
  defp content_type(nil), do: @default_ct

  defp content_type(headers) when is_list(headers) do
    Enum.find_value(headers, @default_ct, fn
      {k, v} -> if String.downcase(k) == "content-type", do: to_charlist(v)
      _ -> nil
    end)
  end

  defp content_type(_), do: @default_ct

  defp ensure_started do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    # Mix only puts dependency-closure ebins on the code path; :inets/:ssl are
    # not in popcorn_demo's dep tree, so add their OTP lib ebins explicitly.
    Enum.each([:inets, :ssl, :public_key], fn app ->
      lib_root = :code.lib_dir()
      pattern = :filename.join([lib_root, Atom.to_charlist(app) ++ ~c"-*", ~c"ebin"])

      case :filelib.wildcard(pattern) do
        [ebin | _] ->
          unless Enum.member?(:code.get_path(), ebin), do: :code.add_pathz(ebin)

        [] ->
          :ok
      end
    end)

    :ok
  end

  defp method_atom(m) when is_binary(m), do: String.to_atom(String.downcase(m))

  # :httpc hands back charlist headers; surface them as lowercase-string-keyed
  # {name, value} pairs so callers can assert the KD-15 WWW-Authenticate
  # challenge directly off the wire.
  defp resp_headers_lc(charlist_headers) when is_list(charlist_headers) do
    Enum.map(charlist_headers, fn {name, value} ->
      {String.downcase(to_string(name)), to_string(value)}
    end)
  end

  defp resp_headers_lc(_), do: []

  defp headers_to_charlists(headers) when is_list(headers) do
    Enum.map(headers, fn {k, v} ->
      {String.to_charlist(String.downcase(k)), String.to_charlist(v)}
    end)
  end

  defp headers_to_charlists(_), do: []
end
