import { test } from "node:test";
import assert from "node:assert/strict";
import { toCsv } from "../ui-v3/lib/format.ts";
import { withUserNames } from "../ui-v3/lib/user-names.ts";
import type { UserLabel } from "../ui-v3/lib/user-names.ts";

const A = "00000000-0000-4000-8000-0000000000a1", B = "00000000-0000-4000-8000-0000000000b2";

test("developer CSV keeps the object ID and adds display name, UPN and lookup state beside it", async () => {
  const asked: string[] = [];
  const get = async (id: string): Promise<UserLabel> => {
    asked.push(id);
    return id === A ? { objectId: id, state: "resolved", displayName: "Ada, \"Ops\"", userPrincipalName: "ada@contoso.example" }
      : { objectId: id, state: "permission_required", displayName: null, userPrincipalName: null };
  };
  const rows = [{ person: A, knownListUsd: "1.5" }, { person: B, knownListUsd: "2" }, { person: A, knownListUsd: "3" }, { person: null, knownListUsd: "0" }];
  const out = await withUserNames(["person", "knownListUsd"], rows, "person", get);
  assert.deepEqual(out.columns, ["person", "displayName", "userPrincipalName", "nameLookup", "knownListUsd"]);
  assert.deepEqual(asked.sort(), [A, B], "each ID is looked up once");
  assert.deepEqual(out.rows.map((r) => [r.person, r.userPrincipalName, r.nameLookup]),
    [[A, "ada@contoso.example", "resolved"], [B, null, "permission_required"], [A, "ada@contoso.example", "resolved"], [null, null, "no_id"]]);
  const csv = toCsv(out.columns, out.rows, { view: "developers" });
  assert.match(csv, new RegExp(`${A},"Ada, ""Ops""",ada@contoso.example,resolved,1.5`));
  assert.match(csv, new RegExp(`${B},,,permission_required,2`));
});

test("exports without the ID column are unchanged", async () => {
  const rows = [{ group: "g1", knownListUsd: "1" }];
  const out = await withUserNames(["group", "knownListUsd"], rows, "person", async () => { throw new Error("must not look up"); });
  assert.deepEqual(out, { columns: ["group", "knownListUsd"], rows });
});
