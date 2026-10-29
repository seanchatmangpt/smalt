# Receipt r03 — publish-dry disposition (v26.10.29)

Standing: PARTIAL — dry run executed; gate 4 fixed in-lane; gate 1 is an
upstream window regression (evidence below), owner decision pending.

## Commands (exits inline)
    just quiet-check        # clear (load 8.3/11.8 < 16, after quiesce retry)
    just publish-dry        # FAIL -> fixed gate 4 -> re-run:
    just gen-error-codes    # wrote docs/ERROR_CODES.md (272 rows)
    just publish-dry        # gate 4 PASS; gate 1 FAIL (pre-window regression)

## Gate 4 (fixed, cross-lane unblock disclosed)
functions-plane landing ba47220 added T7 two-tuple codes
(InvalidHostJson / InvalidHostJsonVersion / UnknownHostJsonExtension)
without pinned statuses; gen_error_codes is fail-closed. Pinned 400
(validation class, per functions.ex @doc + route mapping); regenerated
docs/ERROR_CODES.md. Gate 4: PASS.

## Gate 1 (window regression, evidence)
    mix hex.build   # Stopping package build: Dependencies excluded
                    # (only Hex packages can be dependencies): graphlaw_ex
git log -S graphlaw_ex -- mix.exs -> 28f9dcbe (GL28-2 integration), which
postdates the v26.10.25 release tag 64dd24cb. A prod path dep cannot be
packaged by hex. Options for the owner:
(a) vendor graphlaw_ex into priv/ + load from path-in-package (packaging
    surgery, no behavior change),
(b) publish graphlaw_ex to hex first, then depend on the hex version,
(c) accept release-only shipping (scripts/release.sh MIX_ENV=prod mix
    release works with path deps) and retire the hex-package gate for
    this window with a typed waiver.
No in-lane lawful fix: the dep is the runtime admission gate (not
dev-gated), and choosing the packaging shape changes the release artifact.

## Wave state at close
- W1 generator lane, W4 slice 1, W2 mount, W3 fence, W5 flag: LANDED,
  committed (a95b6f40, a57ea921, 69c1db49, eddad94f, ea8e346a + c6).
- Courts: 4/4 router court, 5/5 generator suite, 1/1 fence (flippable —
  witnessed), 19/19 existing ARM corpus with the mount present.
- publish-dry: gate 4 PASS, gates 2/3 SKIP (no tarball — consequence of
  gate 1), gate 1 FAIL (window regression, receipted above).
