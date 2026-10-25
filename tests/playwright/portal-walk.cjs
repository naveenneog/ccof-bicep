// Playwright walkthrough of the guide's manual Portal steps for one tenant.
// Usage: node portal-walk.cjs <profileDir> <tenantDomain> <steps.json> <outDir>
// Each step: { id, title, guideStep, url, expect: [text...] }. Records signed-in / found text / screenshot.
const { chromium } = require('playwright-core'); const fs = require('fs'); const path = require('path');
const [profile, tenant, stepsFile, outDir, maskList] = process.argv.slice(2);
// Optional fifth argument: comma-separated literal strings (subscription or directory names) masked in screenshots.
const MASK = (maskList || '').split(',').map(x => x.trim()).filter(Boolean);
const steps = JSON.parse(fs.readFileSync(stepsFile, 'utf8'));
const GUID = /\b([0-9a-f]{8})-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{8}([0-9a-f]{4})\b/gi;
async function maskAll(page) {
  for (const f of page.frames()) {
    await f.evaluate(mask => {
      const re = /\b([0-9a-f]{8})-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{8}([0-9a-f]{4})\b/gi;
      const w = document.createTreeWalker(document.body || document, NodeFilter.SHOW_TEXT); let n;
      while ((n = w.nextNode())) if (re.test(n.nodeValue)) n.nodeValue = n.nodeValue.replace(re, '$1-····-····-····-········$2');
      for (const i of document.querySelectorAll('input')) if (re.test(i.value)) i.value = i.value.replace(re, '$1-····-····-····-········$2');
      for (const e of document.querySelectorAll('*')) if (e.title && re.test(e.title)) e.title = '';
      const w2 = document.createTreeWalker(document.body || document, NodeFilter.SHOW_TEXT);
      while ((n = w2.nextNode())) for (const m of mask) if (n.nodeValue.includes(m)) n.nodeValue = n.nodeValue.split(m).join('<masked>');
    }, MASK).catch(() => {});
  }
}
(async () => {
  fs.mkdirSync(outDir, { recursive: true });
  // profile argument: a CDP endpoint (http://127.0.0.1:<port>) of a signed-in window kept open by keepopen.cjs.
  const browser = await chromium.connectOverCDP(profile);
  const ctx = browser.contexts()[0];
  // Reuse a signed-in Portal tab: a new tab can stop at the account picker, which needs the operator.
  const existing = ctx.pages().find(p => /^https:\/\/[a-z.]*portal\.azure\.com\//.test(p.url()));
  const page = existing || await ctx.newPage(); await page.setViewportSize({ width: 1600, height: 1000 });
  // Stay on the session's Portal host (for example ms.portal.azure.com); another host signs in again.
  const host = existing ? new URL(existing.url()).host : 'portal.azure.com';
  const results = [];
  for (const s of steps) {
    const r = { id: s.id, title: s.title, guideStep: s.guideStep, url: s.url.replace(/\/subscriptions\/[0-9a-f-]+/i, '/subscriptions/<sub>') };
    try {
      await page.goto(`https://${host}/#@${tenant}${s.url}`, { waitUntil: 'domcontentloaded', timeout: 90000 });
      await page.waitForTimeout(s.wait ?? 25000);
      if (/login\.microsoftonline\.com/.test(page.url())) { r.status = 'blocked_sign_in'; results.push(r); continue; }
      // Resource menu entries without a stable deep link: filter the blade menu, then open the entry.
      if (s.menu) {
        const esc = s.menu.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        const search = page.locator('input[aria-label="Search box"]').first();
        await search.fill(s.menu).catch(() => {});
        await page.waitForTimeout(2000);
        const item = page.locator('.fxc-menu-listView-item:visible').filter({ hasText: new RegExp(`^\\s*${esc}\\s*$`, 'i') }).first();
        if (await item.count().catch(() => 0)) { await item.click(); r.menu = s.menu; }
        await page.waitForTimeout(s.menuWait ?? 20000);
      }
      if (s.click) {
        for (const f of page.frames()) {
          const tab = f.getByRole('tab', { name: s.click, exact: true });
          if (await tab.count().catch(() => 0)) { await tab.first().click(); r.clicked = s.click; break; }
        }
        await page.waitForTimeout(s.clickWait ?? 15000);
      }
      // Long lists (shared resource groups, inherited role assignments): use the blade's own filter box.
      if (s.filter) {
        for (const f of page.frames()) {
          const box = f.getByPlaceholder(s.filter.placeholder).first();
          if (await box.count().catch(() => 0)) { await box.fill(s.filter.text); r.filtered = s.filter.text; break; }
        }
        await page.waitForTimeout(s.filterWait ?? 10000);
      }
      const read = async () => { let t = ''; for (const f of page.frames()) t += ' ' + (await f.evaluate(() => document.body ? document.body.innerText : '').catch(() => '')); return t; };
      const check = t => (s.expect || []).map(e => ({ text: e, present: t.toLowerCase().includes(e.toLowerCase()) }));
      let text = await read();
      r.found = check(text);
      // Some blades show a loading state ("Service is getting ready...") for longer: read once more.
      if (!r.found.every(x => x.present)) { await page.waitForTimeout(s.retryWait ?? 30000); text = await read(); r.found = check(text); r.reread = true; }
      r.status = r.found.every(x => x.present) ? 'pass' : 'mismatch';
      await maskAll(page);
      r.screenshot = path.join(outDir, `${s.id}.png`);
      await page.screenshot({ path: r.screenshot });
      const leak = text.match(GUID); r.guidsMaskedOnPage = leak ? leak.length : 0;
    } catch (e) { r.status = 'error'; r.error = e.message.slice(0, 300); }
    results.push(r); console.log(`${r.status.padEnd(16)} ${s.id} ${s.title}`);
  }
  fs.writeFileSync(path.join(outDir, 'walk-results.json'), JSON.stringify(results, null, 1));
  if (!existing) await page.close();
  process.exit(0);
})().catch(e => { console.error(e.message); process.exit(1); });


