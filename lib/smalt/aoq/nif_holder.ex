defmodule Smalt.Aoq.Nif do
  @moduledoc """
  The NIF seam (aq-nif-boundary-spec.md, LANE-02). AoQ code NEVER calls a
  NIF directly — it calls this behaviour through `Smalt.Aoq.NifHolder`.
  The real load-bearing NIF module implements these callbacks and is
  configured as `config :smalt, :aoq, nif: MyNifModule`; until it lands,
  `Smalt.Aoq.Nif.Stub` serves.
  """

  @callback parse(frame :: binary) :: {:ok, term} | {:error, term}
  @callback encode(term) :: {:ok, iolist} | {:error, term}

  # PQC capability face (v26.11.6 lane 13): a PQC-capable NIF declares
  # itself; the default posture is incapable.
  @callback pqc_capable?() :: boolean
end

defmodule Smalt.Aoq.Nif.Stub do
  @moduledoc """
  Pure-Elixir placeholder implementation of `Smalt.Aoq.Nif`. Performs no
  NIF call: parse validates the >64B framing law structurally (§2) and
  echoes the payload; encode emits the iolist egress shape `[h | p]` (§3).
  """

  @behaviour Smalt.Aoq.Nif

  @impl true
  def pqc_capable?, do: false

  @header_size 64

  @impl true
  def parse(frame) when is_binary(frame) do
    if byte_size(frame) >= @header_size + 1 do
      <<header::binary-size(@header_size), payload::binary>> = frame
      {:ok, %{header: header, payload: payload}}
    else
      {:error, {:aoq_frame_too_short, byte_size(frame)}}
    end
  end

  @impl true
  def encode(%{header: <<_::binary-size(@header_size)>> = header, payload: payload}) do
    # §3 egress law: iolist [Header | Payload], never a `<>` concatenation.
    {:ok, [header, payload]}
  end

  def encode(other), do: {:error, {:bad_frame, other}}
end

defmodule Smalt.Aoq.NifHolder do
  @moduledoc """
  Holds NIF resource lifetimes for its family (spec §1.1). In the skeleton
  it owns the configured `Smalt.Aoq.Nif` implementation module: boot puts
  it in :persistent_term so the hot path (`parse/1`) is a lock-free read —
  the GenServer is never called on the frame path, and a future real NIF's
  resource refs slot into this same state without rework.
  """

  use GenServer

  @impl_key {__MODULE__, :impl}

  def start_link(cfg) do
    GenServer.start_link(__MODULE__, cfg, name: __MODULE__)
  end

  @doc "Hot-path parse — persistent_term read, no GenServer call."
  @spec parse(binary) :: {:ok, term} | {:error, term}
  def parse(frame) when is_binary(frame) do
    impl().parse(frame)
  end

  @doc "Configured NIF implementation (default: the stub)."
  @spec impl() :: module
  def impl do
    :persistent_term.get(@impl_key, default_impl())
  end

  @doc """
  PQC posture gate (v26.11.6 lane 13). Reads `config :smalt, :aoq, pqc:`
  (default `false`). Returns `:ok` when pqc is off (classical framing is
  the lawful posture) or when the configured NIF declares
  `pqc_capable?/0` true. When pqc is ON and the NIF is incapable, this
  returns a TYPED refusal — never a quiet classical fallback.
  """
  @spec pqc_gate() :: :ok | {:error, {:pqc_nif_incapable, module}}
  def pqc_gate do
    pqc? = :smalt |> Application.get_env(:aoq, []) |> Keyword.get(:pqc, false)

    if pqc? and not impl().pqc_capable?() do
      {:error, {:pqc_nif_incapable, impl()}}
    else
      :ok
    end
  end

  @impl true
  def init(cfg) do
    impl = Keyword.get(cfg, :nif, default_impl())
    :persistent_term.put(@impl_key, impl)
    {:ok, %{impl: impl, refs: []}}
  end

  defp default_impl, do: Smalt.Aoq.Nif.Stub
end
