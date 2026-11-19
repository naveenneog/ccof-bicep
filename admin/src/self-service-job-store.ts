import type { Container } from "@azure/cosmos";
import type { DurableJob, JobStore, StoredJob } from "./self-service-jobs.ts";

const PARTITION = "admin-operations";
const status = (error: unknown) => Number((error as { code?: unknown })?.code ?? 0);

export function createCosmosJobStore(container: Container): JobStore {
  const document = (job: DurableJob) => ({ ...job, scopeId: PARTITION, recordKind: "adminOperation" });
  const stored = (doc: Record<string, unknown>, etag?: string): StoredJob => {
    const { scopeId: _partition, recordKind: _kind, _etag, _rid: _rid, _self: _self, _attachments: _attachments, _ts: _ts, ...job } = doc;
    return { job: job as unknown as DurableJob, etag: etag ?? String(_etag ?? "") };
  };
  return {
    async probe() {
      const id = "self-service-probe";
      const value = { id, scopeId: PARTITION, recordKind: "adminOperationProbe" };
      for (let attempt = 0; attempt < 3; attempt++) {
        try {
          let etag: string | undefined;
          try {
            const response = await container.item(id, PARTITION).read<{ recordKind: string }>();
            if (response.resource?.recordKind !== value.recordKind) throw new Error("operation_probe_conflict");
            etag = response.etag;
          } catch (error) {
            if (status(error) !== 404) throw error;
            etag = (await container.items.create(value)).etag;
          }
          await container.item(id, PARTITION).replace(value, { accessCondition: { type: "IfMatch", condition: etag ?? "" } });
          await container.items.query({
            query: "SELECT TOP 1 c.id FROM c WHERE c.scopeId = @scope AND c.recordKind = 'adminOperation'",
            parameters: [{ name: "@scope", value: PARTITION }],
          }, { partitionKey: PARTITION }).fetchAll();
          return;
        } catch (error) { if (![409, 412].includes(status(error)) || attempt === 2) throw error; }
      }
    },
    async read(id) {
      try {
        const response = await container.item(id, PARTITION).read<Record<string, unknown>>();
        return response.resource?.recordKind === "adminOperation" ? stored(response.resource, response.etag) : null;
      } catch (error) { if (status(error) === 404) return null; throw error; }
    },
    async create(job) {
      try { await container.items.create(document(job)); return true; } catch (error) {
        if (status(error) === 409) return false;
        throw error;
      }
    },
    async replace(job, etag) {
      try {
        const response = await container.item(job.id, PARTITION).replace(document(job), { accessCondition: { type: "IfMatch", condition: etag } });
        return response.etag ?? null;
      } catch (error) { if ([404, 412].includes(status(error))) return null; throw error; }
    },
    async runnable(now, limit) {
      const { resources } = await container.items.query<Record<string, unknown>>({
        query: "SELECT TOP @limit * FROM c WHERE c.scopeId = @scope AND c.recordKind = 'adminOperation' AND (c.state = 'queued' OR c.state = 'running') AND c.nextAt <= @now AND (IS_NULL(c.leaseUntil) OR c.leaseUntil <= @now) ORDER BY c.createdAt",
        parameters: [{ name: "@limit", value: limit }, { name: "@scope", value: PARTITION }, { name: "@now", value: now }],
      }, { partitionKey: PARTITION }).fetchAll();
      return resources.map((doc) => stored(doc));
    },
    async lock(projectId, owner, now, until) {
      const id = `project-lock:${projectId}`;
      const value = { id, scopeId: PARTITION, recordKind: "adminOperationLease", owner, until };
      try {
        const response = await container.item(id, PARTITION).read<{ owner: string; until: string }>();
        if (!response.resource || response.resource.until > now) return false;
        await container.item(id, PARTITION).replace(value, { accessCondition: { type: "IfMatch", condition: response.etag ?? "" } });
        return true;
      } catch (error) {
        if (status(error) === 404) {
          try { await container.items.create(value); return true; } catch (createError) { if (status(createError) === 409) return false; throw createError; }
        }
        if (status(error) === 412) return false;
        throw error;
      }
    },
    async unlock(projectId, owner) {
      const id = `project-lock:${projectId}`;
      const response = await container.item(id, PARTITION).read<{ owner: string }>();
      if (response.resource?.owner !== owner) return;
      try {
        await container.item(id, PARTITION).replace({ id, scopeId: PARTITION, recordKind: "adminOperationLease", owner: null, until: "1970-01-01T00:00:00.000Z" },
          { accessCondition: { type: "IfMatch", condition: response.etag ?? "" } });
      } catch (error) { if (![404, 412].includes(status(error))) throw error; }
    },
  };
}
