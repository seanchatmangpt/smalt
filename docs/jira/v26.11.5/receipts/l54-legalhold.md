# L54 — KD-189: blob legal-hold PUT body divergence (candidate GENUINE, fixed)

Standing: PASS

Context: slice (lane L54 in the v26.11.5 20-lane wave). Repo: /Users/sac/smalt.
Build root: `_build-lane54`.

## Candidate verdict

**GENUINE** (no premise rot). Re-derivation: real Azure Blob Set Container
Legal Hold (`PUT ?comp=legalhold`) answers 200 with the `x-ms-legal-hold:
true|false` response header and NO response body; the emulator answered a
`{"has_legal_hold":true|false}` JSON body while worm.ex's own comment pinned
the header-only shape. The kd130 court (landed by L44, ae38ee23) already pins
`resp_body == ""` at `test/integration/kd130_container_exists_test.exs:104`
and was red on that leg — the registered-divergence evidence standard holds.
No API-version path of the real API returns a legal-hold body, so no
investigation-only row.

## As-found (pre-fix)

```
$ MIX_BUILD_ROOT=_build-lane54 mix test test/integration/kd130_container_exists_test.exs
Result: 6/8 passed
Failed: 2 tests
  1) ... WORM stays ahead: re-create under legal hold is 409 ContainerLocked
     code:  assert hold.resp_body == ""
     left:  "{\"has_legal_hold\":true}"
     right: ""
  2) KD-66 ranged GET content-md5 (pre-existing other-row debt, untouched)
```

## Fix

- `lib/smalt/data_plane/blob/worm.ex` `set_legal_hold/4` success arm: body
  `%{"has_legal_hold" => flag}` → `nil` (header-only), `# KD-COVERS: KD-189`
  token at the fix site.
- `lib/smalt/egress/storage_catch_all.ex` PUT comp=legalhold arm: added the
  `{:ok, status, headers, nil}` branch answering `send_resp(status, "")`
  (no JSON encode, no json content-type on the bodyless 200).
  **Compile-freeze disclosure**: L44 landed this file in ae38ee23 and is
  complete; this lane's edit is a follow-on to the legalhold arm only, and is
  named here (L44's receipt needs no amendment — its landed diff is untouched).
- Court: `test/internal/kd189_legalhold_put_header_only_test.exs` (new,
  5 legs, real router + real ETS, no mocks).

## Court (post-fix)

```
$ MIX_BUILD_ROOT=_build-lane54 mix test test/internal/kd189_legalhold_put_header_only_test.exs
Result: 5 passed, 0 failures
$ MIX_BUILD_ROOT=_build-lane54 mix test test/integration/kd130_container_exists_test.exs
Result: 7/8 passed
  1) KD-66 ranged GET content-md5 — pre-existing (baseline re-run at HEAD
     shows the identical failure; not session-introduced)
```

Non-regression sweep: `grep -rn has_legal_hold lib test` → only worm.ex
(pre-fix) → no other consumer of the removed body. kd_blob_court_test.exs
8/12 with KD-137/139/140/145-146 failing IDENTICALLY at HEAD baseline and
post-fix (pre-existing; not lane debt).

## KD row

`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` KD-189 minted (max id was KD-188;
DRAFT rows do not reserve ids). Status OPEN with fix landed + court green;
flip owed via `scripts/kd_flip.py --apply` (receipt postdates the shim,
satisfying the mtime gate).
