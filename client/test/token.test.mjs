import assert from 'node:assert/strict';
import test from 'node:test';
import { createTokenService } from '../src/token-service.mjs';
import { runCli } from '../src/cli.mjs';

const config = {
  tenantId: '11111111-1111-4111-8111-111111111111',
  scope: 'api://33333333-3333-4333-8333-333333333333/access_as_user',
  helperTtlSeconds: 300, minimumTokenLifetimeSeconds: 360,
  loginTimeoutSeconds: 120, tokenTimeoutSeconds: 30,
};
const now = Date.parse('2026-10-11T12:00:00Z');
const account = { homeAccountId: 'account-id', localAccountId: 'local-id',
  tenantId: config.tenantId, environment: 'login.microsoftonline.com', username: 'not-logged' };
const result = () => ({ accessToken: 'synthetic-credential', account,
  expiresOn: new Date(now + 3_600_000), scopes: [config.scope] });

function fixture({ broker = true, saved = null, failure, tokenResult = result() } = {}) {
  const calls = [];
  let state = saved;
  const client = (mode) => ({
    async acquireTokenInteractive(request) {
      calls.push([mode, 'interactive', request]);
      if (failure?.[mode]) throw failure[mode];
      return tokenResult;
    },
    async acquireTokenByDeviceCode(request) { calls.push([mode, 'device', request]); return tokenResult; },
    async acquireTokenSilent(request) {
      calls.push([mode, 'silent', request]);
      if (failure?.silent) throw failure.silent;
      return tokenResult;
    },
    async removeAccount(value) { calls.push([mode, 'remove', value]); },
  });
  const runtime = {
    brokerAvailable: broker,
    async getClient(mode) { calls.push([mode, 'client']); return client(mode); },
    state: { async load() { return state; }, async save(value) { state = value; },
      async clear() { state = null; } },
    async openBrowser() { calls.push(['browser', 'open']); },
  };
  return { calls, runtime, state: () => state,
    service: createTokenService(config, runtime, { now: () => now }) };
}
const saved = (mode = 'broker') => ({ mode, account, expiresAt: new Date(now + 3_600_000).toISOString() });

test('Windows login prefers broker and persists the selected account without a token', async () => {
  const f = fixture();
  const value = await f.service.login({});
  assert.equal(value.method, 'broker');
  assert.equal(f.calls.find((call) => call[1] === 'interactive')[0], 'broker');
  assert.deepEqual(f.calls.find((call) => call[1] === 'interactive')[2].scopes, [config.scope]);
  assert.equal(f.state().account.homeAccountId, account.homeAccountId);
  assert.ok(!JSON.stringify(f.state()).includes('synthetic-credential'));
  assert.ok(!JSON.stringify(value).includes(account.username));
});

test('broker unavailability falls back to a separate browser client using MSAL-owned loopback', async () => {
  const f = fixture({ failure: { broker: Object.assign(new Error('hidden error'), { errorCode: 'broker_unavailable' }) } });
  await f.service.login({});
  assert.deepEqual(f.calls.filter((call) => call[1] === 'interactive').map((call) => call[0]),
    ['broker', 'browser']);
  const request = f.calls.find((call) => call[0] === 'browser' && call[1] === 'interactive')[2];
  // MSAL 7 rejects redirectUri overrides outside broker flows; it owns the localhost listener.
  assert.equal(request.redirectUri, undefined);
  assert.equal(request.timeout, undefined);
  assert.equal(typeof request.openBrowser, 'function');
  assert.equal(f.state().mode, 'browser');
});

test('without Windows broker login uses the browser, never device code', async () => {
  const f = fixture({ broker: false });
  await f.service.login({});
  assert.equal(f.state().mode, 'browser');
  assert.ok(!f.calls.some((call) => call[1] === 'device'));
});

test('cancelled broker sign-in does not open another window or change the account selection', async () => {
  const f = fixture({ failure: { broker: Object.assign(new Error('private detail'), { errorCode: 'user_cancelled' }) } });
  await assert.rejects(() => f.service.login(), /cancelled/i);
  assert.ok(!f.calls.some((call) => call[0] === 'browser'));
  assert.equal(f.state(), null);
});

test('failed browser sign-in never silently falls back to device code or persists a selection', async () => {
  const f = fixture({ broker: false, failure: { browser: new Error('browser failure') } });
  await assert.rejects(() => f.service.login());
  assert.ok(!f.calls.some((call) => call[1] === 'device'));
  assert.equal(f.state(), null);
});

test('device code requires its explicit login flag and bypasses broker and browser', async () => {
  const f = fixture();
  await f.service.login({ deviceCode: true, onDeviceCode() {} });
  assert.equal(f.state().mode, 'browser');
  assert.equal(f.calls.filter((call) => call[1] === 'device').length, 1);
  assert.ok(!f.calls.some((call) => call[1] === 'interactive'));
});

test('silent token uses only the saved identity and never prompts, even after an error', async () => {
  for (const failure of [undefined, { silent: new Error('sensitive error with synthetic-credential') }]) {
    const f = fixture({ saved: saved(), failure });
    if (failure) await assert.rejects(() => f.service.token(), /ccof-token login/);
    else assert.equal(await f.service.token(), 'synthetic-credential');
    assert.ok(!f.calls.some((call) => ['interactive', 'device', 'open'].includes(call[1])));
    assert.equal(f.calls.find((call) => call[1] === 'silent')[2].account.homeAccountId, account.homeAccountId);
    assert.deepEqual(f.calls.find((call) => call[1] === 'silent')[2].scopes, [config.scope]);
  }
});

