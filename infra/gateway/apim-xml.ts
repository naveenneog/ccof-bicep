// A parser for API Management policy documents in the "rawxml" form APIM stores
// and returns. That form is XML, except that an attribute value starting with
// @( or @{ is a C# expression that may contain raw quotes, '<' and '&'. The
// expression ends at its balancing bracket (C# string and character literals
// are skipped), and the attribute's closing quote must follow. Element text is
// plain XML: an expression in text that needs '<' or '&' goes in CDATA.
//
// Used to check that a rendered policy is well formed before it is deployed,
// and by the tests to assert its structure.

export interface XmlAttribute {
  name: string;
  value: string;
  expression: boolean;
}

export interface XmlElement {
  kind: "element";
  name: string;
  attributes: XmlAttribute[];
  children: XmlNode[];
  line: number;
}

export type XmlNode = XmlElement | { kind: "text"; value: string } | { kind: "cdata"; value: string } | { kind: "comment"; value: string };

export class ApimXmlError extends Error {}

const NAME = /^[A-Za-z_][A-Za-z0-9_.:-]*/;
const ENTITIES: Record<string, string> = { quot: '"', apos: "'", lt: "<", gt: ">", amp: "&" };

function decodeEntities(text: string, line: number): string {
  return text.replace(/&(#x[0-9A-Fa-f]+|#[0-9]+|[A-Za-z]+);|&/g, (whole, ref: string | undefined) => {
    if (ref === undefined) throw new ApimXmlError(`line ${line}: bare '&' outside an expression`);
    if (ref.startsWith("#x")) return String.fromCodePoint(parseInt(ref.slice(2), 16));
    if (ref.startsWith("#")) return String.fromCodePoint(parseInt(ref.slice(1), 10));
    const named = ENTITIES[ref];
    if (named === undefined) throw new ApimXmlError(`line ${line}: unknown entity ${whole}`);
    return named;
  });
}

