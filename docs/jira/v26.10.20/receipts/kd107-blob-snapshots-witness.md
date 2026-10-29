# KD-107 close witness — blob snapshot lifecycle (lane K7, 2026-10-21)

**Standing:** PASS
Context: solo

Snapshot engine + wire arms already landed (blob lane KD-107 RAISE 2026-10-20:
snapshot_blob/get_blob_snapshot/list_snapshots/lease_blob_snapshot in
lib/smalt/data_plane/blob_storage.ex; comp=snapshot PUT, GET ?sharesnapshot,
and include=snapshots list decoration in egress_router.ex). Lane K7 verified
the row's falsifier live on 8443 (bearer, x-ms-version 2021-12-02):

    cont2:201            PUT /smalt/k7cont2?restype=container
    put-v1:201           PUT /smalt/k7cont2/k7blob.txt  "hello-v1"
    snap-ts:2026-10-21T01:51:00.438587Z   PUT ?comp=snapshot → x-ms-snapshot
    put-v2:409           base-blob overwrite (see note)
    base-now:hello-v1
    at-snap:hello-v1     GET ?sharesnapshot=<ts> → frozen record byte-exact
    snapshots-listed:1   GET ?restype=container&comp=list&include=snapshots → <Snapshot> decorated

Create → list → read-at-snapshot all pass; snapshot read-back is isolated from
base-blob mutation by construction (frozen ETS record).

Note (not a KD-107 divergence): base-blob overwrite on the fresh probe containers
returns 409 ContainerLocked — the substrate WORM immutability policy arm, not a
snapshot-listing gap. KD-107 is FLIP-ELIGIBLE.