// The template carries no environment value (AC2). A GUID, URL, host name,
// named-value reference or literal limit/TTL attribute in a template file is a
// defect the scanner must report and the renderer must refuse.

import { strict as assert } from "node:assert";
import { describe, test } from "node:test";

import type { GatewayConfig } from "../infra/gateway/config.ts";
import { loadTemplates, renderPolicy } from "../infra/gateway/render.ts";
import { findTemplateLiterals, fillPlaceholders } from "../infra/gateway/template.ts";
import { sampleConfig } from "./helpers/gateway-fixtures.ts";

const templates = loadTemplates();
const config = sampleConfig() as GatewayConfig;

function withMain(edit: (text: string) => string) {
  return { ...templates, main: edit(templates.main) };
}

const anchor = "<inbound>";

describe("template literals", () => {
  test("the committed template files carry no environment value", () => {
    for (const [name, text] of Object.entries({ main: templates.main, ...templates.fragments })) {
      assert.deepEqual(findTemplateLiterals(text, name), [], `${name} carries a literal`);
    }
  });

  const injections: Array<[string, string, RegExp]> = [
    ["a GUID", '<set-variable name="x" value="00000000-0000-4000-8000-000001011111" />', /GUID/],
    ["an upper-case GUID", '<set-variable name="x" value="00000000-0000-4000-8000-000000000111" />', /GUID/],
    ["an https URL", "<set-url>https://resolver.example.test/api/resolve</set-url>", /URL/],
    ["an http URL", '<set-variable name="x" value="http://10.0.0.4/api" />', /URL/],
    ["an api:// audience", '<authentication-managed-identity resource="api://resolver" />', /URL/],
    ["a host name without a scheme", '<set-variable name="x" value="@(&quot;login.microsoftonline.com&quot;)" />', /host name/],
    ["a named-value reference", '<set-variable name="s" value="{{foundry-crosstenant-client-secret}}" />', /named value/],
    ["a literal cache duration", '<cache-store-value key="k" value="v" duration="300" />', /duration/],
    ["a literal rate limit", '<rate-limit-by-key calls="10" renewal-period="60" counter-key="k" />', /calls/],
    ["a literal token limit", '<llm-token-limit counter-key="k" tokens-per-minute="1000" estimate-prompt-tokens="false" />', /tokens-per-minute/],
    ["a literal timeout", '<send-request mode="new" response-variable-name="r" timeout="5" />', /timeout/],
  ];
  for (const [what, element, expected] of injections) {
    test(`a template with ${what} is reported by the scanner and refused by the renderer`, () => {
      const broken = withMain((t) => t.replace(anchor, `${anchor}\n    ${element}`));
      const problems = findTemplateLiterals(broken.main, "main");
      assert.ok(problems.some((p) => expected.test(p)), `not reported: ${JSON.stringify(problems)}`);
      assert.throws(() => renderPolicy(config, { templates: broken }), /literal/);
    });
  }

  test("a configured named value is written through a placeholder, which the scanner allows", () => {
    assert.deepEqual(findTemplateLiterals('<set-variable name="s" value="{{%%CLIENT_SECRET_NAMED_VALUE%%}}" />', "x"), []);
  });

  test("a template that points a named value at anything but a configured backend secret is refused", () => {
    const name = "backend-cross-tenant-client-credentials";
    const anchorLine = '<set-variable name="ccofBackendSecret" value="" />';
    assert.ok(templates.fragments[name].includes(anchorLine));
    const fragment = templates.fragments[name].replace(anchorLine, `${anchorLine}\n<set-variable name="x" value="{{%%BACKEND_ID%%}}" />`);
    const broken = { ...templates, fragments: { ...templates.fragments, [name]: fragment } };
    assert.throws(() => renderPolicy(config, { templates: broken }), /named value "backend-cross-tenant", which is not a configured backend secret/);
  });

  test("line endings do not change the digests, so Windows and Linux checkouts render the same policy", () => {
    const crlf = { main: templates.main.replace(/\r?\n/g, "\r\n"), fragments: Object.fromEntries(Object.entries(templates.fragments).map(([k, v]) => [k, v.replace(/\r?\n/g, "\r\n")])) };
    const lf = { main: templates.main.replace(/\r\n/g, "\n"), fragments: Object.fromEntries(Object.entries(templates.fragments).map(([k, v]) => [k, v.replace(/\r\n/g, "\n")])) };
    const a = renderPolicy(config, { templates: crlf });
    const b = renderPolicy(config, { templates: lf });
    assert.equal(a.policySha256, b.policySha256);
    assert.equal(a.templateSha256, b.templateSha256);
    assert.doesNotMatch(a.policyXml, /\r/);
  });

  test("an unknown placeholder refuses", () => {
    assert.throws(() => fillPlaceholders("<a>%%NOT_A_VARIABLE%%</a>", { KNOWN: "x" }, "t"), /NOT_A_VARIABLE/);
    const broken = withMain((t) => t.replace(anchor, `${anchor}<!-- %%NOT_A_VARIABLE%% -->`));
    assert.throws(() => renderPolicy(config, { templates: broken }), /NOT_A_VARIABLE/);
  });

  test("a variable the templates never use refuses, so a renamed placeholder cannot silently drop a setting", () => {
    const broken = withMain((t) => t.split("%%PERSON_CALLS%%").join("%%PERSON_PERIOD%%"));
    assert.throws(() => renderPolicy(config, { templates: broken }), /PERSON_CALLS/);
  });

  test("a value that is unsafe to place in XML or C# is refused even if it bypassed validation", () => {
    assert.throws(() => fillPlaceholders("<a>%%X%%</a>", { X: 'a"b' }, "t"), /unsafe/);
    assert.throws(() => fillPlaceholders("<a>%%X%%</a>", { X: "{{secret}}" }, "t"), /unsafe/);
    assert.throws(() => fillPlaceholders("<a>%%X%%</a>", { X: "@(x)" }, "t"), /unsafe/);
  });
});
