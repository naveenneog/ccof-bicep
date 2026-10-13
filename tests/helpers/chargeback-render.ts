import { readFileSync, writeFileSync } from "node:fs";
import { buildChargebackWorkbook } from "../../analytics/workbooks/chargeback.ts";
import { renderQuery } from "../../analytics/workbooks/render.ts";
import { workbookAnswers } from "./workbook-fixtures.ts";

const root = new URL("../../", import.meta.url);
const built = buildChargebackWorkbook(workbookAnswers(),
  readFileSync(new URL("config/rate-card.json", root), "utf8"),
  readFileSync(new URL("analytics/ledger.kql", root), "utf8"),
  [{ projectId: "SYNTHETIC", classification: "STD", groupId: "44444444-4444-4444-8444-444444444444",
    displayName: `  Synthetic & R&D <"One"> / O'Brien \\ Ω  ` }]);
const queries = Object.fromEntries(Object.entries(built.queries).map(([name, query]) =>
  [name, renderQuery(query, { period: "month", project: "*", from: null, to: null })
    .replaceAll("{Group:base64}", "Kg==").replaceAll("{Developer:base64}", "Kg==").replaceAll("{Model:base64}", "Kg==")]));
writeFileSync(process.argv[2], JSON.stringify(queries));
