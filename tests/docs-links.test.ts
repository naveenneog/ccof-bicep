// Every relative link and image in the repository's Markdown resolves to a file in the repository.
// Fenced code blocks are skipped (they hold commands, not links); web links and in-page anchors are not checked.

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function markdownFiles(): string[] {
  const out = execFileSync("git", ["ls-files", "--cached", "--others", "--exclude-standard", "*.md"], { cwd: root, encoding: "utf8" });
  return out.split("\n").filter(Boolean).filter((f) => fs.existsSync(path.join(root, f)));
}

export function brokenLinks(file: string, text: string): string[] {
  const prose = text.replace(/```[\s\S]*?```/g, (block) => "\n".repeat(block.split("\n").length - 1));
  const broken: string[] = [];
  for (const m of prose.matchAll(/!?\[[^\]]*\]\(<?([^)\s>]+)>?(?:\s+"[^"]*")?\)/g)) {
    const target = m[1];
    if (/^(https?:|mailto:|data:|#)/i.test(target)) continue;
    const relative = decodeURIComponent(target.split("#")[0]);
    if (!relative) continue;
    if (!fs.existsSync(path.resolve(root, path.dirname(file), relative))) {
      broken.push(`${file}:${prose.slice(0, m.index).split("\n").length} -> ${target}`);
    }
  }
  return broken;
}

test("relative Markdown links and images resolve to repository files", () => {
  const files = markdownFiles();
  assert.ok(files.length > 50, `expected the repository's Markdown files, found ${files.length}`);
  const broken = files.flatMap((f) => brokenLinks(f, fs.readFileSync(path.join(root, f), "utf8")));
  assert.deepEqual(broken, []);
});

test("the check reports a missing target and ignores code blocks and web links", () => {
  const text = "[ok](../README.md) [web](https://learn.microsoft.com) [gone](missing-page.md)\n```\n[in code](nope.md)\n```\n![img](no-image.png)";
  assert.deepEqual(brokenLinks("docs/example.md", text), ["docs/example.md:1 -> missing-page.md", "docs/example.md:5 -> no-image.png"]);
});
