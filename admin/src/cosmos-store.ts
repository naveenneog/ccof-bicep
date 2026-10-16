// The real ProjectStore: the `projects` container (partition key /projectId) through @azure/cosmos with
// the admin app's own managed identity. create never upserts; replace always carries If-Match.

import { CosmosClient } from "@azure/cosmos";
import type { Container } from "@azure/cosmos";
import type { TokenCredential } from "@azure/identity";
import type { ProjectStore } from "./api.ts";
import type { Doc } from "./validation.ts";

function statusOf(err: unknown): number | undefined {
  if (typeof err !== "object" || err === null) return undefined;
  const e = err as { code?: unknown; statusCode?: unknown };
  const value = typeof e.code === "number" ? e.code : e.statusCode;
  return typeof value === "number" ? value : undefined;
}

export interface CosmosSettings {
  endpoint: string;
  database: string;
  container: string;
}

export function readCosmosSettings(env: Readonly<Record<string, string | undefined>>): CosmosSettings | null {
  const endpoint = env.COSMOS_ENDPOINT?.trim();
  const database = env.COSMOS_DATABASE?.trim();
  const container = env.ADMIN_PROJECTS_CONTAINER?.trim() || "projects";
  if (!endpoint || !/^https:\/\/[a-z0-9-]+\.documents\.azure\.com(:443)?\/?$/.test(endpoint) || !database) return null;
  return { endpoint, database, container };
}

export function openContainer(settings: CosmosSettings, credential: TokenCredential): Container {
  return new CosmosClient({ endpoint: settings.endpoint, aadCredentials: credential }).database(settings.database).container(settings.container);
}

export function createCosmosProjectStore(container: Container): ProjectStore {
  return {
    async list() {
      const { resources } = await container.items.query<Doc>("SELECT * FROM c").fetchAll();
      return resources.map((doc) => ({ doc, etag: String(doc._etag ?? "") }));
    },
    async read(projectId) {
      try {
        const response = await container.item(projectId, projectId).read<Doc>();
        if (!response.resource) return null;
        return { doc: response.resource, etag: response.etag ?? String(response.resource._etag ?? "") };
      } catch (err) {
        if (statusOf(err) === 404) return null;
        throw err;
      }
    },
    async create(doc) {
      try {
        const response = await container.items.create(doc);
        return response.etag ?? "";
      } catch (err) {
        if (statusOf(err) === 409) return "conflict";
        throw err;
      }
    },
    async replace(doc, etag) {
      try {
        const id = String(doc.projectId);
        const response = await container.item(id, id).replace(doc, { accessCondition: { type: "IfMatch", condition: etag } });
        return response.etag ?? "";
      } catch (err) {
        const status = statusOf(err);
        if (status === 412 || status === 404) return "precondition_failed";
        throw err;
      }
    },
  };
}

// Health probe: one point read of a non-existent item. 404 proves network reach and data-plane read
// access; a 403 is classified by Cosmos's message without echoing it (it can contain the caller's IP).
export async function probeCosmos(container: Container): Promise<string> {
  try {
    await container.item("__ccof_admin_probe__", "__ccof_admin_probe__").read();
    return "ok";
  } catch (err) {
    const status = statusOf(err);
    if (status === 404) return "ok";
    const message = String((err as { message?: unknown })?.message ?? "");
    if (status === 403 && /public internet|firewall|virtual network|private endpoint/i.test(message)) return "blocked_by_network";
    if (status === 403) return "forbidden_data_role";
    if (status === 401) return "unauthorized";
    return status ? `error_${status}` : "unreachable";
  }
}
