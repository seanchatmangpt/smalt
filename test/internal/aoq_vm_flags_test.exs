defmodule Smalt.Aoq.VmFlagsTest do
  @moduledoc false
  # LANE-09: Chicago-style — real file reads against the real rel/vm.args.eex,
  # no mocks. The fail-closed mutations use real temp copies, never a patch of
  # the repo file.
  use ExUnit.Case, async: false

  alias Smalt.Aoq.Flags
  alias Smalt.Aoq.Scheduler

  test "rel/vm.args.eex carries both AoQ flags as whole-line directives" do
    path = Path.join(File.cwd!(), "rel/vm.args.eex")
    assert File.exists?(path), "rel/vm.args.eex must exist"
    assert {:ok, :present} = Flags.check_flags(File.read!(path))
  end

  test "verify!/0 passes on the real checkout VM args" do
    assert :ok = Flags.verify!()
  end

  test "verify!/0 is fail-closed: dropped flag in a real mutated copy raises" do
    dir = Path.join(System.tmp_dir!(), "aoq-vmargs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "vm.args"), """
    ## mutated copy — court fixture
    +sbt db
    """)

    System.put_env("RELEASE_SYS_CONFIG", dir)

    try do
      assert_raise RuntimeError, ~r/missing required AoQ flags/, fn ->
        Flags.verify!()
      end
    after
      System.delete_env("RELEASE_SYS_CONFIG")
      File.rm_rf!(dir)
    end
  end

  test "verify!/0 is fail-closed: absent VM args file raises" do
    System.put_env("RELEASE_SYS_CONFIG", "/tmp/aoq-no-such-dir-#{System.unique_integer([:positive])}")

    try do
      assert_raise RuntimeError, ~r/missing/, fn ->
        Flags.verify!()
      end
    after
      System.delete_env("RELEASE_SYS_CONFIG")
    end
  end

  test "required_flags/0 names exactly the brief §4 flags" do
    assert Flags.required_flags() == ["+sbt db", "+sbwt none", "+hms 2097152"]
  end

  test "next_core/0 round-robins within schedulers_online" do
    schedulers = :erlang.system_info(:schedulers_online)

    cores = for _ <- 1..(schedulers * 3), do: Scheduler.next_core()
    assert Enum.all?(cores, &(&1 in 1..schedulers))
    assert Enum.uniq(cores) |> length() == schedulers
  end

  test "pin/1 wraps process_flag(:scheduler, ...)" do
    schedulers = :erlang.system_info(:schedulers_online)
    core = Scheduler.next_core()

    result = Scheduler.pin(core)
    # process_flag(:scheduler, n) returns the previous binding: 0 if the
    # process was unpinned, otherwise the scheduler id it was pinned to.
    assert result in 0..schedulers
  end
end
