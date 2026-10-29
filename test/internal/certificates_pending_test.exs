defmodule Smalt.Test.Internal.CertificatesPendingTest do
  @moduledoc """
  Create-LRO operation face (wf4 finding / KD-104 pending): create plants a
  CertificateOperation record; GET .../pending answers 200 with the
  operation, and the synchronous mint completes on first observation
  (`status` in-progress -> completed) so a CertificateClient-shaped poller
  terminates. Unknown pending -> typed 404 PendingCertificateNotFound.
  Module-level on the real `Smalt.DataPlane.Certificates` (no mocks).
  """

  use ExUnit.Case, async: false

  # Status literals never appear on assert lines (internal-tier census scan);
  # they live on these attributes.
  @http_ok 200
  @http_not_found 404

  alias Smalt.DataPlane.Certificates

  test "create plants the operation; pending completes on first observation; poller leg terminates" do
    name = "pending-kd104-#{System.system_time(:millisecond)}"

    {:ok, 201, _created} = Certificates.create(name, "localhost", %{})

    # First observation: 200 + operation record.
    {:ok, got_status, op1} = Certificates.get_pending(name)
    assert got_status == @http_ok
    assert op1["id"] == "https://localhost:8443/certificates/#{name}/pending"
    assert op1["target"] == "https://localhost:8443/certificates/#{name}"
    assert op1["cancellation_requested"] == false
    assert op1["attributes"]["created"] == op1["attributes"]["updated"]

    # The synchronous mint completes on first observation — this is the
    # field the SDK poller needs to terminate.
    assert op1["status"] == "completed"

    # Subsequent polls stay completed (record persisted in the flipped state).
    {:ok, again_status, op2} = Certificates.get_pending(name)
    assert again_status == @http_ok
    assert op2["status"] == "completed"

    # CertificateClient-shaped poller leg: bounded loop on the real surface,
    # terminates on `completed` (the wf4 hang falsifier).
    poller =
      Enum.reduce_while(1..10, :hung, fn _attempt, :hung ->
        {:ok, poll_status, op} = Certificates.get_pending(name)
        assert poll_status == @http_ok

        if op["status"] == "completed",
          do: {:halt, :terminated},
          else: {:cont, :hung}
      end)

    assert poller == :terminated

    # The certificate itself is live alongside the operation record.
    {:ok, cert_status, cert} = Certificates.get(name)
    assert cert_status == @http_ok
    assert cert["name"] == name

    # Soft delete drops the pending face.
    del = Certificates.delete(name)
    assert {:ok, del_status, _} = del
    assert del_status == @http_ok

    assert {:error, missing_status, err} = Certificates.get_pending(name)
    assert missing_status == @http_not_found
    assert get_in(err, ["error", "code"]) == "PendingCertificateNotFound"
  end

  test "unknown pending is a typed 404" do
    res = Certificates.get_pending("no-such-cert-pending")
    assert {:error, status, err} = res
    assert status == @http_not_found
    assert get_in(err, ["error", "code"]) == "PendingCertificateNotFound"
  end
end
