defmodule Smalt.Routelaw do
  @moduledoc """
  Route law: https://fnox.io/{role}/{otype}_{ulid}/{surface}.
  Elixir mirror of arcus TW5; both consume test/fixtures/routelaw_vectors.json.
  Pure parse/authorize, no state access. Twilio signature helper included.
  """
  @roles ~w(principal revops vendor client distributor credit)
  @surfaces ~w(app api mcp a2a flight)
  @lead %{
    "principal" => "deal", "revops" => "wo", "vendor" => "off",
    "client" => "po", "distributor" => "bom", "credit" => "pool"
  }
  @otypes ~w(deal wo off po bom pool ent qa stl inv)
  @crockford ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"

  def roles, do: @roles
  def lead_otype(role), do: Map.get(@lead, role)

  @doc "Otypes a role may address: its lead + ent; principal also qa/stl/inv."
  def allowed(role) when role in @roles do
    base = [@lead[role], "ent"]
    if role == "principal", do: base ++ ~w(qa stl inv), else: base
  end

  def allowed(_), do: []

  @spec parse(String.t()) ::
          {:ok, %{role: String.t(), otype: String.t(), id: String.t(), surface: String.t()}}
          | {:refused, atom()}
  def parse(path) when is_binary(path) do
    path = path |> String.split(["?", "#"], parts: 2) |> hd()

    case String.split(path, "/", trim: false) do
      ["", role, typeid, surface] -> check(role, typeid, surface)
      _ -> {:refused, :bad_shape}
    end
  end

  def parse(_), do: {:refused, :bad_shape}

  defp check(role, typeid, surface) do
    cond do
      role not in @roles -> {:refused, :bad_role}
      surface not in @surfaces -> {:refused, :bad_surface}
      true -> check_typeid(role, typeid, surface)
    end
  end

  defp check_typeid(role, typeid, surface) do
    with [otype, ulid] <- String.split(typeid, "_", parts: 2),
         true <- otype in @otypes or {:refused, :bad_otype},
         true <- ulid?(ulid) or {:refused, :bad_typeid} do
      if otype in allowed(role),
        do: {:ok, %{role: role, otype: otype, id: ulid, surface: surface}},
        else: {:refused, :cross_role}
    else
      {:refused, _} = r -> r
      _ -> {:refused, :bad_typeid}
    end
  end

  defp ulid?(<<c, _::binary>> = s) when byte_size(s) == 26 and c in ?0..?7,
    do: s |> String.to_charlist() |> Enum.all?(&(&1 in @crockford))

  defp ulid?(_), do: false

  @doc "base64(HMAC-SHA1(token, url <> sorted params as key<>value))"
  def twilio_signature(token, url, params) do
    data = url <> (params |> Enum.sort() |> Enum.map_join(fn {k, v} -> k <> v end))
    :crypto.mac(:hmac, :sha, token, data) |> Base.encode64()
  end

  def twilio_valid?(token, url, params, sig) when is_binary(sig),
    do: Plug.Crypto.secure_compare(twilio_signature(token, url, params), sig)

  def twilio_valid?(_, _, _, _), do: false

  defmodule Guard do
    @moduledoc "Plug: typed refusal at the edge before any downstream state access."
    import Plug.Conn
    @behaviour Plug
    def init(opts), do: opts

    def call(conn, _opts) do
      case Smalt.Routelaw.parse(conn.request_path) do
        {:ok, route} ->
          assign(conn, :route, route)

        {:refused, reason} ->
          status = if reason == :cross_role, do: 403, else: 400

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(status, Jason.encode!(%{refused: Atom.to_string(reason)}))
          |> halt()
      end
    end
  end
end
