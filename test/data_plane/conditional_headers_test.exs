defmodule Smalt.DataPlane.ConditionalHeadersTest do
  use ExUnit.Case, async: false
  alias Smalt.DataPlane.ConditionalHeaders

  @etag "\"0x1\""

  setup do
    if Process.whereis(Smalt.Store) == nil, do: Smalt.Store.start_link()
    Smalt.Store.clear()
    :ok
  end

  test "RFC 7232 precedence: IM and INM evaluated independently" do
    # IM fails -> 412 even with INM present
    assert ConditionalHeaders.evaluate(%{"if-match" => "\"dead\"", "if-none-match" => @etag}, @etag) == {:halt, 412}
    # IM passes -> INM evaluated -> 304
    assert ConditionalHeaders.evaluate(%{"if-match" => @etag, "if-none-match" => @etag}, @etag) == {:halt, 304}
    # IM passes -> INM mismatch -> proceed
    assert ConditionalHeaders.evaluate(%{"if-match" => @etag, "if-none-match" => "\"other\""}, @etag) == :proceed
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
end
