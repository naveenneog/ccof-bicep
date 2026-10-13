import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { test } from "node:test";

import { attr, descendants, parseApimXml } from "../infra/gateway/apim-xml.ts";
import type { GatewayConfig } from "../infra/gateway/config.ts";
import { renderPolicy } from "../infra/gateway/render.ts";
import { sampleConfig } from "./helpers/gateway-fixtures.ts";

const xml = renderPolicy(sampleConfig() as GatewayConfig).policyXml;
const root = parseApimXml(xml);
const all = descendants(root);
const variables = (name: string) => all.filter((e) => e.name === "set-variable" && attr(e, "name") === name);
function expression(name: string, index = 0): string {
  const element = variables(name)[index];
  assert.ok(element, `missing policy expression ${name}`);
  return attr(element, "value")!;
}
const limits = all.filter((e) => e.name === "llm-token-limit");
const limit = (id: string) => {
  const found = limits.find((e) => attr(e, "id") === id);
  assert.ok(found, `missing token policy ${id}`);
  return found;
};

test("v3/d3 isolates legacy decisions and validates cached allows before fresh or LKG use", () => {
  assert.match(expression("ccofCacheKey"), /ccof-ent:d3:v3:/);
  assert.doesNotMatch(xml, /ccof-ent:d[12]:/);
  assert.match(expression("ccofCachedDecisionValid"), /decisionVersion/);
  assert.match(expression("ccofCacheState", 1), /ccofCachedDecisionValid/);
  assert.match(expression("ccofResolverResult"), /decisionVersion/);
  const checks = (source: string, end: string) => source
    .slice(source.indexOf('var groupId = body["classificationGroupId"];'), source.indexOf(end))
    .replaceAll("return false;", "return unavailable;").replace(/\s+/g, " ").trim();
  assert.equal(checks(expression("ccofCachedDecisionValid"), "return true;"),
    checks(expression("ccofResolverResult"), 'decision["decisionVersion"] = 3;'),
    "cached and live v3 family validation must not diverge");
});

