import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

// WP-COST's static pilot card, copied byte for byte: origin/wp/cost bd134a3, config/rate-card.json.
export const pilotRateCardGitBlob = "05dad0466adb2a112d291ea257f7063bc068ff6e";

export function pilotRateCardText(): string {
  return readFileSync(new URL("../fixtures/workbook/pilot-rate-card.json", import.meta.url), "utf8").replace(/\r\n/g, "\n");
}

export function gitBlobId(text: string): string {
  const bytes = Buffer.from(text, "utf8");
  return createHash("sha1").update(`blob ${bytes.length}\0`).update(bytes).digest("hex");
}

export function workbookRateCard() {
  return {
    schemaVersion: 1,
    version: "fixture-2026-10",
    rateUnit: {
      currency: "USD", perTokens: 1000,
      source: { url: "https://example.invalid/pricing", retrieved: "2026-10-01" },
    },
    entries: [
      {
        model: "model-a", effectiveFrom: "2026-10-01T00:00:00Z", effectiveTo: null,
        source: { url: "https://example.invalid/model-a", retrieved: "2026-10-01" },
        inferenceGeoMultipliers: { global: "1", us: "1.1" },
        promptTiers: [{ rates: { input: "2", output: "10", cacheWrite5m: "2.5", cacheWrite1h: "4", cacheRead: "0.2" } }],
      },
      {
        model: "model-b", effectiveFrom: "2026-10-01T00:00:00Z", effectiveTo: null,
        source: { url: "https://example.invalid/model-b", retrieved: "2026-10-02" },
        inferenceGeoMultipliers: { global: "1" },
        promptTokensCountedCategories: ["input", "cacheWrite5m", "cacheWrite1h", "cacheRead"],
        promptTiers: [
          { promptTokensUpTo: 100, rates: { input: "1", output: "5", cacheWrite5m: "1.25", cacheWrite1h: "2", cacheRead: "0.1" } },
          { promptTokensOver: 100, rates: { input: "2", output: "10", cacheWrite5m: "2.5", cacheWrite1h: "4", cacheRead: "0.2" } },
        ],
      },
    ],
  };
}

export function workbookAnswers() {
  const subscriptionId = "11111111-1111-4111-8111-111111111111";
  const scope = `/subscriptions/${subscriptionId}/resourceGroups/fixture-rg/providers`;
  return {
    schemaVersion: 1,
    subscriptionId,
    tenantId: "22222222-2222-4222-8222-222222222222",
    resourceGroupName: "fixture-rg",
    location: "eastus2",
    deploymentName: "fixture-workbook-deployment",
    workbookResourceName: "33333333-3333-4333-8333-333333333333",
    workbookDisplayName: "Fixture chargeback",
    workspaceResourceId: `${scope}/Microsoft.OperationalInsights/workspaces/fixture-law`,
    gatewayResourceId: `${scope}/Microsoft.ApiManagement/service/fixture-apim`,
    reconcilerResourceId: `${scope}/Microsoft.Web/sites/fixture-reconciler`,
    rateCardPath: "fixture-rate-card.json",
    ledgerPath: "fixture-ledger.kql",
    outputDirectory: ".env.workbook-fixture",
    defaultProjectId: "*",
    maxRows: 500,
    topUsers: 20,
    maxQueryDays: 62,
    budgetLookbackDays: 31,
    retentionDays: 35,
  };
}
