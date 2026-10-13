import { fields, positiveInteger, text } from "./rate-card.ts";

export interface WorkbookAnswers {
  schemaVersion: 1;
  subscriptionId: string;
  tenantId: string;
  resourceGroupName: string;
  location: string;
  deploymentName: string;
  workbookResourceName: string;
  workbookDisplayName: string;
  workspaceResourceId: string;
  gatewayResourceId: string;
  reconcilerResourceId: string;
  rateCardPath: string;
  ledgerPath: string;
  outputDirectory: string;
  defaultProjectId: string;
  maxRows: number;
  topUsers: number;
  maxQueryDays: number;
  budgetLookbackDays: number;
  retentionDays: number;
}

const required = [
  "schemaVersion", "subscriptionId", "tenantId", "resourceGroupName", "location", "deploymentName",
  "workbookResourceName", "workbookDisplayName", "workspaceResourceId", "gatewayResourceId",
  "reconcilerResourceId", "rateCardPath", "ledgerPath", "outputDirectory", "defaultProjectId",
  "maxRows", "topUsers", "maxQueryDays", "budgetLookbackDays", "retentionDays",
];
const guid = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const name = "[a-z0-9][a-z0-9._-]*";

// The report settings an administrator answers; WP-CORE's answers file carries them as workbook.settings.
// retentionDays is not one of them: it is the workspace's retention (WP-CORE availability.telemetry).
export const workbookSettingKeys = ["defaultProjectId", "maxRows", "topUsers", "maxQueryDays", "budgetLookbackDays"] as const;
type WorkbookSettings = Pick<WorkbookAnswers, typeof workbookSettingKeys[number]>;

export function validateWorkbookSettings(value: unknown): WorkbookSettings {
  const settings = fields(value, "settings", [...workbookSettingKeys]);
  text(settings.defaultProjectId, "defaultProjectId");
  for (const key of ["maxRows", "topUsers", "maxQueryDays", "budgetLookbackDays"]) positiveInteger(settings[key], key);
  if ((settings.topUsers as number) > (settings.maxRows as number)) throw new Error("topUsers: exceeds_maxRows");
  // Month and previous-month periods are checked against maxQueryDays too; a calendar month must fit.
  if ((settings.maxQueryDays as number) < 31) throw new Error("maxQueryDays: must_cover_a_calendar_month");
  return { ...settings } as unknown as WorkbookSettings;
}

export function validateAnswers(value: unknown): WorkbookAnswers {
  const answers = fields(value, "answers", required);
  if (answers.schemaVersion !== 1) throw new Error("schemaVersion: must_be_1");
  const settingKeys: readonly string[] = workbookSettingKeys;
  for (const key of required.filter(key => key !== "schemaVersion" && key !== "retentionDays" && !settingKeys.includes(key))) {
    text(answers[key], key);
  }
  const check = (key: string, pattern: RegExp) => {
    if (!pattern.test(answers[key] as string)) throw new Error(`${key}: invalid_format`);
  };
  for (const key of ["subscriptionId", "tenantId", "workbookResourceName"]) check(key, new RegExp(`^${guid}$`, "i"));
  for (const key of ["resourceGroupName", "deploymentName"]) check(key, new RegExp(`^${name}$`, "i"));
  check("location", /^[a-z][a-z0-9]+$/);
  const providers = {
    workspaceResourceId: "Microsoft\\.OperationalInsights/workspaces",
    gatewayResourceId: "Microsoft\\.ApiManagement/service",
    reconcilerResourceId: "Microsoft\\.Web/sites",
  };
  for (const [key, provider] of Object.entries(providers)) {
    check(key, new RegExp(`^/subscriptions/${guid}/resourceGroups/${name}/providers/${provider}/${name}$`, "i"));
  }
  for (const key of ["rateCardPath", "ledgerPath"]) {
    // Two leading separators in any mix (\\, //, \/, /\) open UNC or device paths on Windows.
    if (/^(?:[\\/]{2}|[a-z][a-z0-9+.-]*:[\\/]{2})/i.test(answers[key] as string)) throw new Error(`${key}: local_file_required`);
  }
  check("outputDirectory", /^\.env\.[a-z0-9][a-z0-9._-]*$/i);
  validateWorkbookSettings(Object.fromEntries(workbookSettingKeys.map(key => [key, answers[key]])));
  positiveInteger(answers.retentionDays, "retentionDays");
  return { ...answers } as unknown as WorkbookAnswers;
}
