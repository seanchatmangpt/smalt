defmodule Smalt.DataPlane.ConditionalHeadersTest do
  use ExUnit.Case, async: false
  alias Smalt.DataPlane.ConditionalHeaders

  @etag "\"0x1\""

  setup do
    SmaltTest.Lifecycle.ensure_store_up()
    Smalt.Store.clear()
    :ok
  end

  test "RFC 7232 precedence: IM and INM evaluated independently" do
    # IM fails -> 412 even with INM present
    assert ConditionalHeaders.evaluate(
             %{"if-match" => "\"dead\"", "if-none-match" => @etag},
             @etag
           ) == {:halt, 412}

    # IM passes -> INM evaluated -> 304
    assert ConditionalHeaders.evaluate(%{"if-match" => @etag, "if-none-match" => @etag}, @etag) ==
             {:halt, 304}

    # IM passes -> INM mismatch -> proceed
    assert ConditionalHeaders.evaluate(
             %{"if-match" => @etag, "if-none-match" => "\"other\""},
             @etag
           ) == :proceed

    # IM absent -> INM alone
    assert ConditionalHeaders.evaluate(%{"if-none-match" => @etag}, @etag) == {:halt, 304}
    assert ConditionalHeaders.evaluate(%{"if-none-match" => "\"other\""}, @etag) == :proceed
    # IM alone
    assert ConditionalHeaders.evaluate(%{"if-match" => @etag}, @etag) == :proceed
    assert ConditionalHeaders.evaluate(%{"if-match" => "\"dead\""}, @etag) == {:halt, 412}
    # star forms
    assert ConditionalHeaders.evaluate(%{"if-match" => "*"}, @etag) == :proceed
    assert ConditionalHeaders.evaluate(%{"if-none-match" => "*"}, @etag) == {:halt, 304}
  end

  # ---------------------------------------------------------------------------
  # Lens-5: candidate-dialect components of etag_matches?/2 and header/2 —
  # each pinned engine-side because the wire can only observe the outcome.
  # ---------------------------------------------------------------------------

  test "lens-5: comma-separated candidate lists match per-candidate" do
    # one matching candidate in a list -> INM halts 304
    assert ConditionalHeaders.evaluate(
             %{"if-none-match" => ~s("dead", "0x1", "stale")},
             @etag
           ) == {:halt, 304}

    # IM list with no match -> 412
    assert ConditionalHeaders.evaluate(%{"if-match" => ~s("dead", "stale")}, @etag) ==
             {:halt, 412}
  end

  test "lens-5: unquoted candidate matches the quoted current etag (strip_quotes leg)" do
    # client echoes the etag without quotes -> still matches
    assert ConditionalHeaders.evaluate(%{"if-none-match" => "0x1"}, @etag) == {:halt, 304}
    assert ConditionalHeaders.evaluate(%{"if-match" => "0x1"}, @etag) == :proceed
    # and the quoted candidate against a bare current etag? current is quoted
    # by construction; the strip_quotes leg strips the CANDIDATE's comparison
    # basis: candidate "0x1" == strip_quotes("\"0x1\"") — same term.
    assert ConditionalHeaders.evaluate(%{"if-none-match" => ~s("0x1")}, @etag) == {:halt, 304}
  end

  test "lens-5: header/2 lookup is case-insensitive and stringifies values" do
    assert ConditionalHeaders.header(%{"If-Match" => "\"x\""}, "if-match") == "\"x\""
    assert ConditionalHeaders.header(%{"IF-NONE-MATCH" => "*"}, "if-none-match") == "*"
    assert ConditionalHeaders.header(%{"if-match" => 42}, "IF-MATCH") == "42"
    assert ConditionalHeaders.header(%{"etag" => "\"x\""}, "if-match") == nil
    assert ConditionalHeaders.header(%{other: :atom_key}, "if-match") == nil
  end

  test "lens-5: non-map headers fall through to :proceed" do
    assert ConditionalHeaders.evaluate(nil, @etag) == :proceed
    assert ConditionalHeaders.evaluate([], @etag) == :proceed
  end

  test "lens-8: INM nil-guard is load-bearing on the empty-string etag (degenerate input)" do
    # Without the `if_none_match != nil` conjunct, an absent INM header against
    # an empty-string current etag would take etag_matches?(nil, "") ->
    # candidates [""] == strip_quotes("") == "" -> halt 304 with NO conditional
    # header present. The nil-guard keeps that fail-closed at :proceed.
    assert ConditionalHeaders.evaluate(%{}, "") == :proceed
    assert ConditionalHeaders.evaluate(%{"if-match" => "\"x\""}, "") == {:halt, 412}
  end

  test "lens-5: whitespace-padded candidates in a comma list are trimmed" do
    assert ConditionalHeaders.evaluate(%{"if-none-match" => ~s(  "0x1"  , "dead")}, @etag) ==
             {:halt, 304}
  end
end
