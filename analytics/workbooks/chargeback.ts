import { createHash } from "node:crypto";
import { readFileSync, mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { buildWorkbook } from "./build.ts";
import { validateAnswers } from "./config.ts";
import { compileRateCard, fields } from "./rate-card.ts";
import { chargebackQueries, reportingRateCard, reportRollup } from "./chargeback-queries.ts";
import type { GroupMetadata } from "./chargeback-queries.ts";
import { chargebackLayout } from "./chargeback-layout.ts";
import { isMain } from "./main.ts";

export type { GroupMetadata };

export function validateGroups(value: unknown): GroupMetadata[] {
  if (!Array.isArray(value)) throw new Error("groups: array_required");
  const seen = new Set<string>();
  return value.map(raw => {
    const group = fields(raw, "group", ["projectId", "classification", "groupId", "displayName"]);
    for (const key of ["projectId", "classification"]) {
      if (typeof group[key] !== "string" || !/^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/.test(group[key] as string)) {
        throw new Error(`group.${key}: identifier_required`);
      }
    }
    if (typeof group.groupId !== "string" || !/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(group.groupId)) {
      throw new Error("group.groupId: object_id_required");
    }
    // Graph displayName is data, not code: do not trim, case-fold or strip punctuation.
    if (group.displayName !== null && (typeof group.displayName !== "string" || !group.displayName.length || group.displayName.length > 256)) {
      throw new Error("group.displayName: exact_graph_string_or_null_required");
    }
    const key = `${group.projectId}:${group.classification}`;
    if (seen.has(key)) throw new Error("group: duplicate_project_classification");
    seen.add(key);
    return group as unknown as GroupMetadata;
  });
}

// The report rollup lives in the shared builder; re-exported for existing callers.
export { reportRollup };

export function buildChargebackWorkbook(rawAnswers: unknown, rawCard: unknown, ledger: string, rawGroups: unknown) {
  const answers = validateAnswers(rawAnswers);
  const groups = validateGroups(rawGroups);
  const cardObject = typeof rawCard === "string" ? JSON.parse(rawCard) : rawCard;
  const card = reportingRateCard(cardObject);
  const rateCard = compileRateCard(card);
  const legacy = buildWorkbook(answers, card, ledger);
  const queries = chargebackQueries(legacy, answers.maxRows, groups);
  const workbook = chargebackLayout(answers, rateCard, queries);
  const hash = (s: string) => createHash("sha256").update(s).digest("hex");
  const contentSha256 = hash(JSON.stringify(workbook));
  const parameters = { ...legacy.parameters, workbookContent: { value: workbook },
    contentTags: { value: { ...legacy.parameters.contentTags.value, "ccof-content": contentSha256,
      "ccof-groups": hash(JSON.stringify(groups)), "ccof-report": "fixed-price-v1" } } };
  return { groups, rateCard, queries, workbook, parameters, contentSha256 };
}
export function verifyChargebackArtifact(raw: unknown): string {
  const artifact = raw as { parameters?: { workbookContent?: { value?: { version?: string; items?: unknown[] } };
    contentTags?: { value?: Record<string, string> } } };
  const content = artifact?.parameters?.workbookContent?.value;
  const tags = artifact?.parameters?.contentTags?.value;
  if (content?.version !== "Notebook/1.0" || !Array.isArray(content.items) || content.items.length < 10
    || tags?.["ccof-report"] !== "fixed-price-v1") throw new Error("workbook_content_required");
  const digest = createHash("sha256").update(JSON.stringify(content)).digest("hex");
  if (tags["ccof-content"] !== digest) throw new Error("content_digest_mismatch");
  return digest;
}

export function generateChargebackFiles(answersPath: string, groupsPath: string) {
  const answers = validateAnswers(JSON.parse(readFileSync(answersPath, "utf8")));
  const artifact = buildChargebackWorkbook(answers, readFileSync(answers.rateCardPath, "utf8"),
    readFileSync(answers.ledgerPath, "utf8"), JSON.parse(readFileSync(groupsPath, "utf8")));
  mkdirSync(answers.outputDirectory, { recursive: true });
  writeFileSync(path.join(answers.outputDirectory, "workbook.json"), JSON.stringify(artifact.workbook, null, 2) + "\n");
  writeFileSync(path.join(answers.outputDirectory, "parameters.json"), JSON.stringify({
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    contentVersion: "1.0.0.0", parameters: artifact.parameters,
  }, null, 2) + "\n");
  return { contentSha256: artifact.contentSha256 };
}

export function reportingInputDiagnostic(error: unknown): { field?: string; detail?: string } {
  if (error instanceof SyntaxError) return { detail: "json_invalid" };
  if (error instanceof Error && "code" in error && error.code === "ENOENT") return { detail: "local_input_file_missing" };
  const message = error instanceof Error ? error.message : "";
  const match = /^(schemaVersion|subscriptionId|tenantId|resourceGroupName|location|deploymentName|workbookResourceName|workbookDisplayName|workspaceResourceId|gatewayResourceIds|gatewayResourceId|reconcilerResourceId|rateCardPath|ledgerPath|outputDirectory|defaultProjectId|maxRows|topUsers|maxQueryDays|budgetLookbackDays|retentionDays|groups|group\.(?:projectId|classification|groupId|displayName)): ([a-z_]+)$/.exec(message);
  return match ? { field: match[1], detail: match[2] } : {};
}

if (isMain(import.meta.url)) {
  try {
    if (process.argv[2] === "--verify" && process.argv.length === 4) {
      console.log(JSON.stringify({ schema: "ccof.chargeback.build.v1", outcome: "validated",
        contentSha256: verifyChargebackArtifact(JSON.parse(readFileSync(process.argv[3], "utf8"))) }));
    } else {
      const [flag, answers, groupFlag, groups, ...extra] = process.argv.slice(2);
      if (flag !== "--answers" || !answers || groupFlag !== "--groups" || !groups || extra.length) throw new Error("use --answers PATH --groups PATH");
      console.log(JSON.stringify({ schema: "ccof.chargeback.build.v1", outcome: "validated", ...generateChargebackFiles(answers, groups) }));
    }
  } catch (error) {
    console.error(JSON.stringify({ schema: "ccof.chargeback.build.v1", outcome: "refused",
      reason: "reporting_input_invalid", ...reportingInputDiagnostic(error) }));
    process.exitCode = 1;
  }
}
