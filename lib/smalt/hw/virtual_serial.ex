defmodule Smalt.Hw.VirtualSerial do
  @moduledoc """
  HIL virtual device (GenServer) — payload dispatch per gateway.ts:394-442
  layouts, speaking the gateway.ts wire format on a pty bridge.

  Request/response layouts (payload byte 0 = type):

    * `0x01 SIGN_CHALLENGE [digest:32]` ->
      `0x02 SIGNED_RECEIPT [sig:64][serial utf-8][counter u32 LE]` —
      strictly increasing counter per device instance
    * `0x03 ENROLL` -> `0x04 CAPABILITIES` with firmware "sim-0.1+ed25519"
      (the "+ed25519" suffix drives attest.py's algorithm selection at
      attest.py:76-78)
    * unknown type -> `0x7F ERROR [code:u8][message]`
      (codes: 0 BAD_CRC, 1 BAD_FRAME, 2 UNKNOWN_TYPE, 3 NOT_ENROLLED,
      4 BAD_DIGEST, 5 INTERNAL)

  Attach to a pty slave path with `attach/2`. Raw bytes from the pty are
  re-framed by `Smalt.Hw.Frame` (resync semantics identical to the host-side
  FrameDecoder), dispatched, and the reply frame written back to the pty.
  """

  use GenServer

  alias Smalt.Hw.{Frame, Signer}

  @type_sign_challenge 0x01
  @type_signed_receipt 0x02
  @type_enroll 0x03
  @type_capabilities 0x04
  @type_error 0x7F

  @err_unknown_type 2
  @err_bad_digest 4

  @fw_version "sim-0.1+ed25519"
  @max_payload 4096

  defstruct [:device, :decoder, :counter, :serial, stdio: false]

  # -- public API ------------------------------------------------------------

  @doc "Start the device. Opts: `:device_path` (pty slave path to attach at init)."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Stop the device."
  def stop(pid \\ __MODULE__), do: GenServer.stop(pid)

  @doc "Attach a pty slave path: opens the tty and starts the reader loop."
  def attach(pid \\ __MODULE__, path), do: GenServer.call(pid, {:attach, path})

  @doc """
  Dispatch one raw request payload and return the reply payload binary.
  In-process seam used by tests — the pty path runs the same dispatch.
  """
  def handle_payload(pid \\ __MODULE__, payload) do
    GenServer.call(pid, {:handle_payload, payload})
  end

  @doc "Current monotonic counter value (strictly increasing per sign)."
  def counter(pid \\ __MODULE__), do: GenServer.call(pid, :counter)

  # -- callbacks -------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %__MODULE__{
      device: nil,
      decoder: Frame.decoder(),
      counter: 0,
      serial: Signer.serial()
    }

    cond do
      opts[:stdio] ->
        # pty attached as stdin/stdout (the host spawns the beam with the
        # pty slave as stdio) — BEAM :file on a tty is unreliable on macOS.
        start_stdio_reader(self())
        {:ok, %{state | stdio: true}}

      true ->
        case Keyword.fetch(opts, :device_path) do
          {:ok, path} ->
            case open_pair(path) do
              {:ok, wr} ->
                start_reader(path, self())
                {:ok, %{state | device: wr}}

              {:error, reason} ->
                {:stop, {:pty_open_failed, path, reason}}
            end

          :error ->
            {:ok, state}
        end
    end
  end

  @impl true
  def handle_call({:attach, path}, _from, state) do
    case open_pair(path) do
      {:ok, wr} ->
        start_reader(path, self())
        {:reply, :ok, %{state | device: wr}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:counter, _from, state) do
    {:reply, state.counter, state}
  end

  def handle_call({:handle_payload, payload}, _from, state) do
    {reply, counter} = dispatch(payload, state.serial, state.counter)
    {:reply, reply, %{state | counter: counter}}
  end

  @impl true
  def handle_info({:hw_chunk, bytes}, state) when is_binary(bytes) do
    decoder = Frame.push(state.decoder, bytes)
    {payloads, decoder} = Frame.take(decoder)

    state =
      Enum.reduce(payloads, %{state | decoder: decoder}, fn payload, st ->
        {reply, counter} = dispatch(payload, st.serial, st.counter)
        write_frame(st, reply)
        %{st | counter: counter}
      end)

    {:noreply, state}
  end

  def handle_info({:hw_eof, device}, state) do
    :file.close(device)
    {:noreply, %{state | device: nil}}
  end

  @impl true
  def terminate(_reason, %{device: nil}), do: :ok

  def terminate(_reason, %{device: device}) do
    :file.close(device)
    :ok
  end

  # -- internals -------------------------------------------------------------

  # Two fds to the same tty: :file allows one owner per fd, so the reader
  # task opens (and owns) its own read fd while the GenServer owns the write
  # fd. Both fds speak the same tty line.
  defp open_pair(path) do
    :file.open(path, [:raw, :binary])
  end

  # stdio mode: the reader task pulls single bytes off the pty-backed stdin
  # and streams them to the GenServer; replies go out via stdout.
  defp start_stdio_reader(pid) do
    Task.start(fn ->
      Process.set_label(%{service: :hw, role: :serial_reader, id: :stdio})
      case IO.binread(:stdio, 1) do
        :eof ->
          send(pid, {:hw_eof, nil})

        data ->
          send(pid, {:hw_chunk, data})
          stdio_loop(pid)
      end
    end)
  end

  defp stdio_loop(pid) do
    case IO.binread(:stdio, 1) do
      :eof ->
        send(pid, {:hw_eof, nil})

      data ->
        send(pid, {:hw_chunk, data})
        stdio_loop(pid)
    end
  end

  # The reader opens its own fd (owner = itself, required by :file) and
  # streams raw chunks to the GenServer; the reply path writes via the
  # GenServer-owned write fd.
  defp start_reader(path, pid) do
    Task.start(fn ->
      Process.set_label(%{service: :hw, role: :serial_reader, id: path})
      case :file.open(path, [:raw, :binary]) do
        {:ok, rd} -> reader_loop(rd, pid)
        {:error, reason} -> send(pid, {:hw_eof, {:error, reason}})
      end
    end)
  end

  defp reader_loop(device, pid) do
    case :file.read(device, 512) do
      {:ok, bytes} ->
        send(pid, {:hw_chunk, bytes})
        reader_loop(device, pid)

      :eof ->
        send(pid, {:hw_eof, device})

      {:error, _reason} ->
        send(pid, {:hw_eof, device})
    end
  end

  defp write_frame(%__MODULE__{stdio: true}, reply) do
    IO.binwrite(:stdio, Frame.encode(reply))
  end

  defp write_frame(%__MODULE__{device: nil}, _reply), do: :ok

  defp write_frame(%__MODULE__{device: device}, reply) do
    reply |> Frame.encode() |> :file.write(device)
  end

  defp write_frame(device, reply) do
    reply |> Frame.encode() |> :file.write(device)
  end

  # -- payload dispatch ------------------------------------------------------

  defp dispatch(<<@type_enroll>>, _serial, counter) do
    fw = @fw_version

    body =
      <<@type_capabilities, 1::8, 1::8, byte_size(fw)::8, fw::binary,
        @max_payload::little-integer-size(16)>>

    {body, counter}
  end

  defp dispatch(<<@type_sign_challenge, digest::binary-size(32)>>, serial, counter) do
    counter = counter + 1
    sig = Signer.sign(digest)

    body =
      <<@type_signed_receipt, sig::binary-size(64), serial::binary,
        counter::little-integer-size(32)>>

    {body, counter}
  end

  defp dispatch(<<@type_sign_challenge, _::binary>>, _serial, counter) do
    {<<@type_error, @err_bad_digest>> <> "digest must be 32 bytes", counter}
  end

  defp dispatch(<<other, _rest::binary>>, _serial, counter) do
    msg = "unknown message type 0x" <> String.downcase(Integer.to_string(other, 16))
    {<<@type_error, @err_unknown_type>> <> msg, counter}
  end
end
