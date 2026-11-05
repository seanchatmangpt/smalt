defmodule Smalt.Egress.SignIns do
  # Minimal unblock fix (compile-freeze SLA, merge lane): @cap is interpolated
  # in the @moduledoc below, so the attribute must be defined before it.
  @cap 256

  @moduledoc """
  Sign-in logs surface (AF-L14-GAP-1 closure) — an in-memory ring of STS mint
  events assembled at the mint site (`Smalt.ArmGateway.Router.issue_token/2`).

  Each client-credentials mint is recorded with the client identity (appid),
  tenant, timestamp, and the connection's remote IP; `GET
  /v1.0/auditLogs/signIns` (mounted in `Smalt.Egress.GraphRoutes`) renders the
  ring in the Microsoft Graph documented envelope:

      { "@odata.context", value: [{ id, createdDateTime, userPrincipalName,
        appDisplayName, ipAddress, status: { errorCode } }] }

  Newest first (Graph sign-in logs default order). `$filter` subset: the
  `createdDateTime` ge/le conjunctive form; any other property is a documented
  Graph 400 BadRequest.

  The ring is a lazy public named :ets table (cap #{@cap}, newest first)
  keyed by a wrapping slot with a monotone :atomics sequence — global,
  process-tree free, and O(1) per mint with no persistent_term write on
  the hot path: the identity plane mints and the egress plane serves the
  log on the same VM.
  """

  @ring_key :smalt_signins_ring
  @seq_key {:smalt_signins_ring, :seq}

  # Minimal unblock fix (compile-freeze SLA disclosure, G1 what-if lane):
  # band/bor below are Bitwise macros; without this import the module fails
  # to compile at all.
  import Bitwise

  @typedoc "One recorded STS mint event (newest-first ring member)."
  @type mint_event :: %{
          required(:id) => String.t(),
          required(:created_at) => DateTime.t(),
          required(:appid) => String.t(),
          required(:tenant_id) => String.t(),
          required(:ip) => String.t(),
          required(:status_error_code) => non_neg_integer()
        }

  @doc """
  Hook the STS mint site: record one successful token mint. `conn` supplies
  the remote IP; failure of the recording is never allowed to fail the mint.
  """
  @spec record_mint(String.t(), String.t(), Plug.Conn.t()) :: :ok
  def record_mint(tenant_id, appid, conn) do
    event = %{
      id: uuid4(),
      created_at: DateTime.utc_now(),
      appid: appid,
      tenant_id: tenant_id,
      ip: ip_string(conn.remote_ip),
      status_error_code: 0
    }

    ensure_ring()
    seq = :atomics.add_get(seq_ref(), 1, 1)
    # Fixed 256-slot set: seq-snapshot at read time reconstructs the
    # newest-first ring; a mint into an occupied slot evicts the oldest.
    :ets.insert(@ring_key, {rem(seq, @cap), seq, event})
    :ok
  rescue
    _ -> :ok
  end

  @doc "Recorded mint events, newest first."
  @spec events() :: [mint_event(), ...]
  def events do
    ensure_ring()

    @ring_key
    |> :ets.tab2list()
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(@cap)
    |> Enum.map(&elem(&1, 2))
  rescue
    _ -> []
  end

  @doc "Clear the ring (courts use this to pin an exact row count)."
  @spec clear() :: :ok
  def clear do
    ensure_ring()
    :ets.delete_all_objects(@ring_key)
    :ok
  rescue
    _ -> :ok
  end

  # Lazy init — no application.ex edit (C9 lane law). A lost init race is
  # benign: the winner's named table is the ring either way.
  defp ensure_ring do
    if :ets.whereis(@ring_key) == :undefined do
      try do
        :ets.new(@ring_key, [:named_table, :public, :set, read_concurrency: true])
        :persistent_term.put(@seq_key, :atomics.new(1, signed: false))
      rescue
        # Lost the :ets.new race — the winner's table is the ring.
        _ -> :ok
      end
    end
  end

  defp seq_ref do
    case :persistent_term.get(@seq_key, :undefined) do
      :undefined ->
        ref = :atomics.new(1, signed: false)
        :persistent_term.put(@seq_key, ref)
        ref

      ref ->
        ref
    end
  end

  @doc """
  Render one event into the documented Graph signIn row shape.
  `userPrincipalName` is `null` — the emulator STS mints client-credentials
  tokens only (no user principal exists to render; Graph renders null there).
  """
  @spec to_row(mint_event()) :: map()
  def to_row(event) do
    %{
      "id" => event.id,
      "createdDateTime" => DateTime.to_iso8601(event.created_at),
      "userPrincipalName" => nil,
      "appDisplayName" => "workspace-console",
      "ipAddress" => event.ip,
      "status" => %{"errorCode" => event.status_error_code}
    }
  end

  defp ip_string({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp ip_string(tup) do
    tup
    |> :inet.ntoa()
    |> case do
      {:ok, s} -> to_string(s)
      _ -> "0.0.0.0"
    end
  end

  defp uuid4 do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    # RFC 4122 v4 version/variant bits.
    c4 = bor(band(c, 0x0FFF), 0x4000)
    d5 = bor(band(d, 0x3FFF), 0x8000)

    hex(a, 8) <> "-" <> hex(b, 4) <> "-" <> hex(c4, 4) <> "-" <> hex(d5, 4) <> "-" <> hex(e, 12)
  end

  defp hex(v, pad), do: v |> Integer.to_string(16) |> String.pad_leading(pad, "0")
end
