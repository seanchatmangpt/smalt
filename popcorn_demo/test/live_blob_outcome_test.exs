defmodule PopcornDemo.LiveBlobOutcomeTest do
  use ExUnit.Case, async: true

  # Chicago: classify_blob_outcome/2 is a pure function — tested by direct
  # call, no mocks, no doubles. Asserts on the returned typed outcome.
  alias PopcornDemo.LiveBlob

  describe "classify_blob_outcome/2" do
    test "browser CORS-shaped block (Failed to fetch) is a typed skip" do
      assert {:skip, "blob=SKIP(cors-preflight-403:health)"} =
               LiveBlob.classify_blob_outcome("health", "Failed to fetch")
    end

    test "browser CORS-shaped block (blocked) is a typed skip" do
      assert {:skip, "blob=SKIP(cors-preflight-403:put-blob)"} =
               LiveBlob.classify_blob_outcome("put-blob", "TypeError: blocked by CORS policy")
    end

    test "CORS keyword alone is a typed skip" do
      assert {:skip, "blob=SKIP(cors-preflight-403:get-blob)"} =
               LiveBlob.classify_blob_outcome("get-blob", "CORS preflight rejected")
    end

    test "http-500 is a failure, never masked as a skip" do
      assert {:error, "blob=FAIL(create-container:http-500)"} =
               LiveBlob.classify_blob_outcome("create-container", "http-500")
    end

    test "connection refused is a failure, never masked as a skip" do
      assert {:error, "blob=FAIL(health:econnrefused)"} =
               LiveBlob.classify_blob_outcome("health", "econnrefused")
    end

    test "non-binary reason falls through to failure" do
      assert {:error, "blob=FAIL(token::timeout)"} =
               LiveBlob.classify_blob_outcome("token", :timeout)
    end
  end
end
