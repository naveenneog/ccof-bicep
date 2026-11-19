import type { Doc } from "./validation.ts";

export interface PermissionRequirement { action: string; scope: string }
export interface FeatureCapability {
  state: "available" | "disabled" | "permission_required" | "unavailable";
  reason?: string;
  requirements: PermissionRequirement[];
}
export interface OperationJob {
  id: string;
  kind: "publish-routing" | "apply";
  projectId: string;
  expectedEtag: string;
  actorOid: string;
  createdAt: string;
  reason: string;
  checkpoint: Doc;
}
export interface OperationStep {
  state: "running" | "succeeded" | "blocked" | "failed";
  phase: string;
  checkpoint?: Doc;
  result?: Doc;
  reason?: string;
  requirements?: PermissionRequirement[];
}
