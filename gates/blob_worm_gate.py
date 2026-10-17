#!/usr/bin/python3
"""Invariant gate: blob WORM — overwrite/delete refuse with 409 while locked.

Positive: create a container, PUT a blob, set a legal hold, then attempt a
snapshot (PUT ?comp=snapshot), an overwrite (PUT same blob) and a DELETE.
lib/smalt/data_plane/blob_storage.ex refuses all three with 409
ContainerLocked while the hold is set; clearing the hold lets the DELETE
through (202) and the snapshot through (201), proving the lock actually binds.

Negative fixtures: mutated transcripts (snapshot accepted while locked,
overwrite accepted with 200, delete accepted while locked, missing 409s)
must each be refused.

Usage: python3 gates/blob_worm_gate.py   (exit 0 = hold, 1 = violated)
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common

ACCT, CONT, BLOB = "gateacct", "gatecont", "gateblob"


def capture(ports, shared_key):
    egress = ports["egress"]
    cont_path = f"/{ACCT}/{CONT}"
    blob_path = f"/{ACCT}/{CONT}/{BLOB}"
    ver = {"x-ms-version": "2021-12-02"}

    def hdrs(extra=None):
        h = dict(ver)
        if extra:
            h.update(extra)
        return h

    s_create, _, _ = common.http(egress, "PUT", cont_path, headers=hdrs())
    s_put, _, _ = common.http(egress, "PUT", blob_path, body=b"first",
                              headers=hdrs({"Content-Type": "application/octet-stream",
                                            "x-ms-blob-type": "BlockBlob"}))
    s_hold, _, _ = common.http(egress, "PUT", cont_path + "?comp=legalhold",
                               headers=hdrs({"x-ms-legal-hold": "true"}))
    s_snap_locked, _, snap_locked_body = common.http(
        egress, "PUT", blob_path + "?comp=snapshot", headers=hdrs())
    s_overwrite, _, overwrite_body = common.http(
        egress, "PUT", blob_path, body=b"second",
        headers=hdrs({"Content-Type": "application/octet-stream",
                      "x-ms-blob-type": "BlockBlob"}))
    s_del_locked, _, del_locked_body = common.http(egress, "DELETE", blob_path,
                                                   headers=hdrs())

    s_unhold, _, _ = common.http(egress, "PUT", cont_path + "?comp=legalhold",
                                 headers=hdrs({"x-ms-legal-hold": "false"}))
    # snapshot-before-delete: the snapshot freezes the live base blob, so it
    # must be taken while the blob still exists (post-delete it is 404).
    s_snap_free, _, _ = common.http(
        egress, "PUT", blob_path + "?comp=snapshot", headers=hdrs())
    s_del_free, _, _ = common.http(egress, "DELETE", blob_path, headers=hdrs())

    def code(body):
        return (body or {}).get("error", {}).get("code") if isinstance(body, dict) else None

    return {
        "container_create": s_create,
        "blob_put": s_put,
        "legal_hold": s_hold,
        "snapshot_locked_status": s_snap_locked,
        "snapshot_locked_code": code(snap_locked_body),
        "snapshot_after_release": s_snap_free,
        "overwrite_locked_status": s_overwrite,
        "overwrite_locked_code": code(overwrite_body),
        "delete_locked_status": s_del_locked,
        "delete_locked_code": code(del_locked_body),
        "hold_release": s_unhold,
        "delete_after_release": s_del_free,
    }


def verdict(obs):
    details = []
    ok = True

    def check(cond, msg):
        nonlocal ok
        details.append(("PASS" if cond else "FAIL") + " " + msg)
        ok = ok and cond

    check(obs.get("container_create") in (200, 201), "container created")
    check(obs.get("blob_put") in (200, 201), "blob written")
    check(obs.get("legal_hold") in (200, 202), "legal hold set")
    check(obs.get("overwrite_locked_status") == 409,
          f"overwrite under hold -> 409 (got {obs.get('overwrite_locked_status')})")
    check(obs.get("overwrite_locked_code") == "ContainerLocked",
          "overwrite refusal carries ContainerLocked")
    check(obs.get("delete_locked_status") == 409,
          f"delete under hold -> 409 (got {obs.get('delete_locked_status')})")
    check(obs.get("delete_locked_code") == "ContainerLocked",
          "delete refusal carries ContainerLocked")
    check(obs.get("snapshot_locked_status") == 409,
          f"snapshot under hold -> 409 (got {obs.get('snapshot_locked_status')})")
    check(obs.get("snapshot_locked_code") == "ContainerLocked",
          "snapshot refusal carries ContainerLocked")
    check(obs.get("snapshot_after_release") in (201, 200),
          f"snapshot after hold release succeeds (got {obs.get('snapshot_after_release')})")
    check(obs.get("delete_after_release") in (202, 200, 404),
          "delete after hold release succeeds (lock was real)")
    return ok, details


def mutate_fixtures(obs):
    def overwrite_accepted(o):
        o = dict(o)
        o["overwrite_locked_status"] = 200
        o["overwrite_locked_code"] = None
        return o

    def delete_accepted(o):
        o = dict(o)
        o["delete_locked_status"] = 202
        o["delete_locked_code"] = None
        return o

    def wrong_code(o):
        o = dict(o)
        o["overwrite_locked_code"] = "SomethingElse"
        return o

    def lock_not_binding(o):
        o = dict(o)
        o["delete_after_release"] = 409
        return o

    def snapshot_accepted(o):
        # hold-released mutation: the snapshot arm flips to the unlocked
        # outcome while the hold records still claim the lock was set.
        o = dict(o)
        o["snapshot_locked_status"] = 201
        o["snapshot_locked_code"] = None
        o["snapshot_after_release"] = 201
        return o

    def snapshot_wrong_code(o):
        o = dict(o)
        o["snapshot_locked_code"] = "SnapshotsWelcome"
        return o

    return [(n, f(obs)) for n, f in
            [("snapshot-under-hold-accepted", snapshot_accepted),
             ("snapshot-wrong-error-code", snapshot_wrong_code),
             ("overwrite-accepted", overwrite_accepted),
             ("delete-while-locked-accepted", delete_accepted),
             ("wrong-error-code", wrong_code),
             ("lock-never-bound", lock_not_binding)]]


if __name__ == "__main__":
    sys.exit(common.run_gate("blob-worm", capture, verdict, mutate_fixtures))
