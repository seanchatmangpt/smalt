defmodule Smalt.Posh.PortSupervisionTest do
  use ExUnit.Case, async: false

  @bin_path Path.expand("posh/bin/posh")

  setup do
    tmp_dir = System.tmp_dir!()
    unique = Integer.to_string(:erlang.unique_integer([:positive]))
    sock_path = Path.join(tmp_dir, "posh-test-#{unique}.sock")

    on_exit(fn ->
      File.rm(sock_path)
    end)

    %{sock_path: sock_path, unique: unique}
  end

  test "supervises posh port and restarts on abnormal exit", %{sock_path: sock_path, unique: unique} do
    if File.exists?(@bin_path) do
      {:ok, sup} =
        Smalt.Posh.Supervisor.start_link(
          bin_path: @bin_path,
          socket_path: sock_path,
          name: :"test_posh_sup_#{unique}",
          ingress_name: :"ingress_sup_#{unique}",
          egress_name: :"egress_sup_#{unique}",
          task_supervisor_name: :"task_sup_#{unique}",
          ring_name: :"ring_#{unique}",
          log_name: :"log_#{unique}"
        )

      # Give port time to boot
      Process.sleep(200)

      # Verify socket was created by the port
      assert File.exists?(sock_path)

      # Get the port pid
      children = Supervisor.which_children(sup)
      {_id, port_pid, _type, _modules} =
        Enum.find(children, fn
          {{Smalt.Posh.Port, _}, _pid, _, _} -> true
          {Smalt.Posh.Port, _pid, _, _} -> true
          _ -> false
        end)

      assert is_pid(port_pid)

      # Kill the port process abnormally
      Process.exit(port_pid, :kill)
      Process.sleep(300)

      # Verify supervisor restarted it
      new_children = Supervisor.which_children(sup)
      {_id, new_port_pid, _type, _modules} =
        Enum.find(new_children, fn
          {{Smalt.Posh.Port, _}, _pid, _, _} -> true
          {Smalt.Posh.Port, _pid, _, _} -> true
          _ -> false
        end)

      assert is_pid(new_port_pid)
      assert new_port_pid != port_pid

      Supervisor.stop(sup)
    else
      # If binary not built yet, ensure typed error returned
      res = Smalt.Posh.Port.start_link(bin_path: "/nonexistent/posh", socket_path: sock_path)
      assert {:error, {:port, {:enoent, "/nonexistent/posh"}}} = res
    end
  end
end
