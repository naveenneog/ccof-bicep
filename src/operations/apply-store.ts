import type { Container } from "@azure/cosmos";
import { heartbeatId, requestId, sameRequest } from "./apply-contracts.ts";
import type { ApplyHeartbeat, ApplyReceipt, ApplyRequest, ApplyStore, ProcessingLease } from "./apply-contracts.ts";

export const APPLY_PARTITION = "admin-apply";
const status = (error: unknown) => Number((error as { code?: unknown; statusCode?: unknown })?.code ?? (error as { statusCode?: unknown })?.statusCode);
const receiptId = (request: ApplyRequest) => requestId(request).replace("request", "receipt");
const claimId = (request: ApplyRequest) => requestId(request).replace("request", "claim");
type Document = Record<string, unknown> & { id: string; _etag?: string };

export function createCosmosApplyStore(container: Container): ApplyStore {
  const document = (id: string, recordKind: string, value: object) => ({ ...value, id, scopeId: APPLY_PARTITION, recordKind });
  async function read(id: string): Promise<{ doc: Document; etag: string } | null> {
    try {
      const response = await container.item(id, APPLY_PARTITION).read<Document>();
      return response.resource ? { doc: response.resource, etag: response.etag ?? response.resource._etag ?? "" } : null;
    } catch (error) { if (status(error) === 404) return null; throw error; }
  }
  async function create(id: string, kind: string, value: object): Promise<"created" | "existing"> {
    try { await container.items.create(document(id, kind, value)); return "created"; }
    catch (error) { if (status(error) === 409) return "existing"; throw error; }
  }
  async function receipt(request: ApplyRequest): Promise<ApplyReceipt | null> {
    const result = await read(receiptId(request));
    if (!result) return null;
    if (result.doc.recordKind !== "applyReceipt" || !sameRequest(result.doc as unknown as ApplyRequest, request)) throw new Error("apply_correlation_invalid");
    return result.doc as unknown as ApplyReceipt;
  }
  const until = (request: ApplyRequest, now: Date) => new Date(Math.min(now.getTime() + 300_000, Date.parse(request.expiresAt))).toISOString();
  return {
    async heartbeat(value) {
      const id = heartbeatId(value.resourceId);
      for (let attempt = 0; attempt < 3; attempt++) {
        const previous = await read(id);
        if (!previous) { if (await create(id, "applyHeartbeat", value) === "created") return; continue; }
        if (previous.doc.recordKind !== "applyHeartbeat") throw new Error("apply_heartbeat_conflict");
        try {
          await container.item(id, APPLY_PARTITION).replace(document(id, "applyHeartbeat", value), { accessCondition: { type: "IfMatch", condition: previous.etag } });
          return;
        } catch (error) { if (status(error) !== 412 || attempt === 2) throw error; }
      }
      throw new Error("apply_heartbeat_conflict");
    },
    async heartbeats(pairs) {
      return Promise.all(pairs.flatMap((pair) => [pair.syncResourceId, pair.reconcilerResourceId]).map(async (target) => {
        const result = await read(heartbeatId(target));
        return result?.doc.recordKind === "applyHeartbeat" ? result.doc as unknown as ApplyHeartbeat : null;
      }));
    },
    async enqueue(request) {
      const result = await create(requestId(request), "applyRequest", request);
      if (result === "existing") {
        const previous = await read(requestId(request));
        if (previous?.doc.recordKind !== "applyRequest" || !sameRequest(previous.doc as unknown as ApplyRequest, request)) throw new Error("apply_request_conflict");
      }
      return result;
    },
    async readRequest(jobId, phase) {
      const current = await read(requestId({ jobId, phase }));
      return current?.doc.recordKind === "applyRequest" ? current.doc as unknown as ApplyRequest : null;
    },
    readReceipt: receipt,
    async pending(target, now) {
      const { resources } = await container.items.query<Document>({
        query: "SELECT * FROM c WHERE c.scopeId = @scope AND c.recordKind = 'applyRequest' AND c.resourceId = @target AND c.expiresAt > @now",
        parameters: [{ name: "@scope", value: APPLY_PARTITION }, { name: "@target", value: target }, { name: "@now", value: now.toISOString() }],
      }, { partitionKey: APPLY_PARTITION }).fetchAll();
      if (resources.length > 1000) throw new Error("apply_request_backlog");
      return (resources as unknown as ApplyRequest[]).sort((a, b) => a.requestedAt.localeCompare(b.requestedAt));
    },
    async claim(request, owner, now) {
      if (await receipt(request)) return "finished";
      const id = claimId(request);
      const result = await create(id, "applyClaim", { ...request, owner, until: until(request, now), startedAt: now.toISOString() });
      const current = await read(id);
      if (!current || current.doc.recordKind !== "applyClaim" || !sameRequest(current.doc as unknown as ApplyRequest, request)) throw new Error("apply_claim_invalid");
      if (result === "created") return { id, owner, etag: current.etag, until: String(current.doc.until) };
      if (String(current.doc.until) > now.toISOString()) return "busy";
      // An expired processing lease is ambiguous, not permission to repeat business writes.
      await create(receiptId(request), "applyReceipt", {
        ...request, state: "failed", startedAt: current.doc.startedAt, finishedAt: now.toISOString(),
        reason: "runtime_completion_unknown", guarded: true,
      });
      return "finished";
    },
    async renew(request, lease, now) {
      if (lease.until <= now.toISOString()) return false;
      const current = await read(lease.id);
      if (!current || current.etag !== lease.etag || current.doc.owner !== lease.owner) return false;
      try {
        const nextUntil = until(request, now);
        const response = await container.item(lease.id, APPLY_PARTITION).replace(
          document(lease.id, "applyClaim", { ...current.doc, until: nextUntil }), { accessCondition: { type: "IfMatch", condition: lease.etag } });
        lease.etag = response.etag ?? ""; lease.until = nextUntil;
        return !!lease.etag;
      } catch (error) { if ([404, 412].includes(status(error))) return false; throw error; }
    },
    async complete(request, lease: ProcessingLease, value, now) {
      if (!sameRequest(request, value) || lease.until <= now.toISOString()) throw new Error("apply_claim_lost");
      const current = await read(lease.id);
      if (!current || current.etag !== lease.etag || current.doc.owner !== lease.owner) throw new Error("apply_claim_lost");
      await create(receiptId(request), "applyReceipt", value);
      // The immutable receipt is authoritative even if this best-effort processing-lease close loses a race.
      try {
        await container.item(lease.id, APPLY_PARTITION).replace(
          document(lease.id, "applyClaim", { ...current.doc, completedAt: now.toISOString() }),
          { accessCondition: { type: "IfMatch", condition: lease.etag } });
      } catch (error) { if (![404, 412].includes(status(error))) throw error; }
    },
  };
}
