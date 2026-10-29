defmodule PopcornDemo.GuidelineDualmodeTest do
  @moduledoc """
  testing-9: one suite, unchanged assertions, two backends.

  Mechanizes the W30-Q identity audit over the W30-G dual-mode harness
  (azurite-spike/dual-mode-test.mjs):

    1. the harness's assertion block (the five `record(` calls, sliced from
       `// 1. container create` to `await container.delete();`) carries zero
       BACKEND conditionals, and each `dual.*` assertion name occurs exactly
       once in the file;
    2. BACKEND=smalt and BACKEND=azurite both run the real harness as node
       subprocesses and both exit 0 with pass=5 fail=0;
    3. those two exit-code asserts ARE the unchanged-assertions invariant.

  Chicago: real subprocesses over real TLS/HTTP backends, asserts on exit
  codes and stdout. No mocks, no doubles.
  """

  use ExUnit.Case, async: false

  @harness_path Path.join([__DIR__, "..", "azurite-spike", "dual-mode-test.mjs"])
  @dual_names ["dual.container-create.201", "dual.put.2xx", "dual.list.includes-blob",
               "dual.get.byte-equal", "dual.delete.2xx"]

  test "harness assertion block is backend-independent (zero BACKEND conditionals)" do
    assert File.exists?(@harness_path)
    src = File.read!(@harness_path)

    block = portion(src, "// 1. container create", "await container.delete();")
    assert is_binary(block), "could not slice assertion block"

    assert Regex.scan(~r/BACKEND/, block) == [],
           "assertion block contains BACKEND conditional(s): " <> inspect(block)

    for name <- @dual_names do
      assert block =~ name
      assert length(Regex.scan(Regex.compile!(Regex.escape(name)), src)) == 1,
             "assertion " <> name <> " appears more than once - assertions changed"
    end
  end

  test "BACKEND=smalt runs the harness live and exits 0" do
    {out, 0} = run_harness("smalt")
    assert out =~ "SUMMARY backend=smalt pass=5 fail=0"
  end

  test "BACKEND=azurite runs the harness live and exits 0" do
    {out, 0} = run_harness("azurite")
    assert out =~ "SUMMARY backend=azurite pass=5 fail=0"
  end

  defp run_harness(backend) do
    env =
      %{"BACKEND" => backend, "AZURITE_BLOB_URL" => "http://127.0.0.1:10100"}
      |> Map.merge(if backend == "smalt" do
        %{"NODE_EXTRA_CA_CERTS" => ca_cert()}
      else
        %{}
      end)

    System.cmd("node", ["dual-mode-test.mjs"],
      cd: Path.dirname(@harness_path),
      env: env,
      stderr_to_stdout: true
    )
  end

  defp ca_cert do
    Path.expand("../../.smalt/tls/ca-cert.pem", Path.dirname(@harness_path))
  end

  defp portion(src, first, last) do
    case :binary.match(src, first) do
      {pos, _len} ->
        rest = binary_part(src, pos, byte_size(src) - pos)

        case :binary.match(rest, last) do
          {pos2, len2} -> binary_part(rest, 0, pos2 + len2)
          :nomatch -> nil
        end

      :nomatch ->
        nil
    end
  end
end
