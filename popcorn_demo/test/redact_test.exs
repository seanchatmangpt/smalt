defmodule PopcornDemo.RedactTest do
  use ExUnit.Case, async: true

  @fake_jwt "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.faketestsignature_do_not_use"

  test "Redact.fragment/1 collapses JWT-shaped substrings" do
    out = PopcornDemo.Redact.fragment("live=FAIL(body: token=#{@fake_jwt} end)")
    refute out =~ @fake_jwt
    assert out =~ "eyJ<redacted>"
    assert out ==
             "live=FAIL(body: token=eyJ<redacted>.eyJ<redacted>.faketestsignature_do_not_use end)"
  end

  test "Redact.fragment/1 caps at 120 chars" do
    out = PopcornDemo.Redact.fragment(String.duplicate("x", 500))
    assert byte_size(out) == 120
  end

  test "Redact.fragment/1 redacts after inspecting non-binary input" do
    out = PopcornDemo.Redact.fragment({:weird, @fake_jwt})
    refute out =~ @fake_jwt
    assert out =~ "eyJ<redacted>"
  end

  test "Smoke.run/0 receipt line contains no JWT-shaped material" do
    # Real run through the wired fail/2 path: whatever the surfaces produce,
    # the composed message must be JWT-free and capped fragments only.
    message = PopcornDemo.Smoke.run()
    refute message =~ ~r/eyJ[A-Za-z0-9_-]{10,}/
  end

  test "application leg catch-all shape: redacted, capped, JWT-free" do
    # The application.ex catch-all builds "leg=FAIL(" <> Redact.fragment(other)
    # — same composition the composed_receipt path uses for malformed legs.
    frag = "leg=FAIL(" <> PopcornDemo.Redact.fragment({:token, @fake_jwt}) <> ")"
    refute frag =~ @fake_jwt
    assert byte_size(frag) <= 120
    assert frag =~ "eyJ<redacted>"
  end
end
