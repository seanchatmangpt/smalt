defmodule :cgap_beam do
  @moduledoc """
  The AoQ QUIC NIF loader module (v26.11.6 LANE-4) - smalt's first NIF.

  MODULE-NAME LAW (witnessed, court flip 2026-11-04): the cgap dylib's
  `ErlNifEntry.name` is `cgap_beam`, and OTP refuses to bind a NIF into
  a module whose name differs from the entry name
  (`bad_lib: Library module name 'cgap_beam' does not match calling
  module ...`). So the loader module is literally `:cgap_beam`; the
  Elixir-facing facade is `Smalt.Aoq.Quic.Nif` (delegating below).

  Stage the dylib with `scripts/build_aoq_nif.sh` - it is a build
  artifact, never committed (gitignored `priv/aoq/aq_beam_nif*`).

  LOADER LAW (loud-skip, never boot-raise): if `:erlang.load_nif/2`
  fails, the loader logs a NAMED refusal and installs loud-skip stubs
  that answer the error atom - the VM never crashes on boot. A stub
  answer is indistinguishable from a real refusal by return shape
  alone; `loaded?/0` / `load_status/0` are the honest witnesses.

  NIF surface (client role, cgap aq_quic.rs; ALL errors are the bare
  `:error` atom):
    aq_quic_open(Port, CaCertDer)      -> engine resource term | :error
    aq_quic_connect(Engine, Addr, SNI) -> conn resource term    | :error
    aq_quic_send(Conn, Binary)         -> :ok                   | :error
    aq_quic_recv(Conn, TimeoutMs)      -> binary (resource bin) | :error
  """

  require Logger

  @on_load :load_nif

  @doc """
  Loads the dylib. Returns `:ok` in BOTH outcomes (the @on_load contract
  must not fail the module load): real load `:ok`, or stub install with a
  named log. `loaded?/0` tells the two apart.
  """
  @spec load_nif() :: :ok
  def load_nif do
    case :erlang.load_nif(path(), 0) do
      :ok ->
        :persistent_term.put({__MODULE__, :load_status}, {:loaded, path()})
        :ok

      {:error, reason} ->
        # Loud-skip law: named refusal log, never a raise.
        Logger.error(
          "Smalt.Aoq.Quic.Nif: dylib not loaded - " <>
            "path=#{path()} reason=#{inspect(reason)} " <>
            "stub answers are active (stage with scripts/build_aoq_nif.sh)"
        )

        :persistent_term.put({__MODULE__, :load_status}, {:stub, reason})
        :ok
    end
  end

  @doc "True only when the real dylib answered load_nif."
  @spec loaded?() :: boolean
  def loaded? do
    match?({:loaded, _}, load_status())
  end

  @doc "Load receipt: `{:loaded, path}` or `{:stub, reason}`."
  @spec load_status() :: {:loaded, charlist} | {:stub, term}
  def load_status do
    :persistent_term.get({__MODULE__, :load_status}, {:stub, :load_nif_not_yet_run})
  end

  defp path do
    Application.app_dir(:smalt, "priv/aoq/aq_beam_nif") |> String.to_charlist()
  end

  # ------------------------------------------------------------------
  # Surface (stub bodies below; replaced by the dylib's exports at
  # load time). OTP requires stub declarations for ALL entries declared
  # in the dylib's ErlNifEntry (all 38 funcs), otherwise load_nif
  # refuses with {:bad_lib, ~c"Function not found ..."}.
  # ------------------------------------------------------------------

  def cgap_new(_n, _fill), do: :erlang.nif_error(:nif_not_loaded)
  def cgap_new_fast(_n, _fill), do: :erlang.nif_error(:nif_not_loaded)
  def cgap_len(_id), do: :erlang.nif_error(:nif_not_loaded)
  def cgap_get(_id, _idx), do: :erlang.nif_error(:nif_not_loaded)
  def cgap_free(_id), do: :erlang.nif_error(:nif_not_loaded)
  def cgap_version(), do: :erlang.nif_error(:nif_not_loaded)
  def cgap_new_i64(_n, _fill), do: :erlang.nif_error(:nif_not_loaded)
  def cgap_get_i64(_id, _idx), do: :erlang.nif_error(:nif_not_loaded)
  def cgap_stats(_id), do: :erlang.nif_error(:nif_not_loaded)
  def cgap_envelope_new(_id), do: :erlang.nif_error(:nif_not_loaded)
  def cgap_envelope_len(_handle), do: :erlang.nif_error(:nif_not_loaded)
  def cgap_batch_binary(_id), do: :erlang.nif_error(:nif_not_loaded)
  def pointer_of(_id), do: :erlang.nif_error(:nif_not_loaded)
  def cgap_binary_data_pointer(_bin), do: :erlang.nif_error(:nif_not_loaded)
  def cgap_dtor_stats(), do: :erlang.nif_error(:nif_not_loaded)
  def cgap_alloc_stats(), do: :erlang.nif_error(:nif_not_loaded)
  def cgap_flush_to_parquet(_id), do: :erlang.nif_error(:nif_not_loaded)
  def cgap_seal_to_packfile(_id), do: :erlang.nif_error(:nif_not_loaded)
  def cgap_receipt_query(_id), do: :erlang.nif_error(:nif_not_loaded)
  def cgap_open(_path), do: :erlang.nif_error(:nif_not_loaded)
  def cgap_scan(_id, _col, _val), do: :erlang.nif_error(:nif_not_loaded)
  def aq_slab_open(_path), do: :erlang.nif_error(:nif_not_loaded)
  def aq_slab_frame(_slab, _idx), do: :erlang.nif_error(:nif_not_loaded)
  def aq_slab_window(_slab, _idx, _off, _len), do: :erlang.nif_error(:nif_not_loaded)
  def aq_slab_stamp(_slab, _idx), do: :erlang.nif_error(:nif_not_loaded)
  def aq_slab_lease(_slab, _mask), do: :erlang.nif_error(:nif_not_loaded)
  def aq_slab_sync(_slab), do: :erlang.nif_error(:nif_not_loaded)

  def aq_quic_open(_port, _ca_der) do
    stub_refusal(:aq_quic_open, 2)
    stub_error()
  end

  def aq_quic_connect(_engine, _addr, _server_name) do
    stub_refusal(:aq_quic_connect, 3)
    stub_error()
  end

  def aq_quic_send(_conn, _data) do
    stub_refusal(:aq_quic_send, 2)
    stub_error()
  end

  def aq_quic_recv(_conn, _timeout_ms) do
    stub_refusal(:aq_quic_recv, 2)
    stub_error()
  end

  def aq_quic_serve(_engine, _port, _cert_der, _key_der), do: :erlang.nif_error(:nif_not_loaded)
  def aq_quic_accept(_listener, _timeout_ms), do: :erlang.nif_error(:nif_not_loaded)
  def aq_quic_accept_bi(_conn, _timeout_ms), do: :erlang.nif_error(:nif_not_loaded)
  def aq_quic_stream_open(_conn), do: :erlang.nif_error(:nif_not_loaded)
  def aq_quic_stream_send(_stream, _data), do: :erlang.nif_error(:nif_not_loaded)
  def aq_quic_stream_recv(_stream, _timeout_ms), do: :erlang.nif_error(:nif_not_loaded)
  def aq_quic_stream_close(_stream), do: :erlang.nif_error(:nif_not_loaded)

  # dynamic(): the stub must type as term so the wrapper's success
  # clauses (real-dylib returns) are not flagged unreachable.
  defp stub_error, do: :erlang.binary_to_existing_atom("error", :utf8)

  defp stub_refusal(name, arity) do
    Logger.warning(
      "Smalt.Aoq.Quic.Nif: #{name}/#{arity} answered by LOUD-SKIP stub " <>
        "(dylib not loaded) - status=#{inspect(load_status())}"
    )
  end
