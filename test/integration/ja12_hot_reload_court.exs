# JA-12 hot-code-reload court (Joe Armstrong doctrine).
# Repo root: this checkout. Real running gen_server + raw receive-loop processes,
# real code:load_binary lifecycle, no mocks, no doubles.
#
# Phases:
#   P1  compile v1, code:load_binary, start gen_server, add(1) x5 -> read == 5
#   P2  compile v2 (add doubles), load; behavior flips WITHOUT restart:
#       pid unchanged, state preserved (5 still in state, continues from there)
#   P5  mechanism proof: fully-qualified tail call (?MODULE:loop) twin picks up
#       v2; local-call twin stays pinned to v1 (negative control)
#   P6  code:purge + code:delete of old code; gen_server survives on v2
#
# Run (OTP 29 toolchain):
#   cd <repo-root> && MIX_BUILD_ROOT=_build-ja12 \
#   PATH=/opt/homebrew/opt/erlang@29/bin:$PATH \
#   elixir test/integration/ja12_hot_reload_court.exs

defmodule JA12 do
  @moduledoc false

  # gen_server counter, v1: add(N) adds N. State init 0.
  @gs_v1 ~c'''
  -module(ja12_gs).
  -behaviour(gen_server).
  -export([start_link/0, add/1, read/0, init/1, handle_call/3,
           handle_cast/2, handle_info/2, terminate/2, code_change/3]).

  start_link() -> gen_server:start({local, ?MODULE} , ?MODULE, 0, []).
  add(N) -> gen_server:call(?MODULE, {add, N}).
  read() -> gen_server:call(?MODULE, read).

  init(S) -> {ok, S}.
  handle_call({add, N}, _From, S) -> {reply, ok, S + N};
  handle_call(read, _From, S)     -> {reply, S, S}.
  handle_cast(_M, S) -> {noreply, S}.
  handle_info(_M, S) -> {noreply, S}.
  terminate(_R, _S) -> ok.
  code_change(_V, S, _E) -> {ok, S}.
  '''

  # gen_server counter, v2: add(N) DOUBLES N.
  @gs_v2 ~c'''
  -module(ja12_gs).
  -behaviour(gen_server).
  -export([start_link/0, add/1, read/0, init/1, handle_call/3,
           handle_cast/2, handle_info/2, terminate/2, code_change/3]).

  start_link() -> gen_server:start({local, ?MODULE}, ?MODULE, 0, []).
  add(N) -> gen_server:call(?MODULE, {add, N}).
  read() -> gen_server:call(?MODULE, read).

  init(S) -> {ok, S}.
  handle_call({add, N}, _From, S) -> {reply, ok, S + 2 * N};
  handle_call(read, _From, S)     -> {reply, S, S}.
  handle_cast(_M, S) -> {noreply, S}.
  handle_info(_M, S) -> {noreply, S}.
  terminate(_R, _S) -> ok.
  code_change(_V, S, _E) -> {ok, S}.
  '''

  # Fully-qualified tail-call loop twin, v1. Replies {Vsn, State}.
  @fq_v1 ~c'''
  -module(ja12_fq).
  -export([start/0, add/1, loop/2]).

  start()  -> spawn(?MODULE, loop, [?MODULE, 0]).
  add(Pid) -> Pid ! {self(), {add, 1}}, receive {Pid, R} -> R after 5000 -> exit(timeout) end.

  loop(M, S) -> receive {From, {add, N}} ->
                   R = {1, S + N},          %% version literal 1
                   From ! {self(), R},
                   M:loop(M, S + N)         %% JA12-MECH: dynamic module call (current code)
             end.
  '''

  # Fully-qualified loop twin, v2 (doubles).
  @fq_v2 ~c'''
  -module(ja12_fq).
  -export([start/0, add/1, loop/2]).

  start()  -> spawn(?MODULE, loop, [?MODULE, 0]).
  add(Pid) -> Pid ! {self(), {add, 1}}, receive {Pid, R} -> R after 5000 -> exit(timeout) end.

  loop(M, S) -> receive {From, {add, N}} ->
                   R = {2, S + 2 * N},      %% version literal 2, doubled
                   From ! {self(), R},
                   M:loop(M, S + 2 * N)
             end.
  '''

  # LOCAL-call twin (negative control): identical except the tail call is
  # `loop(...)` instead of `?MODULE:loop(...)`.
  @local_v1 ~c'''
  -module(ja12_local).
  -export([start/0, add/1, loop/1]).

  start()  -> spawn(?MODULE, loop, [0]).
  add(Pid) -> Pid ! {self(), {add, 1}}, receive {Pid, R} -> R after 5000 -> exit(timeout) end.

  loop(S) -> receive {From, {add, N}} ->
                   R = {1, S + N},
                   From ! {self(), R},
                   loop(S + N)              %% JA12-NEG: local call pins old code
             end.
  '''

  @local_v2 ~c'''
  -module(ja12_local).
  -export([start/0, add/1, loop/1]).

  start()  -> spawn(?MODULE, loop, [0]).
  add(Pid) -> Pid ! {self(), {add, 1}}, receive {Pid, R} -> R after 5000 -> exit(timeout) end.

  loop(S) -> receive {From, {add, N}} ->
                   R = {2, S + 2 * N},
                   From ! {self(), R},
                   loop(S + 2 * N)
             end.
  '''

  def gs_v1, do: @gs_v1
  def gs_v2, do: @gs_v2
  def fq_v1, do: @fq_v1
  def fq_v2, do: @fq_v2
  def local_v1, do: @local_v1
  def local_v2, do: @local_v2
