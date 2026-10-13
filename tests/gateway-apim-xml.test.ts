// The APIM rawxml parser: what it accepts is what the renderer will deploy, so
// it must refuse malformed policies rather than read them loosely.

import { strict as assert } from "node:assert";
import { describe, test } from "node:test";

import { attr, descendants, parseApimXml, textOf } from "../infra/gateway/apim-xml.ts";

describe("APIM rawxml parser", () => {
  test("reads raw C# in attribute expressions, including quotes, '<', '&&' and brackets inside strings", () => {
    const root = parseApimXml(
      `<policies><inbound><set-variable name="a" value="@(context.Variables["x"] == ")" && 1 < 2)" /><set-variable name="b" value="@{ var s = "}{"; return s + '}'; }" /></inbound></policies>`,
    );
    const vars = descendants(root).filter((e) => e.name === "set-variable");
    assert.equal(attr(vars[0], "value"), '@(context.Variables["x"] == ")" && 1 < 2)');
    assert.equal(attr(vars[1], "value"), `@{ var s = "}{"; return s + '}'; }`);
  });

  test("decodes entities in strict-XML style expressions and plain attributes", () => {
    const root = parseApimXml(`<p a="@(&quot;x&quot; == y &amp;&amp; z &lt; 1)" b="a &amp; b"><v>1 &lt; 2</v><c><![CDATA[@{ return a < b && c; }]]></c></p>`);
    assert.equal(attr(root, "a"), '@("x" == y && z < 1)');
    assert.equal(attr(root, "b"), "a & b");
    assert.equal(textOf(descendants(root)[0]), "1 < 2");
    assert.equal(textOf(descendants(root)[1]), "@{ return a < b && c; }");
  });

  const malformed: Array<[string, string, RegExp]> = [
    ["an unclosed element", "<policies><inbound></policies>", /closes <inbound>|not closed/],
    ["a mismatched end tag", "<policies><inbound></outbound></policies>", /closes <inbound>/],
    ["an unterminated expression", '<p a="@(context.Variables["x"]" />', /unterminated/],
    ["text after an expression in an attribute", '<p a="@(x) and more" />', /text after a policy expression/],
    ["'<' in a plain attribute", '<p a="1 < 2" />', /'<' in an attribute/],
    ["a bare '&' in text", "<p>a & b</p>", /bare '&'/],
    ["a duplicate attribute", '<p a="1" a="2" />', /duplicate attribute/],
    ["two root elements", "<a /><b />", /exactly one root/],
    ["an unterminated comment", "<p><!-- x </p>", /unterminated comment/],
    ["'--' inside a comment (not well-formed XML; APIM refuses it)", "<p><!-- a -- b --></p>", /'--' inside a comment/],
    ["a comment ending in '-' before '-->'", "<p><!-- a ---></p>", /'--' inside a comment/],
  ];
  for (const [what, text, expected] of malformed) {
    test(`refuses ${what}`, () => {
      assert.throws(() => parseApimXml(text), expected);
    });
  }
});
