import assert from 'node:assert/strict';
import test from 'node:test';
import { validateConfig } from '../src/config.mjs';
import { createTokenService } from '../src/token-service.mjs';
import { settings } from './config.test.mjs';

const clientId = '33333333-3333-4333-8333-333333333333';
const apiScope = `api://${clientId}/access_as_user`;
const guidScope = `${clientId}/access_as_user`;
const now = Date.parse('2026-10-13T12:00:00Z');

for (const separate of [false, true]) {
  for (const mode of ['broker', 'browser', 'device']) {
    test(`${separate ? 'separate' : 'combined'} app ${mode} login and silent refresh use the correct resource`, async () => {
      const config = validateConfig({ ...settings, clientId: separate ? settings.clientId : clientId,
        scope: apiScope });
      const requestedScope = separate ? apiScope : guidScope;
      const account = { tenantId: config.tenantId, homeAccountId: 'test-account' };
      const calls = [];
      let saved, shortLived = false;
      const result = () => ({ account, accessToken: 'synthetic-token',
        scopes: [requestedScope], expiresOn: new Date(now + (shortLived ? 1 : 3_600_000)) });
      const runtime = {
        brokerAvailable: mode === 'broker',
        state: { async load() { return saved; }, async save(value) { saved = value; } },
        async getClient() {
          return {
            async acquireTokenInteractive(request) { calls.push(request); return result(); },
            async acquireTokenByDeviceCode(request) { calls.push(request); return result(); },
            async acquireTokenSilent(request) {
              calls.push(request);
              if (request.forceRefresh) shortLived = false;
              return result();
            },
          };
        },
      };
      const service = createTokenService(config, runtime, { now: () => now });
      await service.login({ deviceCode: mode === 'device' });
      shortLived = true;
      assert.equal(await service.token(), 'synthetic-token');
      assert.equal(calls.length, 3);
      assert.equal(calls[2].forceRefresh, true);
      for (const call of calls) assert.deepEqual(call.scopes, [requestedScope]);
      assert.equal(config.scope, apiScope, 'profile/cache namespace retains the configured scope');
    });
  }
}

test('combined app accepts GUID or api:// self-resource spelling, but never another resource', async () => {
  const config = validateConfig({ ...settings, clientId, scope: apiScope });
  for (const returnedScope of [apiScope, guidScope, `api://${settings.clientId}/access_as_user`,
    `${settings.clientId}/access_as_user`, 'access_as_user']) {
    const runtime = {
      brokerAvailable: false,
      state: { async save() {} },
      async getClient() {
        return { async acquireTokenInteractive() {
          return { accessToken: 'synthetic-token', expiresOn: new Date(now + 3_600_000),
            account: { tenantId: config.tenantId, homeAccountId: 'test-account' },
            scopes: [returnedScope] };
        } };
      },
    };
    const login = () => createTokenService(config, runtime, { now: () => now }).login();
    if ([apiScope, guidScope].includes(returnedScope)) await login();
    else await assert.rejects(login, /valid gateway token/);
  }
});

test('explicit GUID self-resource scope is accepted only for this client and a single delegated scope', () => {
  assert.equal(validateConfig({ ...settings, clientId, scope: guidScope }).scope, guidScope);
  for (const scope of [`${settings.clientId}/access_as_user`, `${clientId}/`,
    `${clientId}/access_as_user?secret=hidden`, `${clientId}/access_as_user other`,
    `${clientId}/.default`]) {
    assert.throws(() => validateConfig({ ...settings, clientId, scope }), /configuration/i);
  }
});
