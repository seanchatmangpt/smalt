defmodule Smalt.Planes.Router.Twilio do
  @moduledoc false
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    planes = Map.get(conn.private, :planes_opts, [])
    tw = Keyword.get(planes, :twilio, [])

    tw =
      if Keyword.has_key?(tw, :store),
        do: tw,
        else: Keyword.put(tw, :store, Smalt.Planes.Router.twilio_store())

    Smalt.Twilio.Router.call(conn, Smalt.Twilio.Router.init(tw))
  end
end

defmodule Smalt.Planes.Router.Dyn do
  @moduledoc false
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    mod = Keyword.fetch!(opts, :module)

    if Code.ensure_loaded?(mod) and function_exported?(mod, :call, 2) do
      mod.call(conn, mod.init([]))
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(501, Jason.encode!(%{"type" => "not_implemented", "module" => inspect(mod)}))
    end
  end
end

defmodule Smalt.Planes.Router do
  @moduledoc """
  Unified plane router: /treasury, /erp, /twilio, /tax, /rates.

  `/tax` and `/rates` forward to `Smalt.TaxSanctions.Http` / `Smalt.Rates.Http`
  when those modules are loadable, else answer 501. `/twilio` takes Twilio router
  options (`account_sid:`, `auth_token:`, `base_url:`, `store:`) via `twilio: [...]`.
  """
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  def call(conn, opts) do
    conn = Plug.Conn.put_private(conn, :planes_opts, opts)
    super(conn, opts)
  end

  @doc "Lazily started shared Twilio store, used when `twilio: [store:]` is absent."
  def twilio_store do
    case :persistent_term.get({__MODULE__, :twilio_store}, nil) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: pid, else: start_twilio_store()

      _ ->
        start_twilio_store()
    end
  end

  defp start_twilio_store do
    {:ok, pid} = Agent.start(fn -> %{numbers: [], messages: [], calls: [], events: []} end)
    :persistent_term.put({__MODULE__, :twilio_store}, pid)
    pid
  end

  forward("/treasury", to: Smalt.Treasury.Router)
  forward("/erp", to: Smalt.Erp.Router)
  forward("/twilio", to: Smalt.Planes.Router.Twilio)
  forward("/tax", to: Smalt.Planes.Router.Dyn, init_opts: [module: Smalt.TaxSanctions.Http])
  forward("/rates", to: Smalt.Planes.Router.Dyn, init_opts: [module: Smalt.Rates.Http])

  match _ do
    send_resp(conn, 404, Jason.encode!(%{"type" => "not_found"}))
  end
end