export function parseApimXml(source: string): XmlElement {
  let pos = 0;
  const lineAt = (p: number) => source.slice(0, p).split("\n").length;
  const fail = (message: string, p = pos): never => {
    throw new ApimXmlError(`line ${lineAt(p)}: ${message}`);
  };

  // Skips one C# string or character literal starting at i; returns the index after it.
  function skipCSharpLiteral(i: number): number {
    const verbatim = source[i] === "@" && source[i + 1] === '"';
    const quote = verbatim ? '"' : source[i];
    let j = verbatim ? i + 2 : i + 1;
    while (j < source.length) {
      const c = source[j];
      if (verbatim && c === '"' && source[j + 1] === '"') { j += 2; continue; }
      if (!verbatim && c === "\\") { j += 2; continue; }
      if (c === quote) return j + 1;
      if (!verbatim && c === "\n" && quote === "'") break;
      j++;
    }
    return fail("unterminated C# literal in an expression", i);
  }

  function readExpression(start: number): number {
    const open = source[start + 1];
    const close = open === "(" ? ")" : "}";
    let depth = 0;
    let i = start + 1;
    while (i < source.length) {
      const c = source[i];
      if (c === '"' || c === "'" || (c === "@" && source[i + 1] === '"')) { i = skipCSharpLiteral(i); continue; }
      if (c === open) depth++;
      else if (c === close) {
        depth--;
        if (depth === 0) return i + 1;
      }
      i++;
    }
    return fail("unterminated policy expression", start);
  }

  function readAttributeValue(): { value: string; expression: boolean } {
    const quote = source[pos];
    if (quote !== '"' && quote !== "'") fail("attribute value must be quoted");
    const start = pos + 1;
    if (source[start] === "@" && (source[start + 1] === "(" || source[start + 1] === "{")) {
      const end = readExpression(start);
      if (source[end] !== quote) fail("text after a policy expression inside an attribute", end);
      pos = end + 1;
      return { value: decodeExpression(source.slice(start, end)), expression: true };
    }
    const end = source.indexOf(quote, start);
    if (end < 0) fail("unterminated attribute value");
    const raw = source.slice(start, end);
    if (raw.includes("<")) fail("'<' in an attribute value", start);
    pos = end + 1;
    return { value: decodeEntities(raw, lineAt(start)), expression: false };
  }

  // Entities written inside an expression (strict XML style) are decoded; raw
  // characters (APIM's rawxml style) are kept as they are.
  function decodeExpression(raw: string): string {
    return raw.replace(/&(quot|apos|lt|gt|amp);/g, (_, name: string) => ENTITIES[name]);
  }

  function skipWhitespace(): void {
    while (pos < source.length && /\s/.test(source[pos])) pos++;
  }

  function readElement(): XmlElement {
    const line = lineAt(pos);
    pos++;
    const nameMatch = NAME.exec(source.slice(pos));
    if (!nameMatch) fail("element name expected");
    const name = nameMatch![0];
    pos += name.length;
    const attributes: XmlAttribute[] = [];
    for (;;) {
      const before = pos;
      skipWhitespace();
      if (source.startsWith("/>", pos)) { pos += 2; return { kind: "element", name, attributes, children: [], line }; }
      if (source[pos] === ">") { pos++; break; }
      if (pos === before) fail(`whitespace expected in <${name}>`);
      const attrMatch = NAME.exec(source.slice(pos));
      if (!attrMatch) fail(`attribute name expected in <${name}>`);
      const attrName = attrMatch![0];
      if (attributes.some((a) => a.name === attrName)) fail(`duplicate attribute ${attrName} in <${name}>`);
      pos += attrName.length;
      skipWhitespace();
      if (source[pos] !== "=") fail(`'=' expected after ${attrName}`);
      pos++;
      skipWhitespace();
      attributes.push({ name: attrName, ...readAttributeValue() });
    }
    const children = readChildren(name);
    return { kind: "element", name, attributes, children, line };
  }

  function readChildren(parent: string | null): XmlNode[] {
    const children: XmlNode[] = [];
    while (pos < source.length) {
      if (source.startsWith("<!--", pos)) {
        const end = source.indexOf("-->", pos + 4);
        if (end < 0) fail("unterminated comment");
        const value = source.slice(pos + 4, end);
        // XML 1.0 §2.5: "--" must not occur in a comment, and a comment must not end in "-".
        if (value.includes("--") || value.endsWith("-")) fail("'--' inside a comment");
        children.push({ kind: "comment", value });
        pos = end + 3;
      } else if (source.startsWith("<![CDATA[", pos)) {
        const end = source.indexOf("]]>", pos + 9);
        if (end < 0) fail("unterminated CDATA section");
        children.push({ kind: "cdata", value: source.slice(pos + 9, end) });
        pos = end + 3;
      } else if (source.startsWith("</", pos)) {
        if (parent === null) fail("end tag without a start tag");
        const end = source.indexOf(">", pos);
        const name = source.slice(pos + 2, end).trim();
        if (name !== parent) fail(`</${name}> closes <${parent}>`);
        pos = end + 1;
        return children;
      } else if (source[pos] === "<") {
        if (source[pos + 1] === "?" || source[pos + 1] === "!") fail("declarations are not supported");
        children.push(readElement());
      } else {
        const end = source.indexOf("<", pos);
        const raw = source.slice(pos, end < 0 ? source.length : end);
        children.push({ kind: "text", value: decodeEntities(raw, lineAt(pos)) });
        pos += raw.length;
      }
    }
    if (parent !== null) fail(`<${parent}> is not closed`);
    return children;
  }

  const top = readChildren(null);
  const elements = top.filter((n): n is XmlElement => n.kind === "element");
  const strayText = top.some((n) => n.kind === "text" && n.value.trim() !== "") || top.some((n) => n.kind === "cdata");
  if (elements.length !== 1 || strayText) throw new ApimXmlError("a policy document has exactly one root element and no text outside it");
  return elements[0];
}

export function attr(element: XmlElement, name: string): string | undefined {
  return element.attributes.find((a) => a.name === name)?.value;
}

// Every element below `scope`, depth first, in document order.
export function descendants(scope: XmlElement): XmlElement[] {
  const out: XmlElement[] = [];
  const walk = (el: XmlElement) => {
    for (const child of el.children) {
      if (child.kind === "element") {
        out.push(child);
        walk(child);
      }
    }
  };
  walk(scope);
  return out;
}

export function textOf(element: XmlElement): string {
  return element.children.map((c) => (c.kind === "text" || c.kind === "cdata" ? c.value : "")).join("");
}
