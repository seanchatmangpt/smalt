# BK-149C — smalt-cli closeout residual-failure closure receipt

**Standing: ALIVE** — full smalt-cli suite on a live substrate: **129 passed,
2 skipped, 0 failed, exit 0** (was 3 failed / 116 passed / 11 skipped at
BK-149). `Context: solo`

## Subject

- Repo: /Users/sac/smalt @ main; lane files `smalt-cli/tests/test_blob.py`,
  `smalt-cli/tests/test_cosmos.py` + `docs/ERROR_CODES.md` regen landed via
  coordinator tick checkpoint e3e351fc ("BK-149C cli premises"); this receipt
  closes the ledger.
- Scope: the 3 typed pre-existing failures from
  `receipts/bk149-smaltcli-closeout.md`.

## Fix 1 — docs/ERROR_CODES.md stale projection (regen, no hand-edit)

- `python3 scripts/gen_error_codes.py` regenerated 248 rows; drift was pure
  line-number skew in `lib/smalt/arm_gateway/router.ex` /
  `lib/smalt/egress_router.ex` citations (concurrent lanes editing lib/).
- Post-regen `--check` exit 0. Drift recurred twice mid-session as other
  lanes moved lib/ line anchors; re-verified `--check` exit 0 immediately
  before this receipt (the artifact is committed, current HEAD is in sync).

## Fix 2 — test_blob WORM-overwrite premise (PREMISE ROT, test fixed)

- Premise-rot check per the SDK-parity law: KD-135 is CLOSED-WITH-RECEIPT
  (`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` KD-135 row): current HEAD
  defaults containers to WRITABLE (`lib/smalt/data_plane/blob_storage.ex:177`
  `# KD-COVERS: KD-135`, immutable defaults false) with immutability OPTED IN
  via the `x-ms-immutable-policy` header
  (`lib/smalt/egress_router.ex:1368`). Real Azure: containers are writable by
  default; immutability policies forbid OVERWRITE of an existing blob but
  permit new-blob writes — smalt HEAD matches real semantics; the old
  "default = immutable" test premise described the pre-shim tree.
- Fix (test only, no lib change): new `make_immutable_container` helper
  (raw PUT with `x-ms-immutable-policy: true`); the 409 test now opts IN
  before pinning 409 ContainerLocked on overwrite;
  `test_container_create_default_immutable` renamed
  `test_container_create_default_writable` and now proves overwrite SUCCEEDS
  on a default container.
- Live wire: `tests/test_blob.py` 6/6 passed (2.07s) against the anonymous
  substrate.
- KD register: no new row owed — KD-135 already covers the posture; no
  divergence remains (the corrected test pins the real-Azure-consistent
  behavior).

## Fix 3 — test_cosmos OFFSET-LIMIT-400 premise (PREMISE ROT, test fixed)

- Premise-rot check: real Cosmos OFFSET LIMIT is admitted (docs show
  OFFSET LIMIT without ORDER BY as valid, order nondeterministic), and
  smalt landed the OFFSET/LIMIT pair parser (cosmos_sql.ex:962, pinned 200 by
  the sibling `test_offset_limit_pair_admitted_200`). A live probe against
  the substrate (anonymous, real wire) gave:
  - `SELECT VALUE c.n FROM c` -> 400 SyntaxError "Expected FROM <alias>"
  - `SELECT * FROM c OFFSET 1 LIMIT 1` -> 200
  - `SELECT * FROM c ORDER BY c.n OFFSET 1 LIMIT 1` -> 200
  - `SELECT TOP 1 * FROM c` -> 200
  - `SELECT BOGUS FROM c` -> 200 (permissive projection)
  - `SELECT * FROM c WHERE BOGUS(` -> 400 SyntaxError
  - `SELECT * FROM a JOIN b` -> 400 SyntaxError
  So the old blanket "non-star => 400" whitelist premise is rot; only genuine
  grammar violations stay 400.
- Additional finding: the parametrize list carried a corrupted remnant row
  `" CosmosDB"` (not a query — bad earlier edit). Replaced the list with the
  three live-probed genuine-400 shapes: VALUE projection, malformed WHERE,
  malformed JOIN.
- Live wire: `tests/test_cosmos.py` 9/9 passed (6.33s).

## Session-extras (typed, witnessed)

- `tests/test_virtual_serial.py` 3 fixture ERRORs (not in BK-149's tally):
  `_build/dev` was stale — `Smalt.Hw.VirtualSerial.beam` absent from the dev
  ebins, so the `--pa` stdio attach died `UndefinedFunctionError`. Fixed by
  `MIX_ENV=dev mix compile`; lane then 4/4 passed. No source change owed.
- ERROR_CODES drift recurred mid-session (concurrent lib edits); handled per
  Fix 1.

## Environment / flake ledger (machine-busy window)

- Mid-session full-suite runs flapped (substrate swept mid-run, boot timeouts)
  while machine load sat 20-47 with 10-15 concurrent `mix run` boot loops —
  the cli4/cli5 conftest identity guards mutually sweep the shared 39643/
  38654 port blocks under concurrent lanes. This is environmental, not a
  code defect: identical suite answered 129 passed in the settled window.
  Candidate follow-up: lane-private boot ports for the cli conftest (not
  landed here — shared-seam change, out of lane).

## Receipt run (embedded full-suite output, exit contract)

```
$ cd smalt-cli && .venv-cli/bin/python -m pytest tests/ -q
...
-- Docs: https://docs.pytest.org/en/stable/how-to/capture-warnings.html
129 passed, 2 skipped, 6 warnings in 63.58s (0:01:03)
EXIT=0
```

Environment: `PATH=$HOME/.asdf/shims:$PATH` (elixir 1.20.4-otp-29), python
venv `smalt-cli/.venv-cli`, live anonymous + enforce substrates (cli4/cli5
conftest protocol, reused healthy markers).
