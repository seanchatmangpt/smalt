# GS1 GCS census

Standing: PARTIAL

## Azure blob structure (read)

- Facade `Smalt.DataPlane.BlobStorage` defdelegates to `Blob.Core/Worm/Leases/Website`;
  `BlobService` lists/metadata; `BlobError` renders XML envelopes.
- State lives in `Smalt.Store` ETS tables named in the GENERATED `Smalt.StoreTables`
  (`:smalt_blobs` keyed "acct/container/blob", `:smalt_blob_containers`, ...).
- Wire entry: `Smalt.EgressRouter` literal prefixes first, then a guarded blob splat
  `/{account}/{container}[/{blob}]`.

## Where a second dialect plugs in

- Route: GCS JSON paths (`/storage/v1`, `/upload`) are disjoint from the splat and must be
  forwarded BEFORE it; host-style XML needs a Host check ahead of the splat.
- State: a new Store table needs a pack-ontology edit (generated registry), out of lane scope;
  GS1 uses its own GenServer state instead (divergence logged in GS1.md).
- Errors: GCS uses a JSON envelope with `errors[].reason`; XML API uses `<Error><Code>`.

## Not read in depth

docs/WIRE_PARITY.md and posh/KNOWN_DIVERGENCES.md were not opened; divergence rows unregistered.
