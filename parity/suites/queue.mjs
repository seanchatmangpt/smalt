// suites/queue.mjs — Azure Queue Storage op list (smalt implements this
// plane: lib/smalt/data_plane/queue_storage.ex). Identical code path for
// every target via QueueServiceClient. Message ids/receipts/times are
// volatile and stripped by the differ; dequeue counts and bodies are not.
const statusOf = (res) => res?._response?.status ?? res?.statusCode ?? 200;

export async function runQueueSuite({ svc, runid }) {
  // Distinct prefix from the blob container namespace: smalt routes both
  // planes under /{account}/{name} and the namespaces collide.
  const qname = `parityq${runid}`;
  const queue = svc.getQueueClient(qname);
  const recs = [];
  const op = async (name, fn) => {
    try {
      recs.push({ op: name, ...(await fn()) });
    } catch (e) {
      recs.push({
        op: name,
        outcome: "error",
        status: e?.statusCode ?? 0,
        code: e?.errorCode ?? e?.code ?? null,
        fields: { message: String(e?.message ?? "").slice(0, 160) },
      });
    }
  };

  await op("queue-create", async () => {
    const r = await queue.create();
    return { outcome: "ok", status: statusOf(r), fields: {} };
  });

  await op("queue-get-properties", async () => {
    const r = await queue.getProperties();
    return { outcome: "ok", status: statusOf(r), fields: { hasMetadata: r.metadata != null } };
  });

  await op("queue-set-metadata", async () => {
    const r = await queue.setMetadata({ parity: runid });
    return { outcome: "ok", status: statusOf(r), fields: {} };
  });

  await op("queue-get-metadata", async () => {
    const r = await queue.getProperties();
    return { outcome: "ok", status: statusOf(r), fields: { parity: r.metadata?.parity ?? null } };
  });

  await op("queue-send-message", async () => {
    const r = await queue.sendMessage(`parity-body-${runid}`);
    return { outcome: "ok", status: statusOf(r), fields: { hasMessageId: Boolean(r.messageId) } };
  });

  await op("queue-receive-messages", async () => {
    const r = await queue.receiveMessages({ numberOfMessages: 1 });
    const items = r.receivedMessageItems ?? [];
    return {
      outcome: "ok",
      status: statusOf(r),
      fields: {
        count: items.length,
        bodies: items.map((m) => m.messageText),
        dequeueCounts: items.map((m) => m.dequeueCount),
      },
    };
  });

  // Visibility timeout pushes the received message out of reach; peek must
  // then see nothing — the receive/peek visibility contract.
  await op("queue-peek-empty-while-invisible", async () => {
    const r = await queue.peekMessages({ numberOfMessages: 1 });
    const items = r.peekedMessageItems ?? [];
    return { outcome: "ok", status: statusOf(r), fields: { count: items.length } };
  });

  await op("queue-receive-empty", async () => {
    const r = await queue.receiveMessages({ numberOfMessages: 1, visibilitytimeout: 1 });
    const items = r.receivedMessageItems ?? [];
    return { outcome: "ok", status: statusOf(r), fields: { count: items.length } };
  });

  await op("queue-clear-messages", async () => {
    const r = await queue.clearMessages();
    return { outcome: "ok", status: statusOf(r), fields: {} };
  });

  await op("queue-send-update-delete", async () => {
    await queue.sendMessage(`updatable-${runid}`);
    const got = await queue.receiveMessages({ numberOfMessages: 1 });
    const m = (got.receivedMessageItems ?? [])[0];
    if (!m) return { outcome: "ok", status: 200, fields: { flow: "receive-empty" } };
    const upd = await queue.updateMessage(m.messageId, m.popReceipt, `updated-${runid}`, 0);
    const updStatus = statusOf(upd);
    const again = await queue.receiveMessages({ numberOfMessages: 1 });
    const m2 = (again.receivedMessageItems ?? [])[0];
    const del = await queue.deleteMessage(m2?.messageId ?? "", m2?.popReceipt ?? "");
    return {
      outcome: "ok",
      status: 200,
      fields: { updateStatus: updStatus, deleteStatus: statusOf(del), updatedBody: m2?.messageText ?? null },
    };
  });

  await op("queue-list-contains", async () => {
    const names = [];
    for await (const q of svc.listQueues()) names.push(q.name);
    return { outcome: "ok", status: 200, fields: { listed: names.includes(qname) } };
  });

  await op("queue-delete", async () => {
    const r = await queue.delete();
    return { outcome: "ok", status: statusOf(r), fields: {} };
  });

  await op("queue-send-after-delete", async () => {
    try {
      await queue.sendMessage("should-fail");
      return { outcome: "ok", status: 201, fields: { unexpectedlySent: true } };
    } catch (e) {
      return { outcome: "error", status: e?.statusCode ?? 0, code: e?.errorCode ?? e?.code ?? null };
    }
  });

  return { suite: "queue", records: recs };
}
