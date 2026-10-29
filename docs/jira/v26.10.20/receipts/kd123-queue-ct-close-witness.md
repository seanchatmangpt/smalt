# KD-123 close witness — queue urlencoded body survives (coordinator, 2026-10-21)

**Standing:** PASS
Context: solo

Shim: `# KD-COVERS: KD-123` raw-body exemption for POST /:account/:queue/messages
(lib/smalt/egress_router.ex, raw_blob_put?/1 family; plug-conn tests
test/integration/queue_message_ct_test.exs 3/3 x2 + KD-108/122 exemption-family
regression probe 5/5 by lane W6-HR). Live wire, substrate pid 82830+:

create-queue=201
put-urlencoded=201   (Content-Type: application/x-www-form-urlencoded)
GET dequeue: kde123-payload-7f3a  → KD123-BYTES-SURVIVED

The close condition (urlencoded POST storing correct bytes) is witnessed on the
real wire postdating the shim.
