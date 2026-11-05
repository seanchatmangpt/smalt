defmodule Smalt.Internal.KD189LegalholdPutHeaderOnlyTest do
  @moduledoc """
  KD-189 court: PUT ?comp=legalhold (Set Container Legal Hold) is header-only
  on real Azure — 200 + `x-ms-legal-hold: true|false` response header, NO body.
  The pre-fix wire face projected a `{"has_legal_hold": ...}` JSON body
  (divergence disclosed by L44's KD-130 receipt, ae38ee23); the fix lands the
  header-only shape in `Smalt.DataPlane.Blob.Worm.set_legal_hold/4` (body nil)
  plus a nil-body branch in the PUT legalhold arm
  (`lib/smalt/egress/storage_catch_all.ex`).
  """

  use ExUnit.Case, async: false

  @account "kd189-acct"

  # Real router, real BlobStorage ETS, no mocks — assertions on wire bytes.
  defp call(method, path, opts \\ []) do
    conn =
      Plug.Test.conn(method, path, opts[:body])
      |> Plug.Conn.put_req_header("x-ms-version", "2023-11-03")
      |> then(fn c ->
        Enum.reduce(opts[:headers] || [], c, fn {k, v}, c ->
          Plug.Conn.put_req_header(c, k, v)
        end)
      end)

    Smalt.EgressRouter.call(conn, [])
  end

  defp put_container(container), do: call(:put, "/#{@account}/#{container}?restype=container")

  test "PUT comp=legalhold set answers 200, x-ms-legal-hold header, NO body" do
    assert put_container("hold-a").status == 201

    hold =
      call(:put, "/#{@account}/hold-a?restype=container&comp=legalhold",
        headers: [{"x-ms-legal-hold", "true"}]
      )

    assert hold.status == 200
    assert hold.resp_body == ""
    assert Plug.Conn.get_resp_header(hold, "x-ms-legal-hold") == ["true"]
  end

  test "PUT comp=legalhold clear answers 200 header-only too" do
    assert put_container("hold-b").status == 201

    call(:put, "/#{@account}/hold-b?restype=container&comp=legalhold",
      headers: [{"x-ms-legal-hold", "true"}]
    )

    release =
      call(:put, "/#{@account}/hold-b?restype=container&comp=legalhold",
        headers: [{"x-ms-legal-hold", "false"}]
      )

    assert release.status == 200
    assert release.resp_body == ""
    assert Plug.Conn.get_resp_header(release, "x-ms-legal-hold") == ["false"]
  end

  test "GET comp=legalhold surfaces the committed hold state in the header" do
    assert put_container("hold-c").status == 201

    call(:put, "/#{@account}/hold-c?restype=container&comp=legalhold",
      headers: [{"x-ms-legal-hold", "true"}]
    )

    get = call(:get, "/#{@account}/hold-c?restype=container&comp=legalhold")
    assert get.status == 200
    assert Plug.Conn.get_resp_header(get, "x-ms-legal-hold") == ["true"]
  end

  test "non-boolean flag is a typed 400 InvalidHeaderValue on the function face" do
    assert put_container("hold-d").status == 201

    assert {:error, 400, "InvalidHeaderValue", _} =
             Smalt.DataPlane.Blob.Worm.set_legal_hold(@account, "hold-d", "maybe")
  end

  test "missing container is a typed 404, not a 500" do
    assert {:error, 404, "ContainerNotFound", _} =
             Smalt.DataPlane.Blob.Worm.set_legal_hold(@account, "never-created", true)
  end

  # KD-COVERS: KD-189
end