test("aggregate limits run unchanged before admitted family group/person ceilings without header collisions", () => {
  assert.deepEqual(limits.map((e) => attr(e, "id")), [
    "ccof-limit-group-rate-quota", "ccof-limit-group-rate", "ccof-limit-group-quota",
    "ccof-limit-person-rate-quota", "ccof-limit-person-rate", "ccof-limit-person-quota",
    "ccof-limit-family-group-rate-quota", "ccof-limit-family-group-rate", "ccof-limit-family-group-quota",
    "ccof-limit-family-person-rate-quota", "ccof-limit-family-person-rate", "ccof-limit-family-person-quota",
  ]);
  for (const scope of ["Group", "Person"]) {
    assert.match(expression(`ccof${scope}Tpm`), /aggregateLimits/);
    for (const mode of ["rate-quota", "rate", "quota"]) {
      const family = limit(`ccof-limit-family-${scope.toLowerCase()}-${mode}`);
      const key = attr(family, "counter-key")!;
      assert.match(key, /ccofModelFamily/);
      assert.doesNotMatch(key, /ccofModel"\]/, "versions must share counters");
      assert.match(key, scope === "Group" ? /gf:.*ccofClassificationGroupId/ : /pf:.*ccofOid/);
      for (const header of ["tokens-consumed-header-name", "remaining-tokens-header-name", "remaining-quota-tokens-header-name"]) {
        assert.equal(attr(family, header), undefined, "family accounting must not overwrite aggregate headers");
      }
      if (mode !== "quota") assert.equal(attr(family, "tokens-per-minute"), `@((int)context.Variables["ccofFamily${scope}Tpm"])`);
      if (mode !== "rate") {
        assert.equal(attr(family, "token-quota"), `@((long)context.Variables["ccofFamily${scope}Quota"])`);
        assert.equal(attr(family, "token-quota-period"), `@((string)context.Variables["ccofFamily${scope}Period"])`);
      }
    }
  }
  assert.ok(all.indexOf(variables("ccofModelFamily")[1]) < all.indexOf(limits[0]), "admission precedes every counter");
  for (const scope of ["group", "person"]) {
    for (const mode of ["rate", "quota"]) {
      assert.match(expression("ccofErrorBody"), new RegExp(`case "family_${scope}_${mode}_exceeded":`));
    }
  }
});

test("usage telemetry carries trusted family/group ID without introducing a streamed body read", () => {
  const trace = expression("ccofUsageTrace");
  assert.match(trace, /new JProperty\("modelFamily",/);
  assert.match(trace, /new JProperty\("classificationGroupId",/);
  assert.match(trace, /ccofModelFamily/);
  assert.match(trace, /ccofClassificationGroupId/);
  assert.match(trace, /new JProperty\("classificationGroupDisplayName",/);
  assert.doesNotMatch(trace, /context\.(Request|Response)\.Body/);
  assert.equal([...xml.matchAll(/context\.Response\.Body/g)].length, 1, "existing non-streamed reader only");
});

interface Vector {
  label: string;
  method: string;
  vars?: Record<string, unknown>;
  status?: number;
  policyId?: string;
  reason?: string;
  expected: unknown;
  json?: boolean;
  property?: string;
}

// Compile and execute the actual rendered C# expressions, not a TypeScript imitation.
// PowerShell 7 and its Newtonsoft assembly are already required by the repository.
function runExpressions(methods: Record<string, string>, vectors: Vector[]): unknown[] {
  const bodies = Object.entries(methods).map(([name, source]) => {
    const body = source.startsWith("@{") ? source.slice(2, -1) : `return ${source.slice(2, -1)};`;
    return `public static object ${name}(Context context) { ${body} }`;
  }).join("\n");
  const source = `
using System;
using System.Collections.Generic;
using Newtonsoft.Json.Linq;
public class Bag : Dictionary<string, object> {
  public T GetValueOrDefault<T>(string key, T fallback) { return ContainsKey(key) ? (T)this[key] : fallback; }
}
public class Body { public string Text; public T As<T>() { return (T)(object)JObject.Parse(Text); } }
public interface IResponse { int StatusCode { get; } Body Body { get; } }
public class Response : IResponse { public int StatusCode { get; set; } public Body Body { get; set; } }
public class Error { public string Source = ""; public string PolicyId = ""; public string Reason = ""; }
public class Context {
  public Bag Variables = new Bag();
  public Response Response = new Response();
  public Error LastError = new Error();
  public Guid RequestId = Guid.Parse("00000000-0000-0000-0000-000000000001");
}
public static class PolicyExpressions { ${bodies} }`;
  const script = `
$ErrorActionPreference = 'Stop'
$inputJson = [Console]::In.ReadToEnd() | ConvertFrom-Json -AsHashtable
$refs = @([Newtonsoft.Json.Linq.JObject].Assembly.Location, (Join-Path $PSHOME 'ref\\System.Collections.dll'), (Join-Path $PSHOME 'ref\\System.Linq.dll'), (Join-Path $PSHOME 'ref\\System.Text.RegularExpressions.dll'))
# Only suppress the assembly unification warning between PowerShell's bundled Newtonsoft
# and the host's System.Runtime. C# errors and every other warning remain failures.
Add-Type -TypeDefinition $inputJson.source -ReferencedAssemblies $refs -CompilerOptions '/nowarn:1701', '/langversion:7'
$results = @()
foreach ($v in $inputJson.vectors) {
  $ctx = [Context]::new()
  $ctx.Response.StatusCode = [int]$v.status
  $ctx.LastError.PolicyId = [string]$v.policyId
  $ctx.LastError.Reason = [string]$v.reason
  foreach ($key in $v.vars.Keys) {
    $value = $v.vars[$key]
    if ($key -eq 'ccofResolverResponse') {
      $response = [Response]::new()
      $response.StatusCode = [int]$value.status
      $response.Body = [Body]::new()
      $response.Body.Text = $value.body | ConvertTo-Json -Depth 50 -Compress
      $ctx.Variables[$key] = $response
    } elseif ($value -is [System.Collections.IDictionary] -or $value -is [array]) {
      $encoded = $value | ConvertTo-Json -Depth 50 -Compress
      $ctx.Variables[$key] = $encoded.PSObject.BaseObject
    } elseif ($key.EndsWith('Tpm')) { $ctx.Variables[$key] = [int]$value
    } elseif ($key.EndsWith('Quota')) { $ctx.Variables[$key] = [long]$value
    } else { $ctx.Variables[$key] = if ($null -eq $value) { $null } else { $value.PSObject.BaseObject } }
  }
  $method = [PolicyExpressions].GetMethod($v.method)
  try { $result = $method.Invoke($null, @($ctx)) } catch { throw ($v.label + ': ' + $_.Exception.ToString()) }
  if ($v.json) { $result = $result | ConvertFrom-Json -AsHashtable }
  $results += ,$result
}
ConvertTo-Json -InputObject $results -Depth 50 -Compress
`;
  const result = spawnSync("pwsh", ["-NoProfile", "-NonInteractive", "-Command", script], {
    input: JSON.stringify({ source, vectors }),
    encoding: "utf8",
    timeout: 120_000,
    maxBuffer: 4_000_000,
    env: { ...process.env, CCOF_LIVE_TESTS: "0" },
  });
  assert.equal(result.status, 0, `C# expression harness failed:\n${result.stdout}\n${result.stderr}`);
  return JSON.parse(result.stdout.trim());
}

const nullLimit = () => ({ tokensPerMinute: null, tokenQuota: null, tokenQuotaPeriod: null });
function decision(): Record<string, any> {
  return {
    decisionVersion: 3, resolverOutcome: "success", projectId: "EXAMPLE01", classification: "STD",
    classificationGroupId: "22222222-2222-2222-2222-222222222222", backendId: "foundry-example",
    familyPolicy: {
      aggregateLimits: {
        person: { tokensPerMinute: 1000000, tokenQuota: 500000, tokenQuotaPeriod: "Daily" },
        group: { tokensPerMinute: null, tokenQuota: 2000000, tokenQuotaPeriod: "Daily" },
      },
      families: {
        haiku: { models: ["claude-haiku-4-5", "claude-haiku-4-5-20251001", "team-fast"], person: nullLimit(), group: nullLimit() },
        sonnet: { models: ["claude-sonnet-5"], person: nullLimit(), group: nullLimit() },
      },
    },
  };
}

test("actual C# rejects invalid v3 policies, admits only exact IDs, scopes keys and maps all family failures", (t) => {
  const methods: Record<string, string> = {
    Resolve: expression("ccofResolverResult"),
    CacheValid: expression("ccofCachedDecisionValid"),
    CacheState: expression("ccofCacheState", 1),
    GroupId: expression("ccofClassificationGroupId"),
    GroupDisplayName: expression("ccofClassificationGroupDisplayName"),
    Family: expression("ccofModelFamily", 1),
    Allowed: expression("ccofModelAllowed"),
    RefusalStatus: expression("ccofRefusalStatus"),
    RefusalBody: expression("ccofRefusalBody"),
    ErrorKind: expression("ccofErrorKind"),
    ErrorStatus: expression("ccofErrorStatus"),
    ErrorBody: expression("ccofErrorBody"),
    RetryAfter: expression("ccofErrorRetryAfter"),
    GroupKey: attr(limit("ccof-limit-family-group-rate"), "counter-key")!,
    PersonKey: attr(limit("ccof-limit-family-person-rate"), "counter-key")!,
    PersonTpm: expression("ccofPersonTpm"), GroupTpm: expression("ccofGroupTpm"),
    FamilyPersonTpm: expression("ccofFamilyPersonTpm"), FamilyGroupTpm: expression("ccofFamilyGroupTpm"),
    FamilyPersonQuota: expression("ccofFamilyPersonQuota"), FamilyGroupQuota: expression("ccofFamilyGroupQuota"),
    FamilyPersonPeriod: expression("ccofFamilyPersonPeriod"), FamilyGroupPeriod: expression("ccofFamilyGroupPeriod"),
    Usage: expression("ccofUsageTrace"),
  };
  for (const scope of ["Group", "Person"]) {
    for (const mode of ["rate-quota", "rate", "quota"]) {
      const policy = limit(`ccof-limit-family-${scope.toLowerCase()}-${mode}`);
      const parent = all.find((e) => e.children.includes(policy))!;
      methods[`${scope}_${mode.replace("-", "_")}`] = attr(parent, "condition")!;
    }
  }
  const vectors: Vector[] = [];
  function resolver(label: string, body: Record<string, any>, allowed: boolean) {
    vectors.push({ label, method: "Resolve", vars: { ccofResolverResponse: { status: 200, body } }, json: true,
      expected: allowed ? "allow" : "unavailable" });
    vectors.push({ label: `${label} cached`, method: "CacheValid", vars: { ccofCached: { d: body } }, expected: allowed });
  }
  resolver("valid new decision", decision(), true);
  for (const model of ["a".repeat(120), `claude-haiku-${"a".repeat(106)}`]) {
    const d = decision(); d.familyPolicy.families.haiku.models = [model];
    resolver("maximum model length", d, true);
  }
  const snapshot = decision();
  snapshot.classificationGroupId = "00000000-0000-4000-8000-000001011101";
  snapshot.classificationGroupDisplayName = "CYB Approved <informational only>";
  vectors.push({ label: "normalized trusted group ID", method: "Resolve",
    vars: { ccofResolverResponse: { status: 200, body: snapshot } }, json: true,
    property: "d.classificationGroupId", expected: snapshot.classificationGroupId.toLowerCase() });
  vectors.push({ label: "exact informational snapshot", method: "Resolve",
    vars: { ccofResolverResponse: { status: 200, body: snapshot } }, json: true,
    property: "d.classificationGroupDisplayName", expected: snapshot.classificationGroupDisplayName });
  vectors.push({ label: "policy copied without normalization loss", method: "Resolve",
    vars: { ccofResolverResponse: { status: 200, body: snapshot } }, json: true,
    property: "d.familyPolicy", expected: snapshot.familyPolicy });
  for (const [label, edit] of [
    ["old v1", (d: any) => { d.decisionVersion = 1; }],
    ["old v2", (d: any) => { d.decisionVersion = 2; }],
    ["missing version", (d: any) => { delete d.decisionVersion; }],
    ["version string", (d: any) => { d.decisionVersion = "3"; }],
    ["missing policy", (d: any) => { delete d.familyPolicy; }],
    ["missing group", (d: any) => { delete d.classificationGroupId; }],
    ["group not GUID", (d: any) => { d.classificationGroupId = "CYB Approved"; }],
    ["no families", (d: any) => { d.familyPolicy.families = {}; }],
    ["unknown family", (d: any) => { d.familyPolicy.families.other = d.familyPolicy.families.haiku; }],
    ["empty models", (d: any) => { d.familyPolicy.families.haiku.models = []; }],
    ["duplicate within family", (d: any) => { d.familyPolicy.families.haiku.models.push("team-fast"); }],
    ["duplicate across families", (d: any) => { d.familyPolicy.families.sonnet.models.push("team-fast"); }],
    ["canonical mismatch", (d: any) => { d.familyPolicy.families.haiku.models = ["claude-sonnet-5"]; }],
    ["malformed claude prefix", (d: any) => { d.familyPolicy.families.haiku.models = ["claude-haikux-5"]; }],
    ["canonical missing version", (d: any) => { d.familyPolicy.families.haiku.models = ["claude-haiku-"]; }],
    ["alias invalid", (d: any) => { d.familyPolicy.families.haiku.models = ["team fast"]; }],
    ["alias trailing newline", (d: any) => { d.familyPolicy.families.haiku.models = ["team-fast\n"]; }],
    ["canonical trailing newline", (d: any) => { d.familyPolicy.families.haiku.models = ["claude-haiku-4-5\n"]; }],
    ["alias too long", (d: any) => { d.familyPolicy.families.haiku.models = ["a".repeat(121)]; }],
    ["canonical too long", (d: any) => { d.familyPolicy.families.haiku.models = [`claude-haiku-${"a".repeat(107)}`]; }],
    ["policy extra field", (d: any) => { d.familyPolicy.unlimited = true; }],
    ["aggregate extra field", (d: any) => { d.familyPolicy.aggregateLimits.unlimited = true; }],
    ["family extra field", (d: any) => { d.familyPolicy.families.haiku.unlimited = true; }],
    ["missing person", (d: any) => { delete d.familyPolicy.families.haiku.person; }],
    ["missing group limit", (d: any) => { delete d.familyPolicy.aggregateLimits.group; }],
  ] as Array<[string, (d: any) => void]>) {
    const d = decision(); edit(d); resolver(label, d, false);
  }
  const now = Math.floor(Date.now() / 1000) + 62135596800;
  for (const [label, age, retryAt, valid, state] of [
    ["fresh allow", 1, 0, true, "fresh-allow"],
    ["stale allow", 121, 0, true, "stale-allow"],
    ["LKG backoff", 121, now + 300, true, "stale-allow-backoff"],
    ["expired grace", 4000, 0, true, "miss"],
    ["clock moved backward", -60, 0, true, "miss"],
    ["invalid fresh decision", 1, 0, false, "miss"],
    ["invalid LKG decision", 121, now + 300, false, "miss"],
  ] as Array<[string, number, number, boolean, string]>) {
    vectors.push({ label, method: "CacheState", vars: {
      ccofCached: { k: "allow", at: now - age, rt: retryAt, d: decision() },
      ccofCachedDecisionValid: valid,
    }, expected: state });
  }
  for (const target of ["aggregate", "family"]) {
    for (const [label, edit] of [
      ["tpm zero", (l: any) => { l.tokensPerMinute = 0; }],
      ["tpm negative", (l: any) => { l.tokensPerMinute = -1; }],
      ["tpm fraction", (l: any) => { l.tokensPerMinute = 1.5; }],
      ["tpm string", (l: any) => { l.tokensPerMinute = "1"; }],
      ["tpm overflow", (l: any) => { l.tokensPerMinute = 2147483648; }],
      ["quota zero", (l: any) => { l.tokenQuota = 0; l.tokenQuotaPeriod = "Daily"; }],
      ["quota negative", (l: any) => { l.tokenQuota = -1; l.tokenQuotaPeriod = "Daily"; }],
      ["quota fraction", (l: any) => { l.tokenQuota = 1.5; l.tokenQuotaPeriod = "Daily"; }],
      ["quota string", (l: any) => { l.tokenQuota = "1"; l.tokenQuotaPeriod = "Daily"; }],
      ["quota unsafe", (l: any) => { l.tokenQuota = 9007199254740992; l.tokenQuotaPeriod = "Daily"; }],
      ["quota period missing", (l: any) => { l.tokenQuota = 1; l.tokenQuotaPeriod = null; }],
      ["period quota missing", (l: any) => { l.tokenQuota = null; l.tokenQuotaPeriod = "Daily"; }],
      ["period bad", (l: any) => { l.tokenQuota = 1; l.tokenQuotaPeriod = "daily"; }],
      ["period numeric", (l: any) => { l.tokenQuota = 1; l.tokenQuotaPeriod = 1; }],
      ["missing property", (l: any) => { delete l.tokenQuota; }],
      ["unknown property", (l: any) => { l.unlimited = true; }],
    ] as Array<[string, (l: any) => void]>) {
      const d = decision();
      edit(target === "aggregate" ? d.familyPolicy.aggregateLimits.person : d.familyPolicy.families.haiku.person);
      resolver(`${target} ${label}`, d, false);
    }
  }
  for (const period of ["Hourly", "Daily", "Weekly", "Monthly", "Yearly"]) {
    const d = decision();
    d.familyPolicy.families.haiku.person = { tokensPerMinute: 2147483647, tokenQuota: 9007199254740991, tokenQuotaPeriod: period };
    resolver(`safe maxima ${period}`, d, true);
  }
  for (const restricted of ["fable", "mythos"]) {
    for (const classification of ["STD", "PRM", "cyb", "CYB-extra", "CYB"]) {
      const d = decision(); d.classification = classification;
      d.classificationGroupDisplayName = "CYB Approved";
      d.familyPolicy.families[restricted] = { models: ["deployment-approved"], person: nullLimit(), group: nullLimit() };
      resolver(`${restricted} under ${classification}`, d, classification === "CYB");
      vectors.push({ label: `${restricted} independent admission ${classification}`, method: "Family",
        vars: { ccofFamilyPolicy: d.familyPolicy, ccofClassification: classification, ccofModel: "deployment-approved",
          ccofClassificationGroupDisplayName: "CYB Approved" },
        expected: classification === "CYB" ? restricted : "" });
      if (classification !== "CYB") {
        d.familyPolicy.families[restricted] = { models: [], person: nullLimit(), group: nullLimit() };
        resolver(`${restricted} forbidden even empty ${classification}`, d, false);
      }
    }
  }
  for (const [model, family] of [
    ["claude-haiku-4-5", "haiku"], ["claude-haiku-4-5-20251001", "haiku"], ["team-fast", "haiku"],
    ["claude-sonnet-5", "sonnet"], ["claude-haiku-unknown", ""], ["claude-haikux-5", ""],
    ["Claude-haiku-4-5", ""], ["TEAM-FAST", ""], ["claude-opus-4-6", ""],
  ]) {
    vectors.push({ label: `exact ${model}`, method: "Family",
      vars: { ccofFamilyPolicy: decision().familyPolicy, ccofClassification: "STD", ccofModel: model }, expected: family });
    vectors.push({ label: `allowed ${model}`, method: "Allowed", vars: { ccofModelFamily: family }, expected: family !== "" });
  }
  vectors.push({ label: "duplicate matches fail admission independently", method: "Family",
    vars: { ccofFamilyPolicy: { families: {
      haiku: { models: ["same-alias"] }, sonnet: { models: ["same-alias"] },
    } }, ccofClassification: "STD", ccofModel: "same-alias" }, expected: "" });
  const base = { ccofProjectId: "PROJECT1", ccofOid: "person1", ccofClassificationGroupId: "group1", ccofModelFamily: "haiku" };
  for (const model of ["claude-haiku-4-5", "claude-haiku-4-5-20251001"]) {
    vectors.push({ label: `version shared group ${model}`, method: "GroupKey", vars: { ...base, ccofModel: model }, expected: "gf:PROJECT1:group1:haiku" });
    vectors.push({ label: `version shared person ${model}`, method: "PersonKey", vars: { ...base, ccofModel: model }, expected: "pf:PROJECT1:person1:haiku" });
  }
  for (const [field, value, groupKey, personKey] of [
    ["ccofProjectId", "PROJECT2", "gf:PROJECT2:group1:haiku", "pf:PROJECT2:person1:haiku"],
    ["ccofOid", "person2", "gf:PROJECT1:group1:haiku", "pf:PROJECT1:person2:haiku"],
    ["ccofClassificationGroupId", "group2", "gf:PROJECT1:group2:haiku", "pf:PROJECT1:person1:haiku"],
    ["ccofModelFamily", "sonnet", "gf:PROJECT1:group1:sonnet", "pf:PROJECT1:person1:sonnet"],
  ]) {
    vectors.push({ label: `group scope ${field}`, method: "GroupKey", vars: { ...base, [field]: value }, expected: groupKey });
    vectors.push({ label: `person scope ${field}`, method: "PersonKey", vars: { ...base, [field]: value }, expected: personKey });
  }
  const vars = { ccofDecision: decision(), ccofFamilyPolicy: decision().familyPolicy, ccofModelFamily: "haiku" };
  for (const [method, expected] of [
    ["PersonTpm", 1000000], ["GroupTpm", 0], ["FamilyPersonTpm", 0], ["FamilyGroupTpm", 0],
    ["FamilyPersonQuota", 0], ["FamilyGroupQuota", 0], ["FamilyPersonPeriod", ""], ["FamilyGroupPeriod", ""],
  ] as Array<[string, unknown]>) vectors.push({ label: `all-null family ${method}`, method, vars, expected });
  const maximum = decision();
  for (const scope of ["person", "group"]) {
    maximum.familyPolicy.families.haiku[scope] = {
      tokensPerMinute: 2147483647, tokenQuota: 9007199254740991, tokenQuotaPeriod: "Yearly",
    };
    const prefix = `Family${scope === "person" ? "Person" : "Group"}`;
    for (const [suffix, expected] of [["Tpm", 2147483647], ["Quota", 9007199254740991], ["Period", "Yearly"]] as Array<[string, unknown]>) {
      vectors.push({ label: `safe extraction ${prefix}${suffix}`, method: `${prefix}${suffix}`,
        vars: { ccofFamilyPolicy: maximum.familyPolicy, ccofModelFamily: "haiku" }, expected });
    }
  }
  for (const scope of ["Group", "Person"]) {
    for (const [tpm, quota, chosen] of [
      [100, 200, "rate-quota"], [100, 0, "rate"], [0, 200, "quota"], [0, 0, null],
    ] as Array<[number, number, string | null]>) {
      // APIM choose takes the first matching when, so rate-only can match rate+quota
      // but must never be reached after the combined branch.
      for (const mode of ["rate-quota", "rate", "quota"]) {
        vectors.push({ label: `${scope} branch ${mode} tpm=${tpm} quota=${quota}`,
          method: `${scope}_${mode.replace("-", "_")}`,
          vars: { [`ccofFamily${scope}Tpm`]: tpm, [`ccofFamily${scope}Quota`]: quota },
          expected: mode === "rate-quota" ? chosen === "rate-quota" : mode === "rate" ? tpm > 0 : quota > 0 });
      }
    }
  }
  const usageVars = {
    ccofBackendId: "foundry-example", ccofModel: "team-fast", ccofOid: "person1", ccofProjectId: "EXAMPLE01",
    ccofClassification: "STD", ccofClassificationGroupId: "22222222-2222-2222-2222-222222222222",
    ccofClassificationGroupDisplayName: snapshot.classificationGroupDisplayName,
    ccofModelFamily: "haiku", ccofDecision: snapshot, ccofStream: true,
  };
  for (const [property, expected] of [
    ["modelFamily", "haiku"], ["classificationGroupId", usageVars.ccofClassificationGroupId],
    ["classificationGroupDisplayName", snapshot.classificationGroupDisplayName], ["usage", null],
  ] as Array<[string, unknown]>) vectors.push({ label: `trusted usage ${property}`, method: "Usage", vars: usageVars, json: true, property, expected });
  vectors.push({ label: "unestablished family telemetry is null", method: "Usage",
    vars: { ...usageVars, ccofModelFamily: "" }, json: true, property: "modelFamily", expected: null });
  vectors.push({ label: "missing name telemetry is null", method: "Usage",
    vars: { ...usageVars, ccofClassificationGroupDisplayName: "" }, json: true,
    property: "classificationGroupDisplayName", expected: null });
  vectors.push({ label: "trusted ID extraction is lowercase", method: "GroupId", vars: { ccofDecision: snapshot },
    expected: snapshot.classificationGroupId.toLowerCase() });
  for (const name of [undefined, "", null, 1, "x".repeat(257), "CYB Approved <snapshot>", "x".repeat(256)]) {
    vectors.push({ label: `name extraction ${String(name).slice(0, 30)}`, method: "GroupDisplayName",
      vars: { ccofDecision: { ...snapshot, classificationGroupDisplayName: name } },
      expected: typeof name === "string" && name.length >= 1 && name.length <= 256 ? name : "" });
  }
  vectors.push({ label: "model refusal status", method: "RefusalStatus", vars: { ccofRefusal: "model_family_not_allowed" }, expected: 403 });
  vectors.push({ label: "model refusal body", method: "RefusalBody", vars: {
    ccofRefusal: "model_family_not_allowed", ccofSelector: "", ccofModel: "claude-haiku-unknown",
  }, json: true, expected: "The requested model family is not available to your project classification. Ask your platform team for an approved model." });
  for (const scope of ["group", "person"]) {
    for (const mode of ["rate-quota", "rate", "quota"]) {
      for (const status of mode === "rate-quota" ? [429, 403] : [mode === "rate" ? 429 : 403]) {
        const kind = `family_${scope}_${status === 429 ? "rate" : "quota"}_exceeded`;
        vectors.push({ label: `${scope} ${mode} ${status}`, method: "ErrorKind",
          status, policyId: `ccof-limit-family-${scope}-${mode}`, expected: kind });
        vectors.push({ label: `${kind} status`, method: "ErrorStatus", vars: { ccofErrorKind: kind }, expected: status });
        vectors.push({ label: `${kind} body`, method: "ErrorBody", vars: { ccofErrorKind: kind }, json: true, expected: status === 429 ? "rate_limit_error" : "permission_error" });
        vectors.push({ label: `${kind} retry`, method: "RetryAfter", vars: { ccofErrorKind: kind, ccofRetryAfter: 30 }, expected: "30" });
      }
    }
  }
  const results = runExpressions(methods, vectors);
  assert.equal(results.length, vectors.length);
  for (let i = 0; i < vectors.length; i++) {
    const v = vectors[i];
    const value = v.property ? v.property.split(".").reduce((value: any, key) => value?.[key], results[i])
      : v.method === "Resolve" ? (results[i] as any).o
      : v.method === "RefusalBody" ? (results[i] as any).error.message.replace(/ Request id:.*$/, "")
      : v.method === "ErrorBody" ? (results[i] as any).error.type : results[i];
    assert.deepEqual(value, v.expected, v.label);
    if (v.method === "ErrorBody") {
      const messages: Record<string, string> = {
        family_person_rate_exceeded: "Your token rate limit for this model family is exceeded. Retry after the indicated interval.",
        family_group_rate_exceeded: "Your group's token rate limit for this model family is exceeded. Retry after the indicated interval.",
        family_person_quota_exceeded: "Your token quota for this model family is used up for this quota period.",
        family_group_quota_exceeded: "Your group's token quota for this model family is used up for this quota period.",
      };
      assert.equal((results[i] as any).error.message,
        `${messages[v.vars!.ccofErrorKind as string]} Request id: 00000000-0000-0000-0000-000000000001.`,
        `${v.label} exact message`);
    }
  }
  assert.ok(vectors.length >= 250, `only ${vectors.length} behavioral vectors ran`);
  t.diagnostic(`${vectors.length} actual rendered C# 7 behavioral vectors passed`);
});
