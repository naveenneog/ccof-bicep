// The developer's own CCOF budget use (docs/USAGE-SELF-SERVICE.md). Calls the gateway's usage API
// (GET <gateway origin>/ccof-usage/me/usage) with the same Entra token Claude Code uses; the gateway
// answers for the token's own user only. No figures are cached or written to disk.
import { ClientError } from './errors.mjs';

export const DEFAULT_USAGE_PATH = '/ccof-usage/me/usage';

export function usageUrl(config, env = process.env) {
  const override = env.CCOF_USAGE_URL;
  const url = new URL(override ?? `${new URL(config.gatewayUrl).origin}${DEFAULT_USAGE_PATH}`);
  if (url.protocol !== 'https:' || url.username || url.password || url.hash) {
    throw new ClientError('invalid_usage_url', 'CCOF_USAGE_URL must be an https URL without credentials.');
  }
  return url.toString();
}

export async function fetchUsage(url, token, { fetchImpl = fetch, timeoutMs = 15000 } = {}) {
  let response;
  try {
    response = await fetchImpl(url, { headers: { authorization: `Bearer ${token}`, accept: 'application/json' },
      signal: AbortSignal.timeout(timeoutMs) });
  } catch {
    throw new ClientError('usage_unavailable', 'The gateway usage API did not answer. Try again shortly.');
  }
  if (response.status === 401) throw new ClientError('sign_in_required', 'The gateway refused the token. Run ccof-token login.');
  if (response.status === 403) throw new ClientError('not_authorized', 'This account is not allowed to use the gateway.');
  if (response.status === 404) throw new ClientError('usage_not_deployed', 'The gateway has no usage API yet. Ask the CCOF administrators.');
  if (response.status === 429) throw new ClientError('rate_limited', 'Too many usage checks. Try again in a minute.');
  if (response.status !== 200) throw new ClientError('usage_unavailable', 'Usage is temporarily unavailable. Try again shortly.');
  const body = await response.json().catch(() => null);
  if (!body || body.schema !== 'ccof.usage.me.v1' || !Array.isArray(body.projects)) {
    throw new ClientError('usage_unavailable', 'The gateway returned an unexpected usage response.');
  }
  return body;
}

const when = (iso) => (iso ? `${iso.slice(0, 16).replace('T', ' ')} UTC` : 'unknown time');

export function formatUsage(usage) {
  if (!usage.projects.length) return 'CCOF budget: no active project membership for this account.\n';
  const lines = ['CCOF budget (this month, your own use)'];
  for (const p of usage.projects) {
    const name = `${p.projectId} / ${p.classification}`;
    if (p.state === 'no_budget_state') { lines.push(`  ${name}: no budget figures yet (the reconciler has not reported this project for you).`); continue; }
    if (p.state !== 'available') { lines.push(`  ${name}: figures unavailable.`); continue; }
    const pct = p.percentUsed === null ? '' : ` (${p.percentUsed}%)`;
    const flags = [p.exhausted ? 'BUDGET EXHAUSTED' : '', p.stale ? 'figures are older than usual' : '',
      p.completeness === 'partial' ? 'some usage not yet priced' : ''].filter(Boolean);
    lines.push(`  ${name}: $${p.spentUsd} of $${p.budgetUsd} used${pct}, $${p.remainingUsd} left, as of ${when(p.computedAt)}` +
      (flags.length ? ` [${flags.join('; ')}]` : ''));
  }
  lines.push('  Figures at the approved rate card (100 CCU = USD 1); usage not yet priced is not included.');
  return `${lines.join('\n')}\n`;
}
