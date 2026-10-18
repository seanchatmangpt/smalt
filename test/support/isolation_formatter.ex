defmodule SmaltTest.IsolationFormatter do
  @moduledoc """
  AZB-11 runtime isolation twin. An ExUnit formatter that snapshots
  `Process.registered()/0` and `Application.get_all_env(:smalt)` at
  case_started and diffs both at case_finished; any delta after a module
  finishes is reported as `ISOLATION-TWIN LEAK module=<name> ...` on stdout
  (the isolation court greps these and fails the run with the module name).

  Run serially (`--max-cases 1`) so concurrent async modules cannot leak
  into each other's diffs. Display-only deltas (ExUnit dots) are not
  reproduced; failure counts and the exit code still come from ExUnit.
  """

  use GenServer
  @behaviour ExUnit.Formatter

  defp snapshot do
    names = Process.registered() |> Enum.sort()
    env = Application.get_all_env(:smalt) |> Enum.sort()
    {names, env}
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       stdout: opts[:stdout] || Process.group_leader(),
       baselines: %{},
       leaks: [],
       tests: 0,
       failures: 0
     }}
  end

  @impl true
  def handle_event({:case_started, %ExUnit.TestCase{name: name}}, state) do
    {names, env} = snapshot()
    {:ok, put_in(state.baselines[name], {names, env})}
  end

  def handle_event({:case_finished, %ExUnit.TestCase{name: name}}, state) do
    case Map.pop(state.baselines, name) do
      {nil, _} ->
        {:ok, state}

      {{base_names, base_env}, baselines} ->
        {names, env} = snapshot()

        new_names = names -- base_names
        lost_names = base_names -- names

        base_map = Map.new(base_env)
        now_map = Map.new(env)

        env_added =
          for {k, v} <- now_map,
              base_map[k] != v,
              do: {k, v}

        env_removed =
          for {k, v} <- base_map,
              now_map[k] != v,
              do: {k, v}

        if new_names == [] and lost_names == [] and env_added == [] and
             env_removed == [] do
          {:ok, %{state | baselines: baselines}}
        else
          io(state, "ISOLATION-TWIN LEAK module=#{inspect(name)}")

          io(
            state,
            "ISOLATION-TWIN   names_new=#{inspect(new_names)}" <>
              " names_lost=#{inspect(lost_names)}"
          )

          Enum.each(env_added ++ env_removed, fn {k, v} ->
            io(state, "ISOLATION-TWIN   env #{inspect(k)} -> #{inspect(v)}")
          end)

          leak = %{module: name, names_new: new_names, env: env_added}
          {:ok, %{state | baselines: baselines, leaks: [leak | state.leaks]}}
        end
    end
  end

  def handle_event({:test_finished, %ExUnit.Test{state: nil}}, state) do
    {:ok, %{state | tests: state.tests + 1}}
  end

  def handle_event({:test_finished, %ExUnit.Test{}}, state) do
    {:ok, %{state | tests: state.tests + 1, failures: state.failures + 1}}
  end

  def handle_event({:suite_started, _opts}, state), do: {:ok, state}

  def handle_event(_event, state), do: {:ok, state}

  def handle_event({:suite_finished, _run_us, _load_us}, state) do
    io(state, "ISOLATION-TWIN SUMMARY modules_leaked=#{length(state.leaks)}" <>
                " tests=#{state.tests} failures=#{state.failures}")
    {:ok, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ExUnit delivers formatter events as casts of the raw event tuple;
  # handle_event/2 returns {:ok, state}, GenServer wants {:noreply, state}.
  def handle_cast(event, state) when is_tuple(event) do
    case handle_event(event, state) do
      {:ok, state} -> {:noreply, state}
      other -> other
    end
  end

  def handle_cast(_msg, state), do: {:noreply, state}

  defp io(state, msg), do: IO.puts(state.stdout, msg)
end
