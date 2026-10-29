defmodule Smalt.Amqp10.Session do
  @moduledoc """
  Per-channel session actor of the crash-only AMQP 10 family. Spawned lazily
  (linked, non-trapping) by the connection on the first frame for an unmapped
  channel; answers `begin`, spawns a `Smalt.Amqp10.Link` per ATTACH with
  immediate flow credit, and routes transfers/dispositions/detaches to links.
  """

  @spec start_link(keyword()) :: pid()
  def start_link(opts) do
    parent = self()

    pid =
      spawn_link(fn ->
        :proc_lib.set_label({__MODULE__, Keyword.fetch!(opts, :channel)})
        send(parent, {:amqp10_session_ready, self()})
        loop(opts, %{})
      end)

    pid
  end

  defp loop(opts, links) do
    receive do
      {:amqp10_frame, {:begin, _fields}, _payload} ->
        send(opts[:conn], {:amqp10_tx, opts[:channel],
                           {:begin, %{remote_channel: opts[:channel],
                                      next_outgoing_id: 1, incoming_window: 1000,
                                      outgoing_window: 1000}}})

        loop(opts, links)

      {:amqp10_frame, {:attach, fields}, _payload} ->
        name = fields[:name] || "link"
        handle = fields[:handle] || 0

        link =
          Smalt.Amqp10.Link.start_link(
            name: name,
            handle: handle,
            channel: opts[:channel],
            conn: opts[:conn],
            table: opts[:table]
          )

        receive do
          {:amqp10_link_ready, _pid} -> :ok
        after
          5_000 -> :ok
        end

        # Immediate flow credit: the peer attached as sender (role false);
        # grant credit on its handle right away.
        send(opts[:conn], {:amqp10_tx, opts[:channel],
                           {:attach, %{name: name, handle: handle, role: true}}})

        send(link, {:amqp10_grant_credit, opts[:channel], handle})

        loop(opts, Map.put(links, handle, link))

      {:amqp10_frame, {:transfer, fields}, payload} ->
        handle = fields[:handle] || 0

        case Map.fetch(links, handle) do
          {:ok, link} ->
            send(link, {:amqp10_frame, {:transfer, fields}, payload})

          :error ->
            # Transfer on an unknown handle is a session-level protocol
            # error; the crash-only answer is to die and cascade.
            exit({:unknown_link_handle, handle})
        end

        loop(opts, links)

      {:amqp10_frame, {:disposition, fields}, _payload} ->
        Enum.each(links, fn {_h, link} -> send(link, {:amqp10_frame, {:disposition, fields}, <<>>}) end)
        loop(opts, links)

      {:amqp10_frame, {:flow, fields}, _payload} ->
        handle = fields[:handle]

        case handle do
          nil -> :ok
          h -> case Map.fetch(links, h) do
                 {:ok, link} -> send(link, {:amqp10_flow, fields})
                 :error -> :ok
               end
        end

        loop(opts, links)

      {:amqp10_frame, {:detach, fields}, _payload} ->
        handle = fields[:handle] || 0

        case Map.pop(links, handle) do
          {nil, _} ->
            exit({:unknown_link_handle, handle})

          {link, links2} ->
            send(link, {:amqp10_frame, {:detach, fields}, <<>>})
            loop(opts, links2)
        end

      {:amqp10_frame, {:end, _fields}, _payload} ->
        # Session end tears down all links and the session itself.
        Enum.each(links, fn {_h, link} -> send(link, {:amqp10_frame, {:detach, %{}}, <<>>}) end)

      {:amqp10_frame, _other, _payload} ->
        loop(opts, links)
    end
  end
end
