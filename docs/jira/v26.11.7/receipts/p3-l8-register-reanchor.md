# P3-L8: KD register dialect-column re-anchor

Standing: PASS

Lane: P3-L8 (cross-lane, repos /Users/sac/smalt + /Users/sac/arcus). No git
commits (per contract).

## Scope executed

1. **Register note append** — `docs/jira/v26.11.6/KNOWN_DIVERGENCES.md`,
   end-of-file note block only:
   - `AZURE-#1` rows' arcus-side register =
     `arcus docs/jira/v26.11.6/KNOWN_DIVERGENCES.azure.md` (191 KD rows +
     KD-A1..A4).
   - Flips still owned by smalt kd-registrar (`scripts/kd_flip.py --apply`)
     until P1 admits; note is an authority map, no row edits, no flips.
2. **Comment-only re-anchor** — `lib/smalt/plane/control_supervisor.ex`
   `@moduledoc` lines 12–14 region: the dialect-conformance court note now
   cites the arcus counterpart wire courts. All three named files verified
   present on disk pre-write:
   - `/Users/sac/arcus/internal/dialect/azure/wire_court_test.go`
   - `/Users/sac/arcus/internal/dialect/azure/routing_court_test.go`
   - `/Users/sac/arcus/internal/dialect/azure/error_code_parity_court_test.go`
3. **This receipt** (new file).

## Gates (real output)

- Register diff append-only:
  `git diff --stat docs/jira/v26.11.6/KNOWN_DIVERGENCES.md` →
  `1 file changed, 10 insertions(+)`; deletion grep count 0
  (`git diff ... | grep -c '^-[^-]'` → 0). The other +1 line is the
  pre-existing uncommitted KD-212 row (lane M1, already in tree before this
  lane started); this lane added 9 lines, all after KD-212.
- `control_supervisor.ex` diff comment-only: every +/- line is inside the
  `@moduledoc` docstring; zero code lines changed (diff inspected above the
  module body, `def start_link` untouched).

## Verified counts

- Arcus azure register: `grep -c '^| KD-'` → 195 rows = 191 KD-nn rows +
  KD-A1..A4 (matches contract's "191 rows + KD-A1..A4").

## Falsifier / open condition

The note is an authority map only; it becomes stale if (a) arcus re-homes
its azure register, or (b) P1 admits and the kd-registrar handoff changes.
Either event must update or retire this note.