end

defmodule JA12Court do
  @moduledoc false

  def compile!(src) do
    # OTP 29 removed compile:string/1 — file-based compile to in-memory beam.
    path = Path.join(System.tmp_dir!(), "ja12-" <> Integer.to_string(System.unique_integer([:positive])) <> ".erl")
    File.write!(path, src)
    try do
      case :compile.file(String.to_charlist(path), [:binary, :return]) do
        {:ok, mod, beam, _warns} -> {mod, beam}
        other -> exit({:compile_failed, path, other})
      end
    after
      File.rm(path)
    end
  end

  def load!(mod, beam, tag) do
    case :code.load_binary(mod, ~c"ja12/memory/" ++ String.to_charlist(tag), beam) do
      {:module, ^mod} -> :ok
      other -> exit({:load_failed, mod, tag, other})
    end
  end

  def add_and_read(n) do
    Enum.each(1..n, fn _ -> (:ok = :gen_server.call(:ja12_gs, {:add, 1})) end)
    :gen_server.call(:ja12_gs, :read)
  end

  def run do
    IO.puts("== JA-12 hot-reload court ==")
    IO.puts("otp_release=#{:erlang.system_info(:otp_release)} erts=#{:erlang.system_info(:version)}")
    failures = []

    ### P1: load v1, exercise, read == 5 ####################################
    {m, beam_v1} = compile!(JA12.gs_v1())
    :ok = load!(m, beam_v1, "v1")
    {:ok, pid} = :gen_server.start({:local, m}, m, 0, [])
    IO.puts("[P1] v1 loaded via code:load_binary; gen_server pid=#{inspect(pid)}")

    5 = add_and_read(5)
    IO.puts("[P1] add(1) x5 -> read == 5  PASS")
    IO.puts("")

    ### P2: load v2, behavior flips, pid unchanged, state preserved ########
    {^m, beam_v2} = compile!(JA12.gs_v2())
    :ok = load!(m, beam_v2, "v2")
    {:file, _file} = :code.is_loaded(m)

    (:ok = :gen_server.call(m, {:add, 1}))
    7 = :gen_server.call(m, :read)   # 5 + 2*1 = 7 : v2 behavior, state 5 preserved
    pid_after = Process.whereis(m)
    ^pid = pid_after
    IO.puts("[P2] v2 loaded; add(1) -> read == 7 (doubled, state 5 preserved)")
    IO.puts("[P2] pid unchanged: #{inspect(pid)} == #{inspect(pid_after)}  PASS")
    IO.puts("")

    ### P5: mechanism — fully-qualified vs local tail call ##################
    {fqm, fq_v1_beam} = compile!(JA12.fq_v1())
    :ok = load!(fqm, fq_v1_beam, "v1")
    fq_pid = :ja12_fq.start()
    {1, 1} = :ja12_fq.add(fq_pid)
    {1, 2} = :ja12_fq.add(fq_pid)

    {lm, local_v1_beam} = compile!(JA12.local_v1())
    :ok = load!(lm, local_v1_beam, "v1")
    local_pid = :ja12_local.start()
    {1, 1} = :ja12_local.add(local_pid)
    {1, 2} = :ja12_local.add(local_pid)
    IO.puts("[P5] both twins on v1: fq replies {1,S}, local replies {1,S}")

    # Load v2 for BOTH modules.
    {^fqm, fq_v2_beam} = compile!(JA12.fq_v2())
    :ok = load!(fqm, fq_v2_beam, "v2")
    {^lm, local_v2_beam} = compile!(JA12.local_v2())
    :ok = load!(lm, local_v2_beam, "v2")

    # Armstrong semantics: the process is parked in an old-code receive; it
    # handles exactly one more message on v1, then the dynamic M:loop tail
    # call re-enters CURRENT code — v2 from then on, state preserved.
    {1, 3} = :ja12_fq.add(fq_pid)
    IO.puts("[P5] fq twin 1st call after v2 load: {1,3} — parked old-code frame (expected)")
    {2, 5} = :ja12_fq.add(fq_pid)
    IO.puts("[P5] fq twin 2nd call: {2,5} — now executing v2 (doubled), state 3 preserved  PASS")
    {2, 7} = :ja12_fq.add(fq_pid)
    IO.puts("[P5] fq twin 3rd call: {2,7} — steady on v2  PASS")

    {1, 3} = :ja12_local.add(local_pid) # local twin: STILL v1 {1, S+1}
    IO.puts("[P5] local twin after v2 load: {1,3} — PINNED to v1 (negative control)  PASS")

    {1, 4} = :ja12_local.add(local_pid)
    IO.puts("[P5] local twin still v1 after repeated calls  PASS")
    IO.puts("")

    ### P6: purge old code, process survives on v2 ##########################
    fq_purge = :code.purge(fqm)  # true => a process was still on old fq code and was killed
    IO.puts("[P6] fq purge returned #{inspect(fq_purge)} (true = killed a stale old-code holder)")
    _ = :code.delete(fqm)

    :erlang.garbage_collect(pid)
    false = :erlang.check_process_code(pid, m)
    IO.puts("[P6] check_process_code(gen_server, old ja12_gs) = false — gen_server holds no old code")
    purge_res = :code.purge(m)
    IO.puts("[P6] purge(ja12_gs) = #{inspect(purge_res)} (false = no process had to be killed; nothing pinned)")
    _ = :code.delete(m)
    IO.puts("[P6] is_loaded(ja12_gs) after purge+delete = #{inspect(:code.is_loaded(m))} — code server dropped it (in-memory code lives until last reference dies)")
    # Re-establish the module entry (same v2 beam) — the process never restarted.
    {:module, ^m} = :code.load_binary(m, ~c"ja12/memory/v2-reload", beam_v2)
    IO.puts("[P6] v2 beam re-registered via code:load_binary")

    (:ok = :gen_server.call(m, {:add, 1}))
    9 = :gen_server.call(m, :read)   # 7 + 2 = 9
    ^pid = Process.whereis(m)
    alive = Process.alive?(pid)
    true = alive
    IO.puts("[P6] purge+delete old code: gen_server alive=#{alive}, pid unchanged, read == 9 (v2 math)  PASS")

    # negative-control twin cleanup: local twin still runs old code; purge MUST
    # kill it (that is the documented semantics) — prove the pin was real.
    true = :code.purge(lm)   # returns true: a process was killed, i.e. was on old code
    _ = :code.delete(lm)
    false = Process.alive?(local_pid)
    IO.puts("[P6] local twin killed by purge (was on old code) — negative control non-vacuous  PASS")

    fq_alive = Process.alive?(fq_pid)
    IO.puts("[P6] fq twin alive after purge: #{inspect(fq_alive)} (informational)")

    failures =
      case failures do
        [] -> IO.puts("== JA-12 COURT: PASS (all phases) "); []
        other -> other
      end

    failures
  end
end

case JA12Court.run() do
  [] -> :ok
  other -> exit({:ja12_court_failures, other})
end
