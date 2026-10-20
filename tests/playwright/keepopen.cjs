const { chromium } = require('playwright-core');
const [profile, tenant, port] = process.argv.slice(2);
(async () => {
  const ctx = await chromium.launchPersistentContext(profile, { channel: 'msedge', headless: false, viewport: null, args: ['--start-maximized', `--remote-debugging-port=${port}`] });
  const page = ctx.pages()[0] || await ctx.newPage();
  await page.goto(`https://portal.azure.com/#@${tenant}/home`);
  console.log(`window open on port ${port}; stays open until this process is stopped`);
  await new Promise(() => {});
})().catch(e => { console.error(e.message); process.exit(1); });
