// Playwright walkthrough of the guide's manual Portal steps for one tenant.
// Usage: node portal-walk.cjs <profileDir> <tenantDomain> <steps.json> <outDir>
// Each step: { id, title, guideStep, url, expect: [text...] }. Records signed-in / found text / screenshot.
const { chromium } = require('playwright-core'); const fs = require('fs'); const path = require('path');
const [profile, tenant, stepsFile, outDir] = process.argv.slice(2);
const steps = JSON.parse(fs.readFileSync(stepsFile, 'utf8'));
const GUID = /\b([0-9a-f]{8})-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{8}([0-9a-f]{4})\b/gi;
async function maskAll(page) {
  for (const f of page.frames()) {
    await f.evaluate(() => {
      const re = /\b([0-9a-f]{8})-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{8}([0-9a-f]{4})\b/gi;
      const w = document.createTreeWalker(document.body || document, NodeFilter.SHOW_TEXT); let n;
      while ((n = w.nextNode())) if (re.test(n.nodeValue)) n.nodeValue = n.nodeValue.replace(re, '$1-····-····-····-········$2');
      for (const i of document.querySelectorAll('input')) if (re.test(i.value)) i.value = i.value.replace(re, '$1-····-····-····-········$2');
      for (const e of document.querySelectorAll('*')) if (e.title && re.test(e.title)) e.title = '';
    }).catch(() => {});
  }
}
(async () => {
  fs.mkdirSync(outDir, { recursive: true });
  // profile argument: a CDP endpoint (http://127.0.0.1:<port>) of a signed-in window kept open by keepopen.cjs.
  const browser = await chromium.connectOverCDP(profile);
  const ctx = browser.contexts()[0];
  const page = await ctx.newPage(); await page.setViewportSize({ width: 1600, height: 1000 });
  const results = [];
  for (const s of steps) {
    const r = { id: s.id, title: s.title, guideStep: s.guideStep, url: s.url.replace(/\/subscriptions\/[0-9a-f-]+/i, '/subscriptions/<sub>') };
    try {
      await page.goto(`https://portal.azure.com/#@${tenant}${s.url}`, { waitUntil: 'domcontentloaded', timeout: 90000 });
      await page.waitForTimeout(s.wait ?? 25000);
      if (/login\.microsoftonline\.com/.test(page.url())) { r.status = 'blocked_sign_in'; results.push(r); continue; }
      let text = '';
      for (const f of page.frames()) text += ' ' + (await f.evaluate(() => document.body ? document.body.innerText : '').catch(() => ''));
      r.found = (s.expect || []).map(e => ({ text: e, present: text.toLowerCase().includes(e.toLowerCase()) }));
      r.status = r.found.every(x => x.present) ? 'pass' : 'mismatch';
      await maskAll(page);
      r.screenshot = path.join(outDir, `${s.id}.png`);
      await page.screenshot({ path: r.screenshot });
      const leak = text.match(GUID); r.guidsMaskedOnPage = leak ? leak.length : 0;
    } catch (e) { r.status = 'error'; r.error = e.message.slice(0, 300); }
    results.push(r); console.log(`${r.status.padEnd(16)} ${s.id} ${s.title}`);
  }
  fs.writeFileSync(path.join(outDir, 'walk-results.json'), JSON.stringify(results, null, 1));
  await page.close();
})().catch(e => { console.error(e.message); process.exit(1); });