test('missing sign-in refuses before creating an MSAL client', async () => {
  const f = fixture();
  await assert.rejects(() => f.service.token(), /ccof-token login/);
  assert.equal(f.calls.length, 0);
});

test('an invalid saved method, tenant or account refuses before constructing MSAL', async () => {
  for (const state of [{ mode: 'other', account }, { mode: 'browser', account: null },
    { mode: 'browser', account: { ...account, homeAccountId: '' } },
    { mode: 'browser', account: { ...account, tenantId: 'another-tenant' } }]) {
    const f = fixture({ saved: state });
    await assert.rejects(() => f.service.token(), /ccof-token login/);
    assert.equal(f.calls.length, 0);
  }
});

test('silent result must outlive both helper caches; a near-expiry token is force-refreshed once', async () => {
  const f = fixture({ saved: saved(), tokenResult: { ...result(), expiresOn: new Date(now + 100_000) } });
  await assert.rejects(() => f.service.token(), /lifetime|login/i);
  const calls = f.calls.filter((call) => call[1] === 'silent');
  assert.equal(calls.length, 2);
  assert.equal(calls[1][2].forceRefresh, true);
});

test('a refreshed sufficiently-lived token is returned', async () => {
  const f = fixture({ saved: saved('browser') });
  f.runtime.getClient = async () => ({ async acquireTokenSilent(request) {
    return { ...result(), expiresOn: new Date(now + (request.forceRefresh ? 3_600_000 : 1)) };
  } });
  assert.equal(await f.service.token(), 'synthetic-credential');
});

test('invalid or mismatched token results never reach stdout or persistent state', async () => {
  for (const patch of [
    { accessToken: '' }, { accessToken: 'token\nbanner' }, { expiresOn: null },
    { expiresOn: new Date(now - 1) }, { account: null },
    { account: { ...account, tenantId: 'different-tenant' } },
    { account: { ...account, homeAccountId: 'another-person' } },
    { scopes: ['unrequested-scope'] },
  ]) {
    const f = fixture({ saved: saved(), tokenResult: { ...result(), ...patch } });
    await assert.rejects(() => f.service.token(), /token|sign-in|login/i);
  }
});

test('status reports ids and expiry without acquiring or exposing a token or username', async () => {
  const f = fixture({ saved: saved() });
  const status = await f.service.status();
  assert.equal(status.accountId, account.homeAccountId);
  assert.equal(status.expiresAt, saved().expiresAt);
  assert.equal(status.signedIn, true);
  assert.equal(f.calls.length, 0);
  assert.ok(!JSON.stringify(status).includes('synthetic-credential'));
  assert.ok(!JSON.stringify(status).includes(account.username));
});

test('logout removes this application account and clears selection, not other Windows accounts', async () => {
  const f = fixture({ saved: saved() });
  await f.service.logout();
  assert.equal(f.state(), null);
  assert.equal(f.calls.find((call) => call[1] === 'remove')[2].homeAccountId, account.homeAccountId);
  await assert.rejects(() => f.service.token(), /ccof-token login/);
});

test('logout clears the local selection even when broker sign-out is unavailable', async () => {
  const f = fixture({ saved: saved() });
  f.runtime.getClient = async () => { throw new Error('broker unavailable'); };
  await assert.rejects(() => f.service.logout());
  assert.equal(f.state(), null);
  await assert.rejects(() => f.service.token(), /ccof-token login/);
});

test('failed persistence never allows a successfully acquired credential to reach stdout', async () => {
  const f = fixture({ saved: saved() });
  f.runtime.state.save = async () => { throw new Error('encrypted store locked'); };
  let output = '';
  const exit = await runCli(['token'], { loadService: async () => f.service,
    stdout: (value) => { output += value; }, stderr() {} });
  assert.equal(exit, 1);
  assert.equal(output, '');
});

test('CLI token stdout is exactly the credential and errors name login on stderr only', async () => {
  for (const signedIn of [true, false]) {
    const f = fixture({ saved: signedIn ? saved() : null });
    let stdout = '', stderr = '';
    const exit = await runCli(['token'], { loadService: async () => f.service,
      stdout: (value) => { stdout += value; }, stderr: (value) => { stderr += value; } });
    assert.equal(exit, signedIn ? 0 : 1);
    assert.equal(stdout, signedIn ? 'synthetic-credential\n' : '');
    assert.equal(signedIn ? stderr : /ccof-token login/.test(stderr), signedIn ? '' : true);
  }
});

test('CLI refuses unknown commands and interactive flags on token before loading credentials', async () => {
  for (const args of [[], ['bad'], ['token', '--device-code'], ['token', '--interactive'],
    ['login', '--bad'], ['login', '--device-code', 'extra'],
    ['status', '--device-code'], ['logout', '--device-code']]) {
    let loaded = false, stdout = '', stderr = '';
    const exit = await runCli(args, { loadService: async () => { loaded = true; },
      stdout: (value) => { stdout += value; }, stderr: (value) => { stderr += value; } });
    assert.equal(exit, 2);
    assert.equal(stdout, '');
    assert.match(stderr, /usage/i);
    assert.equal(loaded, false);
  }
});

test('unexpected MSAL or cache errors never echo secrets or personal data', async () => {
  let stdout = '', stderr = '';
  const exit = await runCli(['token'], {
    loadService: async () => { throw new Error('synthetic-credential personal-name'); },
    stdout: (value) => { stdout += value; }, stderr: (value) => { stderr += value; },
  });
  assert.equal(exit, 1);
  assert.equal(stdout, '');
  assert.match(stderr, /ccof-token login/);
  assert.ok(!/synthetic-credential|personal-name/.test(stderr));
});
