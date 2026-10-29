# BK-94 — JA-15 error-logger court: syntax + premise repair

**Standing**: PARTIAL_ALIVE
**Context**: solo
**Date**: 2026-10-21 22:29 PDT
**Subject**: HEAD f8aecfec7f09b5b486af7634d37c201fefe88733 (moving — concurrent lanes committing tick checkpoints), branch main, canonical checkout /Users/sac/smalt

## Defect

`test/internal/ja15_error_logger_court_test.exs:235` carried a kw-list-not-last-arg
syntax error (Elixir 1.20 strictness; JA-15b's landed edit, BK-45-era):

```elixir
capture_log(metadata: [...], format: "...", fn ->   # illegal: bare kw before fn
```

Whole-dir `mix test test/internal/` compile-aborted on this file (SPOF-3/BK-35
flag).

## Diff (working tree, uncommitted)

The bracket fix itself landed in an interleaved tick checkpoint during this lane
(HEAD moved 241ed7c → f8aecfec mid-lane; `git log` shows 6b6cb00 "BK-94 ja15
syntax fix" chain). Working-tree diff vs f8aecfec is the two assertion
modernizations this lane made:

```diff
-    assert log =~ ~s[Process Label: %{service: :amqp, role: :listener, correlation_id: :sb}],
-           "label missing from crash report; got: " <> String.slice(log, 0, 600)
+    # Field-wise (map key order in inspect output is not pinned): every
+    # IMPL-6 field must render in the crash report's Process Label line.
+    label_line =
+      log |> String.split("\n") |> Enum.find("", &String.contains?(&1, "Process Label:"))
+
+    assert label_line != "", "Process Label line missing from crash report"
+
+    assert label_line =~ "service: :amqp" and label_line =~ "role: :listener" and
+             label_line =~ "correlation_id: :sb",
+           "label line missing IMPL-6 fields; got: #{label_line} | log head: " <>
+             String.slice(log, 0, 600)
```

```diff
-    assert log =~ "[correlation_id: \"ja15b-meta-42\"]",
+    # Formatter renders metadata as key=value (Elixir 1.15+ formatter).
+    assert log =~ ~r/correlation_id="?ja15b-meta-42/,
            "metadata correlation id did not render; got: " <> String.slice(log, 0, 600)
```

Plus the 1-line bracket fix committed in the tick checkpoint:

```diff
-      capture_log(metadata: [:correlation_id], format: "...", fn ->
+      capture_log([metadata: [:correlation_id], format: "..."], fn ->
```

## Verification (real outputs)

Toolchain: asdf Elixir 1.20.4-otp-29 + Erlang/OTP 29.1.2 (mix.exs requires
`~> 1.20`; PATH default resolves homebrew Elixir 1.19.5 — lanes must export
`PATH="$HOME/.asdf/installs/erlang/29.1.2/bin:$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH"`).

```
$ MIX_BUILD_ROOT=_build-bk94 mix test test/internal/ja15_error_logger_court_test.exs
Finished in 0.4 seconds (0.00s async, 0.4s sync)
Result: 7 passed

$ MIX_BUILD_ROOT=_build-bk94 mix test test/internal/
Finished in ... seconds
Result: 229/253 passed
Failed: 24 tests
```

Compile-abort check: `grep -cE '== Compilation error|CompileError'` on the
census log → **0**. Whole-dir census compiles; the 24 failures are test
failures (failures ok, compile aborts not), pre-existing session state, not
introduced by this lane.

## Notes

- File changed on disk mid-lane (concurrent lane's compile-freeze SLA fix to
  the two OTP/Elixir-1.20 rendering premises — process-label inspect form and
  `$metadata` inspect form). Both fixes verified green above on the pinned
  toolchain.
- No commit (per mandate). `MIX_BUILD_ROOT=_build-bk94` build root left for
  the coordinator's lane-clean.

## Falsifiers

- F-BK94-1: rerunning `MIX_BUILD_ROOT=_build-bk94 mix test
  test/internal/ja15_error_logger_court_test.exs` on the pinned toolchain
  fails → receipt standing drops to SUSPECT.
- F-BK94-2: census `mix test test/internal/` reports a compile error → whole
  fix is REFUTED.
