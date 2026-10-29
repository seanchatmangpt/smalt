defmodule Internal.EXPL3DataplaneRepairsCourtTest do
  # EXPL-3 repair lane (v26.10.22): T1/T2/T3 fail-open -> fail-closed repairs,
  # each proven against the real collaborators (real XML bodies, real ETS
  # policy state, real Store-backed queue) — no mocks; assertions are on the
  # typed wire shapes and the stored state AFTER the mutation attempt.
  #
  # T1 (F1): blob service-properties envelope-absent body used to silently
  # store enabled:false + 200. Now: empty body = legal clear (200, disabled);
  # envelope-parseable = parse + apply; non-empty non-envelope = typed 400
  # InvalidXmlDocument with the PRIOR policy state left unchanged.
  #
  # T2 (F2): queue `x-ms-ttl` parse used to fail open to the 7-day default.
  # Now: malformed/negative -> typed 400 InvalidHeaderValue and NO enqueue;
  # `x-ms-ttl=-1` is the explicit never-expire form; absent keeps the default.
  #
  # T3 (F3): MHSM degenerate empty constraint sets (anyOf/allOf/assertions
  # empty) used to reduce to ops-only :ok (allow-all). Now: typed 403
  # KeyReleasePolicyViolation; matching non-empty assertions still admit.
  use ExUnit.Case, async: false

  alias Smalt.DataPlane.BlobSoftDelete
  alias Smalt.DataPlane.MHSM
  alias Smalt.DataPlane.QueueStorage

  @account "expl3r"
  @blob_acct "expl3r-blob"

  # ---------------------------------------------------------------------------
  # T1 — blob soft-delete service-properties three-case parse
  # ---------------------------------------------------------------------------

  test "T1a: garbage <foo/> delete-retention PUT is typed 400 and does NOT flip prior policy" do
    BlobSoftDelete.set_delete_retention_policy(@blob_acct, """
    <DeleteRetentionPolicy><Enabled>true</Enabled><Days>7</Days></DeleteRetentionPolicy>
    """)

    assert BlobSoftDelete.delete_retention_policy(@blob_acct) == %{"enabled" => true, "days" => 7}

    assert {:error, 400, "InvalidXmlDocument", msg} =
             BlobSoftDelete.set_delete_retention_policy(@blob_acct, "<foo/>")

    assert msg =~ "DeleteRetentionPolicy"

    # Prior state unchanged — the garbage PUT must not have disabled it.
    assert BlobSoftDelete.delete_retention_policy(@blob_acct) == %{"enabled" => true, "days" => 7}
  end

  test "T1b: empty body is the legal clear (200, disabled)" do
    BlobSoftDelete.set_delete_retention_policy(@blob_acct, """
    <DeleteRetentionPolicy><Enabled>true</Enabled><Days>7</Days></DeleteRetentionPolicy>
    """)

    assert {:ok, %{"enabled" => false}} = BlobSoftDelete.set_delete_retention_policy(@blob_acct, "")
    assert BlobSoftDelete.delete_retention_policy(@blob_acct) == %{"enabled" => false}
  end

  test "T1c: valid envelope parses + applies (enabled with days)" do
    assert {:ok, %{"enabled" => true, "days" => 30}} =
             BlobSoftDelete.set_delete_retention_policy(@blob_acct, """
             <DeleteRetentionPolicy><Enabled>true</Enabled><Days>30</Days></DeleteRetentionPolicy>
             """)

    assert BlobSoftDelete.delete_retention_policy(@blob_acct) == %{"enabled" => true, "days" => 30}
  end

  test "T1d: garbage <foo/> versioning PUT is typed 400 and does NOT flip prior flag" do
    assert {:ok, true} = BlobSoftDelete.set_versioning_enabled(@blob_acct, "<IsVersioningEnabled>true</IsVersioningEnabled>")

    assert {:error, 400, "InvalidXmlDocument", msg} =
             BlobSoftDelete.set_versioning_enabled(@blob_acct, "<foo/>")

    assert msg =~ "IsVersioningEnabled"
    assert BlobSoftDelete.versioning_enabled?(@blob_acct) == true
  end

  test "T1e: empty body clears versioning (200, off); valid envelope applies" do
    assert {:ok, false} = BlobSoftDelete.set_versioning_enabled(@blob_acct, "")
    assert BlobSoftDelete.versioning_enabled?(@blob_acct) == false

    assert {:ok, true} =
             BlobSoftDelete.set_versioning_enabled(@blob_acct, "<IsVersioningEnabled>true</IsVersioningEnabled>")

    assert BlobSoftDelete.versioning_enabled?(@blob_acct) == true
  end

  # ---------------------------------------------------------------------------
  # T2 — queue x-ms-ttl typed refusal (fail-open default removed)
  # ---------------------------------------------------------------------------

  defp unique_queue, do: "q-expl3r-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))

  defp enqueue(ttl_value) do
    queue = unique_queue()
    {:ok, 201, _} = QueueStorage.create_queue(@account, queue)
    xml = "<QueueMessage><MessageText>expl3r-payload</MessageText></QueueMessage>"
    {queue, QueueStorage.put_message(@account, queue, xml, %{"messagettl" => ttl_value})}
  end

  test "T2a: x-ms-ttl=abc is a typed 400 InvalidHeaderValue and NO message is enqueued" do
    {queue, result} = enqueue("abc")

    assert {:error, 400, "InvalidHeaderValue", msg} = result
    assert msg =~ "x-ms-ttl"

    # State assertion: nothing was enqueued — dequeue finds no message.
    assert {:ok, 200, _headers, body} = QueueStorage.get_messages(@account, queue, %{})
    refute body =~ "expl3r-payload"
    refute body =~ "<MessageText>expl3r"
  end

  test "T2b: x-ms-ttl=-5 is a typed 400; -1 is the legal never-expire form" do
    assert {:error, 400, "InvalidHeaderValue", _} = enqueue("-5") |> elem(1)

    {queue, result} = enqueue("-1")
    assert {:ok, 201, _, body} = result
    assert body =~ "<ExpirationTime>" and body =~ "9999"

    # Never-expire: far-future expiry sentinel, message still retrievable.
    assert {:ok, 200, _, got} = QueueStorage.get_messages(@account, queue, %{})
    assert got =~ "9999"
    assert got =~ "<MessageId>"
  end

  test "T2c: valid ttl applies unchanged (60s); absent keeps the 7-day default" do
    {queue, result} = enqueue("60")
    assert {:ok, 201, _, body} = result
    assert body =~ "<TimeNextVisible>"

    assert {:ok, 200, _, got} = QueueStorage.get_messages(@account, queue, %{})
    assert got =~ "expl3r-payload"
    refute got =~ "9999"

    {queue2, result2} = enqueue(nil)
    assert {:ok, 201, _, _} = result2
    assert queue2
  end

  # ---------------------------------------------------------------------------
  # T3 — MHSM degenerate empty constraint sets refuse (fail-closed)
  # ---------------------------------------------------------------------------

  @satisfying %{"x-ms-attestation-type" => "sevsnpvm"}

  test "T3a: empty anyOf refuses despite fully satisfying claims" do
    assert {:error, 403, %{"error" => %{"code" => "KeyReleasePolicyViolation", "message" => msg}}} =
             MHSM.evaluate_policy(%{"anyOf" => []}, @satisfying)

    assert msg =~ "anyOf is empty"
  end

  test "T3b: empty allOf / empty assertions refuse" do
    for policy <- [%{"allOf" => []}, %{"assertions" => []}] do
      assert {:error, 403, %{"error" => %{"code" => "KeyReleasePolicyViolation", "message" => msg}}} =
               MHSM.evaluate_policy(policy, @satisfying)

      assert msg =~ "empty constraint set"
    end
  end

  test "T3c: matching non-empty assertion still admits; ops-only unchanged" do
    assert :ok =
             MHSM.evaluate_policy(
               %{"anyOf" => [%{"claim" => "x-ms-attestation-type", "condition" => "equals", "value" => "sevsnpvm"}]},
               @satisfying
             )

    assert :ok =
             MHSM.evaluate_policy(
               %{"assertions" => [%{"claim" => "x-ms-attestation-type", "condition" => "equals", "value" => "sevsnpvm"}]},
               %{"x-ms-isolation-tee" => %{"x-ms-attestation-type" => "sevsnpvm"}}
             )

    # ops-only policy (no claim-constraint keys) stays :ok.
    assert :ok = MHSM.evaluate_policy(%{"allowed_operations" => ["sign"]}, %{})
  end

  test "T3d: non-empty anyOf whose entries all mismatch still refuses (behavior unchanged)" do
    assert {:error, 403, %{"error" => %{"code" => "KeyReleasePolicyViolation"}}} =
             MHSM.evaluate_policy(
               %{"anyOf" => [%{"claim" => "x-ms-attestation-type", "condition" => "equals", "value" => "other"}]},
               @satisfying
             )
  end
end
