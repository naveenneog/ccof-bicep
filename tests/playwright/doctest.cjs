const { chromium } = require('playwright-core'); const fs = require('fs'); const path = require('path');
(async () => {
  const docs = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  const b = await chromium.launch({ channel: 'msedge' }); const page = await b.newPage();
  const report = [];
  for (const d of docs) {
    const errors = [];
    page.removeAllListeners('pageerror'); page.on('pageerror', e => errors.push(e.message));
    await page.goto('file:///' + d.html.replace(/\\/g, '/')); await page.waitForTimeout(1500);
    const r = await page.evaluate(async () => {
      const imgs = [...document.images].map(i => ({ src: i.getAttribute('src'), ok: i.complete && i.naturalWidth > 0 }));
      const ids = new Set([...document.querySelectorAll('[id]')].map(e => e.id));
      const anchors = [...document.querySelectorAll('a[href^="#"]')].map(a => ({ href: a.getAttribute('href'), ok: ids.has(decodeURIComponent(a.getAttribute('href').slice(1))) }));
      const local = [...document.querySelectorAll('a[href]')].map(a => a.getAttribute('href')).filter(h => !/^(https?:|#|mailto:)/.test(h));
      return { imgs, anchors, local, headings: [...document.querySelectorAll('h2,h3')].map(h => h.textContent) };
    });
    const localChecks = r.local.map(h => { const p = path.resolve(path.dirname(d.html), decodeURIComponent(h.split('#')[0])); return { href: h, ok: fs.existsSync(p) }; });
    report.push({ doc: d.doc, images: r.imgs.length, brokenImages: r.imgs.filter(i => !i.ok).map(i => i.src), anchors: r.anchors.length, brokenAnchors: r.anchors.filter(a => !a.ok).map(a => a.href),
      localLinks: localChecks.length, brokenLinks: localChecks.filter(l => !l.ok).map(l => l.href), pageErrors: errors, headings: r.headings });
  }
  await b.close(); fs.writeFileSync(process.argv[3], JSON.stringify(report, null, 1));
  for (const x of report) console.log(`${x.doc}: images ${x.images} (broken ${x.brokenImages.length}), anchors ${x.anchors} (broken ${x.brokenAnchors.length}), local links ${x.localLinks} (broken ${x.brokenLinks.length}), page errors ${x.pageErrors.length}` + (x.brokenImages.length + x.brokenAnchors.length + x.brokenLinks.length ? '\n   ' + JSON.stringify([...x.brokenImages, ...x.brokenAnchors, ...x.brokenLinks]) : ''));
})().catch(e => { console.error(e); process.exit(1); });
