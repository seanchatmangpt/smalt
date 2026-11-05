defmodule Smalt.Aoq.Worker do
  @moduledoc """
  One stateless frame worker (spec §1.1): a plain GenServer-free process
  that pulls frames off its mailbox, parses through the NIF seam
  (behaviour — the real NIF plugs in via LANE-02 without rework), and
  drops the result. Owns nothing; a crash is a supervisor restart.

  Process isolation (C4 hardening):

  - Spawned with `message_queue_data: :off_heap` so a backed-up mailbox
    lives outside the heap the `max_heap_size` budget measures; the
    tradeoff is slightly slower message delivery vs. heap-budget integrity.
  - Spawned with `max_heap_size: %{size: @max_heap_words, kill: true,
    error_logger: true}` — a runaway frame allocation kills the worker
    (supervisor restart) instead of leaking into the VM. Enforcement is
    GC-gated, so the loop carries a 30 s `receive` timeout heartbeat that
    runs `:erlang.garbage_collect/0` then recurses: the zero-alloc idle
    loop would otherwise never GC and the budget would never be checked.
  - No hibernation: the idle loop allocates nothing, so there is no heap
    to reclaim — hibernation would only add copy churn.

  The heartbeat timeout is a maintenance step, not coordination
  (`# SLEEP-CLASS: POLL-STEP` — receive-after GC heartbeat; the runtime
  schedules the process away for the interval, per the no-sleep doctrine).
  """

  @doc false
  def child_spec(index) do
    %{
      id: {__MODULE__, index},
      start: {__MODULE__, :start_link, [index]},
      restart: :permanent,
      type: :worker
    }
  end

  # 2_097_152 words = 16 MiB on 64-bit (8 bytes/word) heap budget per worker.
  @max_heap_words 2_097_152

  @doc false
  def max_heap_words, do: @max_heap_words

  def start_link(index) do
    # C4 + SLA unblock (L20 mid-flight edit disclosed in l20 receipt; fixed
    # forward here per compile-freeze SLA): Elixir has no 4-arity spawn_link,
    # so the isolation opts ride :erlang.spawn_opt/2 (atomic at spawn —
    # preferred over post-spawn process_flag, which leaves a window).
    pid =
      :erlang.spawn_opt(
        fn -> loop(index) end,
        [
          {:message_queue_data, :off_heap},
          {:max_heap_size, %{size: @max_heap_words, kill: true, error_logger: true}}
        ]
      )

    Process.register(pid, registered(index))
    {:ok, pid}
  end

  @doc "Registered name for worker slot `index`."
  def registered(index), do: :"#{__MODULE__}.#{index}"

  @doc "Resolve the worker for round-robin slot `idx mod count` by name."
  def via(idx, count), do: registered(rem(idx, count))

  @doc false
  def loop(index) do
    receive do
      {:aoq_frame, frame} ->
        # The seam: behaviour dispatch, never a direct NIF call from here.
        _parsed = Smalt.Aoq.NifHolder.parse(frame)
        loop(index)

      :stop ->
        :ok
    after
      # SLEEP-CLASS: POLL-STEP — GC heartbeat, not coordination. max_heap_size
      # enforcement is GC-gated and the idle zero-alloc loop never GCs on its
      # own; this 30 s timeout forces a collection then recurses. The runtime
      # owns the interval; the process has genuinely nothing to do until a
      # frame or the heartbeat arrives.
      30_000 ->
        :erlang.garbage_collect()
        loop(index)
    end
  end
end
