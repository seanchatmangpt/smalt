defmodule Smalt.MixAuthScopeTest do
  use ExUnit.Case, async: false

  # Chicago: the helper runs against the real Application env; assertions on
  # final state. The tripwire arm greps the real task sources.

  @tasks_dir Path.expand("../lib/mix/tasks", __DIR__)

  describe "with_anonymous_auth/1" do
    setup do
      # Cross-file interference fix (v26.10.17 court run-1, 401-class cluster):
      # these tests set :auth_mode globally and previously leaked :enforce into
      # every later file in the batch (kd79 setup, C2 keyvault, PolicyRbac,
      # SmaltServices all 401'd). Save/restore the prior env per test.
      prev = Application.get_env(:smalt, :auth_mode)

      on_exit(fn ->
        if prev == nil do
          Application.delete_env(:smalt, :auth_mode)
        else
          Application.put_env(:smalt, :auth_mode, prev)
        end
      end)

      :ok
    end

    test "sets :anonymous inside and restores the previous value on exit" do
      Application.put_env(:smalt, :auth_mode, :enforce)

      seen =
        Smalt.MixAuthScope.with_anonymous_auth(fn ->
          Application.get_env(:smalt, :auth_mode)
        end)

      assert seen == :anonymous
      assert Application.get_env(:smalt, :auth_mode) == :enforce
    end

    test "restores when the body raises" do
      Application.put_env(:smalt, :auth_mode, :enforce)

      assert_raise(RuntimeError, fn ->
        Smalt.MixAuthScope.with_anonymous_auth(fn -> raise "boom" end)
      end)

      assert Application.get_env(:smalt, :auth_mode) == :enforce
    end

    test "deletes the key when there was no previous value" do
      Application.delete_env(:smalt, :auth_mode)

      Smalt.MixAuthScope.with_anonymous_auth(fn -> :ok end)

      refute Application.get_env(:smalt, :auth_mode)
    end
  end

  test "tripwire: no raw put_env(auth_mode: :anonymous) remains outside the helper" do
    offenders =
      Path.wildcard(Path.join(@tasks_dir, "*.ex"))
      |> Enum.flat_map(fn f ->
        body = File.read!(f)

        if String.contains?(body, "Application.put_env(:smalt, :auth_mode, :anonymous)") do
          [f]
        else
          []
        end
      end)

    assert offenders == [],
           "raw anonymous put_env leaked outside Smalt.MixAuthScope: #{inspect(offenders)}"
  end
end
