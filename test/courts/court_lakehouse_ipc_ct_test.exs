defmodule Smalt.Court.LakehouseIpcCtTest do
  @moduledoc """
  Runs the lane-12 common_test court suite
  (test/courts/court_lakehouse_ipc_SUITE.erl) under `mix test`:
  erlc-compiles the SUITE into tmp/, then :ct.run/2 executes it against
  the compiled smalt_lakehouse_mount beam. Exit fail-closed: any
  failed/skipped case fails this test. No sleeps — CT runs synchronously.
  """
  use ExUnit.Case, async: false

  @tag :lakehouse_ipc_ct
  test "common_test court suite passes" do
    root = File.cwd!()
    ebin = Path.join(root, "tmp/lakehouse_ct_ebin")
    logs = Path.join(root, "tmp/lakehouse_ct_logs")
    File.mkdir_p!(ebin)
    File.mkdir_p!(logs)

    suite_src = Path.join(root, "test/courts/court_lakehouse_ipc_SUITE.erl")

    ct_include =
      case :code.lib_dir(:common_test, :include) do
        dir when is_list(dir) ->
          List.to_string(dir)

        _ ->
          root = List.to_string(:code.root_dir())

          case Path.wildcard(Path.join(root, "lib/common_test-*/include")) do
            [dir | _] -> dir
            [] -> flunk("common_test include dir not found under #{root}")
          end
      end

    {out, rc} =
      System.cmd("erlc", ["-I", ct_include, "-o", ebin, suite_src],
        stderr_to_stdout: true
      )

    if rc != 0 do
      flunk("SUITE erlc failed (rc #{rc}): #{out}")
    end

    Code.append_path(Path.join(ebin, "") |> String.to_charlist())
    ct_ebin =
      Path.wildcard(Path.join(List.to_string(:code.root_dir()), "lib/common_test-*/ebin"))
      |> List.first()

    true = is_binary(ct_ebin)
    Code.append_path(ct_ebin)
    true = Code.ensure_loaded?(:ct)

    true = Code.ensure_loaded?(:court_lakehouse_ipc_SUITE)

    # the mount beam itself: compiled from src/ into the app ebin by mix
    true = Code.ensure_loaded?(:smalt_lakehouse_mount)

    {ok_n, failed_n, {user_skipped, _auto_skipped}} =
      :ct.run_test(
        suite: :court_lakehouse_ipc_SUITE,
        logdir: String.to_charlist(logs),
        auto_compile: false,
        include: [String.to_charlist(ct_include)]
      )

    assert failed_n == 0, "#{failed_n} CT failures — logs: #{logs}"
    assert user_skipped == 0, "#{user_skipped} CT cases skipped — logs: #{logs}"
    assert ok_n > 0, "CT ran zero cases (vacuous)"

    IO.puts(
      "lakehouse_ipc CT: #{ok_n} ok / #{failed_n} failed / #{user_skipped} skipped"
    )

  end
end