end

defmodule Smalt.Aoq.Quic.Nif do
  @moduledoc """
  Elixir-facing facade over the `:cgap_beam` NIF loader module
  (v26.11.6 LANE-4). The loader itself lives in the `:cgap_beam` module
  above - OTP's NIF module-name law (see its moduledoc) requires the
  calling module name to equal the dylib's `ErlNifEntry.name`.
  """

  @doc "Load receipt: `{:loaded, path}` or `{:stub, reason}`."
  defdelegate load_status, to: :cgap_beam

  @doc "True only when the real dylib answered load_nif."
  defdelegate loaded?, to: :cgap_beam

  defdelegate aq_quic_open(port, ca_der), to: :cgap_beam
  defdelegate aq_quic_connect(engine, addr, server_name), to: :cgap_beam
  defdelegate aq_quic_send(conn, data), to: :cgap_beam
  defdelegate aq_quic_recv(conn, timeout_ms), to: :cgap_beam
  defdelegate aq_quic_serve(engine, port, cert_der, key_der), to: :cgap_beam
  defdelegate aq_quic_accept(listener, timeout_ms), to: :cgap_beam
  defdelegate aq_quic_accept_bi(conn, timeout_ms), to: :cgap_beam
  defdelegate aq_quic_stream_open(conn), to: :cgap_beam
  defdelegate aq_quic_stream_send(stream, data), to: :cgap_beam
  defdelegate aq_quic_stream_recv(stream, timeout_ms), to: :cgap_beam
  defdelegate aq_quic_stream_close(stream), to: :cgap_beam
end
