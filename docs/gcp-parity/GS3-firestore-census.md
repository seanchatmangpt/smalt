# GS3 Firestore Census

Standing: PARTIAL

Surface (REST v1, `projects/{p}/databases/(default)/documents`): get, list, create
(documentId), patch (updateMask, currentDocument.updateTime/exists), delete, runQuery,
commit, batchWrite, beginTransaction, rollback.

| Area | Status |
|---|---|
| CRUD + preconditions (400 FAILED_PRECONDITION / 409 / 404) | implemented |
| updateTime as etag; CAS via Store.compare_and_swap/insert_new/cas_delete | implemented |
| runQuery: field/composite/unary filters, orderBy, limit, offset, select, allDescendants | implemented |
| commit atomic (serialized per project + rollback on abort) | implemented |
| transactions: optimistic read-set validation, ABORTED 409 | implemented |
| updateTransforms, cursors, batchGet, listCollectionIds, listen, aggregation | UNSUPPORTED |
| auth/IAM, multi-database ids other than (default) | UNSUPPORTED |
