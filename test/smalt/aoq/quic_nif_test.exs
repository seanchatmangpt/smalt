defmodule Smalt.Aoq.Quic.NifTest do
  use ExUnit.Case, async: false

  alias Smalt.Aoq.Quic.Nif

  test "loader law: module loads without raising in both dylib states" do
    status = Nif.load_status()
    assert match?({:loaded, _}, status) or match?({:stub, _}, status)
    IO.puts("[lane4] NIF load_status = #{inspect(status)}")
  end

  test "real dylib: open refuses a garbage CA typed" do
    if Nif.loaded?() do
      # Garbage CA: the engine validates the DER early and refuses.
      assert {:error, {:quic_refusal, {:nif_open_failed, {:loaded, _}}}} =
               Smalt.Aoq.Quic.open(0, "not-a-der")
    else
      IO.puts("[SKIP-loud] dylib not staged - real-NIF assertion skipped (stub test covers this VM)")
    end
  end

  test "stub path: every surface fn refuses with the error atom" do
    unless Nif.loaded?() do
      assert {:error, {:quic_refusal, {:nif_open_failed, {:stub, _}}}} =
               Smalt.Aoq.Quic.open(0, <<1, 2, 3>>)

      fake = make_ref()

      assert {:error, {:quic_refusal, {:nif_connect_failed, {:stub, _}}}} =
               Smalt.Aoq.Quic.connect(fake, "127.0.0.1:9", "localhost")

      assert {:error, {:quic_refusal, {:nif_send_failed, {:stub, _}}}} =
               Smalt.Aoq.Quic.send(fake, <<1>>)

      assert {:error, {:quic_refusal, {:nif_recv_failed, {:stub, _}}}} =
               Smalt.Aoq.Quic.recv(fake, 100)
    else
      IO.puts(
        "[SKIP-loud] dylib IS loaded - stub assertions skipped " <>
          "(both paths cannot coexist in one VM; loader court in test/courts covers the other arm)"
      )
    end
  end
end

defmodule Smalt.Aoq.Quic.WrapperTest do
  use ExUnit.Case, async: true

  alias Smalt.Aoq.Quic

  test "badarg refusals" do
    assert {:error, {:quic_refusal, :badarg}} = Quic.open(-1, <<>>)
    assert {:error, {:quic_refusal, :badarg}} = Quic.open(70_000, <<>>)
    assert {:error, {:quic_refusal, :badarg}} = Quic.open(0, :not_a_binary)
    assert {:error, {:quic_refusal, :badarg}} = Quic.connect(make_ref(), :bad, "x")
    assert {:error, {:quic_refusal, :badarg}} = Quic.recv(make_ref(), -5)
    assert {:error, {:quic_refusal, :badarg}} = Quic.recv(make_ref(), 61_000)
    assert {:error, {:quic_refusal, :badarg}} = Quic.serve(make_ref(), -1, <<>>, <<>>)
    assert {:error, {:quic_refusal, :badarg}} = Quic.accept(make_ref(), -1)
    assert {:error, {:quic_refusal, :badarg}} = Quic.accept_bi(make_ref(), -1)
    assert {:error, {:quic_refusal, :badarg}} = Quic.stream_open(:not_a_conn)
    assert {:error, {:quic_refusal, :badarg}} = Quic.stream_send(:not_a_stream, 42)
    assert {:error, {:quic_refusal, :badarg}} = Quic.stream_recv(make_ref(), 61_000)
    assert {:error, {:quic_refusal, :badarg}} = Quic.stream_close(:not_a_stream)
  end
end
