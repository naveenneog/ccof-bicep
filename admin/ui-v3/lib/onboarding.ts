// ADR 0040: client-side rules for the backend onboarding wizard. The server re-validates everything;
// these only stop a request that is certain to be refused and pre-fill the backend ID.

export interface OnboardingDraft { foundryResourceId: string; backendId: string; displayName: string; deployments: string; inferenceGeo: string }
export interface OnboardingScope { resourceIds: string[]; discoveryScopes: string[] }

const ACCOUNT_ID = /^\/subscriptions\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/resourceGroups\/[^/]+\/providers\/Microsoft\.CognitiveServices\/accounts\/([A-Za-z0-9-]{2,64})$/i;
const BACKEND_ID = /^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/;
const GEOS = ["global", "us", "eu"];
const csv = (v: string) => v.split(",").map((s) => s.trim()).filter(Boolean);
const lower = (s: string) => s.toLowerCase();

export function suggestBackendId(accountId: string): string {
  const m = ACCOUNT_ID.exec(accountId.trim());
  return m ? lower(m[1]).replace(/^ccof-/, "").slice(0, 80) : "";
}

export function inScope(accountId: string, scope: OnboardingScope): boolean {
  const id = lower(accountId);
  return scope.resourceIds.some((r) => lower(r) === id)
    || scope.discoveryScopes.some((s) => id.startsWith(`${lower(s).replace(/\/+$/, "")}/`));
}

export function onboardingProblems(d: OnboardingDraft, scope: OnboardingScope): Record<string, string> {
  const out: Record<string, string> = {};
  if (!ACCOUNT_ID.test(d.foundryResourceId)) out.foundryResourceId = "The account's full resource ID: /subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<name>.";
  else if (!inScope(d.foundryResourceId, scope)) out.foundryResourceId = "Outside the accounts this console may onboard (ADMIN_RESOURCE_IDS or ADMIN_DISCOVERY_SCOPES).";
  if (!BACKEND_ID.test(d.backendId) || lower(d.backendId).startsWith("ccof-")) out.backendId = "Letters, digits, - and _, up to 80; not starting with ccof-.";
  if (d.displayName.trim().length > 120) out.displayName = "Up to 120 characters.";
  if (!GEOS.includes(d.inferenceGeo)) out.inferenceGeo = "global, us or eu.";
  return out;
}

export function onboardingBody(d: OnboardingDraft): Record<string, unknown> {
  const body: Record<string, unknown> = { backendId: d.backendId, foundryResourceId: d.foundryResourceId.trim(), inferenceGeo: d.inferenceGeo };
  if (d.displayName.trim()) body.displayName = d.displayName.trim();
  const deployments = csv(d.deployments);
  if (deployments.length) body.deployments = deployments;
  return body;
}
