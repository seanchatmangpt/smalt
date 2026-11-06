# Lane R7-I (v26.11.6): shared BLAKE3 vector court over the canonical fixture.
#
# Canonical fixture: /Users/sac/smalt/verification/blake3_vectors.json
# (sha256 dbbcd0c57e177447dd502c24d3b40c841ae70798e906081cb0d7ce35cb617fc6),
# minted from REAL cgap-blake3 at cgap commit
# a216b486fe7d312ad982ff66b158c30ae493ec09 via scratch cargo helper r7i-vgen
# (path-dep on /Users/sac/cgap/crates/cgap-blake3, CARGO_TARGET_DIR isolation;
# helper asserts hash == hash_wide_simd == hash_many_simd per vector before
# minting). Vendored byte-identical copies (sha-pinned in their consumer
# tests) at:
#   - /Users/sac/arcus/internal/arcus/adapter/testdata/blake3_vectors.json
#   - /Users/sac/cgap/crates/cgap-blake3/tests/blake3_vectors.json
#
# Vector iv251_2097153 (2,097,153 bytes) spans 2049 chunks = >= 3 Merkle
# reduction levels -- the SIMD witness row for the Rust-only SIMD drivers.
#
# Run: MIX_BUILD_ROOT=_build-r7i mix test test/smalt/posh/blake3_vectors_test.exs

defmodule Smalt.Test.Posh.Blake3VectorsTest do
  use ExUnit.Case, async: false

  alias Smalt.Posh.Blake3

  @vectors_path "/Users/sac/smalt/verification/blake3_vectors.json"
  @vectors File.read!(@vectors_path) |> Jason.decode!()
  @sha256_pin "dbbcd0c57e177447dd502c24d3b40c841ae70798e906081cb0d7ce35cb617fc6"

  test "canonical fixture sha256 self-pin (drift fence)" do
    got =
      :crypto.hash(:sha256, File.read!(@vectors_path))
      |> Base.encode16(case: :lower)

    assert got == @sha256_pin,
           "canonical fixture drifted: got #{got}"
  end

  test "Smalt.Posh.Blake3.digest matches every vector" do
    for v <- @vectors["vectors"] do
      input =
        if v["size"] == 0 do
          ""
        else
          # ivMod251 law, matching the generator's byte schedule.
          0..(v["size"] - 1)//1
          |> Enum.map(&rem(&1, 251))
          |> :binary.list_to_bin()
        end

      got = Blake3.digest(input) |> Base.encode16(case: :lower)
      assert got == v["digest"], "mismatch on #{v["name"]}: #{got}"
    end

    # SIMD witness row present (2 MiB+1 forces >= 3 Merkle levels).
    assert Enum.any?(@vectors["vectors"], &(&1["size"] == 2_097_153)),
           "SIMD witness vector missing"
  end
end
