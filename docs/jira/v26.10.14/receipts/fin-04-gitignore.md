# fin-04: .gitignore underscore-variant build dirs (DoD-6 follow-up)

## Change
`/Users/sac/smalt/.gitignore` — one line added adjacent to the existing build-dir block:

```gitignore
# The directory Mix will write compiled artifacts to (including multi-lane builds)
/_build/
/_build-*/
/_build_*
```

## Verification (git check-ignore -v)
Run with real directories present (`mkdir -p _build_f16L6 _build-laneX`), since
trailing-slash patterns only match directories:

```
.gitignore:4:/_build_*	_build_f16L6
.gitignore:3:/_build-*/	_build-laneX
.gitignore:2:/_build/	_build
```

- `_build_f16L6` ignored — matched by the NEW line 4 (`/_build_*`). DoD-6 gap closed.
- `_build-laneX` ignored — matched by pre-existing line 3 (unchanged behavior).
- `_build` ignored only by pre-existing canonical line 2 — the new pattern does
  NOT match `_build` (line attribution witnesses this); canonical Mix build dir
  remains intentionally ignored as before.

Test dirs removed after the check (`rmdir`). No commits made.

## Re-witness 2026-10-16

```
$ mkdir -p _build_f16L6 _build-laneX && git check-ignore -v _build_f16L6 _build-laneX; echo "exit=$?"
.gitignore:4:/_build_*	_build_f16L6
.gitignore:3:/_build-*/	_build-laneX
exit=0
$ rmdir _build_f16L6 _build-laneX && echo "rmdir ok"
rmdir ok
```

Both patterns hold on the current tree: `_build_*` via line 4, `_build-lane*` via
line 3 (`/_build-*/`, directory-only — a bare `git check-ignore` against a
non-existent `_build-laneX` does not match, the dir must exist to witness the
trailing-slash rule). Test dirs removed after the check.

check-ignore exit 0; rmdir exit 0. Re-witnessed on the current tree.
