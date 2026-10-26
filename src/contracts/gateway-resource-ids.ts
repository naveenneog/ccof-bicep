// The APIM gateways whose logs make up one deployment's usage ledger. Active/passive DR
// (docs/DR-ACTIVE-PASSIVE.md, ADR 0033) has two APIM instances, and one calendar month can hold
// traffic from both, so the ledger, workbook and admin queries take a list. The list reaches KQL as
// one comma-separated string literal: no accepted entry may contain a comma, quote or backslash.

export const MAX_GATEWAY_RESOURCE_IDS = 4;

export type GatewayListProblem = "invalid" | "too_many" | "duplicate";

// A comma-separated setting value; entries are trimmed, and an empty entry stays (it is invalid).
export function splitGatewayList(value: string): string[] {
  return value.split(",").map((entry) => entry.trim());
}

export function gatewayListProblem(ids: readonly string[], pattern: RegExp): GatewayListProblem | undefined {
  if (ids.length === 0 || ids.some((id) => !pattern.test(id) || /[,'"\\]/.test(id))) return "invalid";
  if (ids.length > MAX_GATEWAY_RESOURCE_IDS) return "too_many";
  if (new Set(ids.map((id) => id.toLowerCase())).size !== ids.length) return "duplicate";
  return undefined;
}

export function includesGateway(ids: readonly string[], id: string): boolean {
  return ids.some((entry) => entry.toLowerCase() === id.toLowerCase());
}
