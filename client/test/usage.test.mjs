import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fetchUsage, formatUsage, usageUrl } from '../src/usage.mjs';

const config = { gatewayUrl: 'https://gw.example.net/anthropic' };
const usage = {
  schema: 'ccof.usage.me.v1', observedAt: '2026-10-23T10:00:00.000Z', basis: 'x',
  projects: [
    { projectId: 'PILOT1', classification: 'STD', state: 'available', spentUsd: '42.10', budgetUsd: '100.00', remainingUsd: '57.89',
      percentUsed: '42.1', exhausted: false, stale: false, completeness: 'complete', computedAt: '2026-10-23T09:55:00Z' },
    { projectId: 'PILOT2', classification: 'PRM', state: 'available', spentUsd: '120.00', budgetUsd: '100.00', remainingUsd: '0.00',
      percentUsed: '120.0', exhausted: true, stale: true, completeness: 'partial', computedAt: '2026-10-23T08:00:00Z' },
    { projectId: 'NEW1', classification: 'STD', state: 'no_budget_state' },
  ],
};

test('the usage URL is the gateway origin plus the usage API, or an https override', () => {
  assert.equal(usageUrl(config, {}), 'https://gw.example.net/ccof-usage/me/usage');
  assert.equal(usageUrl(config, { CCOF_USAGE_URL: 'https://other.example.net/u' }), 'https://other.example.net/u');
  assert.throws(() => usageUrl(config, { CCOF_USAGE_URL: 'http://plain.example.net/u' }), { code: 'invalid_usage_url' });
});

test('the token is sent as a bearer token and each status maps to an actionable error', async () => {
  let seen;
  const ok = await fetchUsage('https://gw.example.net/ccof-usage/me/usage', 'tok', {
    fetchImpl: async (url, init) => { seen = init.headers.authorization; return new Response(JSON.stringify(usage), { status: 200 }); } });
  assert.equal(seen, 'Bearer tok');
  assert.equal(ok.projects.length, 3);
  for (const [status, code] of [[401, 'sign_in_required'], [403, 'not_authorized'], [404, 'usage_not_deployed'], [429, 'rate_limited'], [503, 'usage_unavailable']]) {
    await assert.rejects(fetchUsage('https://x.example.net/u', 't', { fetchImpl: async () => new Response('{}', { status }) }), { code }, String(status));
  }
  await assert.rejects(fetchUsage('https://x.example.net/u', 't', { fetchImpl: async () => new Response('{"schema":"other"}', { status: 200 }) }),
    { code: 'usage_unavailable' });
  await assert.rejects(fetchUsage('https://x.example.net/u', 't', { fetchImpl: async () => { throw new Error('dns'); } }), { code: 'usage_unavailable' });
});

test('the text names spend, budget, remaining and as-of time, and flags exhausted, stale and partial figures', () => {
  const text = formatUsage(usage);
  assert.match(text, /PILOT1 \/ STD: \$42\.10 of \$100\.00 used \(42\.1%\), \$57\.89 left, as of 2026-10-23 09:55 UTC/);
  assert.match(text, /PILOT2 \/ PRM: .*\[BUDGET EXHAUSTED; figures are older than usual; some usage not yet priced\]/);
  assert.match(text, /NEW1 \/ STD: no budget figures yet/);
  assert.equal(formatUsage({ ...usage, projects: [] }), 'CCOF budget: no active project membership for this account.\n');
});

test('past the soft limit the text warns that requests are slowed; below it, or without the flag, it does not', () => {
  const project = (over) => ({ ...usage.projects[0], ...over });
  const warned = formatUsage({ ...usage, projects: [project({ percentUsed: '85.0', softLimitPercent: 80, softLimitReached: true })] });
  assert.match(warned, /\[WARNING: past the 80% soft limit, requests are slowed until the budget resets\]/);
  for (const over of [{ softLimitPercent: 80, softLimitReached: false }, { softLimitPercent: null, softLimitReached: null }, {}]) {
    assert.doesNotMatch(formatUsage({ ...usage, projects: [project(over)] }), /WARNING/, JSON.stringify(over));
  }
  const exhausted = formatUsage({ ...usage, projects: [project({ exhausted: true, softLimitPercent: 80, softLimitReached: true })] });
  assert.doesNotMatch(exhausted, /WARNING/, 'exhausted replaces the warning');
  assert.match(exhausted, /BUDGET EXHAUSTED/);
});
