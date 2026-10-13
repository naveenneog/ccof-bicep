import assert from 'node:assert/strict';
import test from 'node:test';
import path from 'node:path';
import { createRuntime, openSystemBrowser } from '../src/msal-runtime.mjs';

const config = { tenantId: '11111111-1111-4111-8111-111111111111',
  clientId: '22222222-2222-4222-8222-222222222222',
  scope: 'api://33333333-3333-4333-8333-333333333333/access_as_user',
  gatewayUrl: 'https://gateway.example.test/anthropic', tokenTimeoutSeconds: 30 };
const configPath = path.resolve('test', 'fixture-config.json');

function libraries({ failPersistence = false, available = true } = {}) {
  const persistenceConfigs = [], clients = [], stores = new Map(), events = [];
  class PublicClientApplication {
    constructor(value) { clients.push(value); }
    async acquireTokenSilent(request) { return { request }; }
    async acquireTokenInteractive(request) { return { request }; }
    async acquireTokenByDeviceCode(request) { return { request }; }
    async signOut(request) { events.push(['signOut', request]); }
  }
  class NativeBrokerPlugin { isBrokerAvailable = available; }
  class PersistenceCachePlugin {
    constructor(persistence) { this.persistence = persistence; }
    async beforeCacheAccess(context) {
      events.push('lock');
      const value = await this.persistence.load();
      if (value) context.tokenCache.deserialize(value);
    }
    async afterCacheAccess(context) {
      try { if (context.cacheHasChanged) await this.persistence.save(context.tokenCache.serialize()); }
      finally { events.push('unlock'); }
    }
  }
  return { clients, persistenceConfigs, stores, events, value: {
    msal: { PublicClientApplication },
    extensions: { NativeBrokerPlugin, PersistenceCachePlugin, DataProtectionScope: { CurrentUser: 'user' },
      PersistenceCreator: { async createPersistence(value) {
        persistenceConfigs.push(value);
        if (failPersistence) throw new Error('secret internal cache failure');
        return { async load() { return stores.get(value.cachePath) ?? null; },
          async save(text) { stores.set(value.cachePath, text); }, async delete() { stores.delete(value.cachePath); } };
      } },
    },
  } };
}

async function runtime(fakes, platform = 'win32', patch = {}) {
  return createRuntime({ ...config, ...patch }, configPath, {
    platform, loadLibraries: async () => fakes.value, mkdir: async () => {},
  });
}

test('native cache configuration is encrypted, user-scoped, namespaced, and has no plaintext fallback', async () => {
  const f = libraries();
  const r = await runtime(f);
  await r.getClient('browser');
  assert.equal(f.persistenceConfigs.length, 2);
  for (const value of f.persistenceConfigs) {
    assert.equal(value.usePlaintextFileOnLinux, false);
    assert.equal(value.dataProtectionScope, 'user');
    assert.equal(value.loggerOptions.piiLoggingEnabled, false);
    assert.equal(typeof value.loggerOptions.loggerCallback, 'function');
    assert.ok(path.isAbsolute(value.cachePath));
    assert.ok(value.serviceName && value.accountName);
  }
  const original = f.persistenceConfigs[0].cachePath;
  for (const field of ['tenantId', 'clientId', 'scope', 'gatewayUrl']) {
    const other = libraries();
    await runtime(other, 'win32', { [field]: 'different-configuration-value' });
    assert.notEqual(other.persistenceConfigs[0].cachePath, original);
  }
});

test('separate config paths cannot share a Keychain or libsecret record protected by different locks', async () => {
  const one = libraries(), two = libraries();
  await runtime(one);
  await createRuntime(config, path.resolve('other-profile', 'config.json'), {
    loadLibraries: async () => two.value, mkdir: async () => {},
  });
  assert.notEqual(one.persistenceConfigs[0].serviceName, two.persistenceConfigs[0].serviceName);
});

test('changing only project hints in one common configuration keeps the same SSO cache namespace', async () => {
  const first = libraries(), second = libraries();
  await runtime(first, 'win32', { project: { id: 'CCOFPILOT01', selectorHeader: 'X-Test-Project' } });
  await runtime(second, 'win32', { project: { id: 'CCOFPILOT02', selectorHeader: 'X-Test-Project' } });
  assert.equal(first.persistenceConfigs[0].serviceName, second.persistenceConfigs[0].serviceName);
});

test('broker is explicit on Windows and browser has a separate MSAL instance without broker configuration', async () => {
  const f = libraries();
  const r = await runtime(f);
  await r.getClient('broker');
  await r.getClient('browser');
  assert.equal(r.brokerAvailable, true);
  assert.equal(f.clients[0].auth.authority, `https://login.microsoftonline.com/${config.tenantId}`);
  assert.ok(f.clients[0].broker.nativeBrokerPlugin);
  assert.equal(f.clients[1].broker, undefined);
  assert.ok(f.clients[1].cache.cachePlugin);
  assert.equal(f.clients[1].system.loggerOptions.piiLoggingEnabled, false);
});

test('unavailable broker refuses rather than silently letting MSAL choose a different flow', async () => {
  const f = libraries({ available: false });
  const r = await runtime(f);
  await assert.rejects(() => r.getClient('broker'), /broker/i);
  assert.equal(f.clients.length, 0);
  const linux = await runtime(libraries(), 'linux');
  assert.equal(linux.brokerAvailable, false);
  await assert.rejects(() => linux.getClient('broker'), /broker/i);
  await assert.rejects(() => linux.getClient('other'), /method/i);
  await assert.rejects(() => runtime(libraries(), 'unsupported-platform'),
    (error) => error.code === 'unsupported_platform');
});

test('secure persistence failure is fatal, never an in-memory or plaintext fallback', async () => {
  const f = libraries({ failPersistence: true });
  await assert.rejects(() => runtime(f), /cache|secure/i);
  assert.equal(f.clients.length, 0);
});

test('state transactions lock across the whole operation and do not overwrite on read failures', async () => {
  const f = libraries();
  const r = await runtime(f);
  await r.runExclusive(async () => {
    assert.equal(await r.state.load(), null);
    await r.state.save({ mode: 'browser', expiresAt: 'test-expiry' });
    f.events.push('inside');
  });
  assert.deepEqual(f.events, ['lock', 'inside', 'unlock']);
  await r.runExclusive(async () => assert.equal((await r.state.load()).mode, 'browser'));
  const key = f.persistenceConfigs[0].cachePath;
  f.stores.set(key, 'corrupted-cache');
  await assert.rejects(() => r.runExclusive(async () => r.state.clear()), /cache/i);
  assert.equal(f.stores.get(key), 'corrupted-cache');
  assert.equal(f.events.at(-1), 'unlock');
});

test('clear selection persists even if remote sign-out fails and the lock is released', async () => {
  const f = libraries();
  const r = await runtime(f);
  await assert.rejects(() => r.runExclusive(async () => {
    await r.state.clear();
    throw new Error('signout unavailable');
  }), /signout/);
  assert.equal(f.events.at(-1), 'unlock');
  await r.runExclusive(async () => assert.equal(await r.state.load(), null));
});

test('logout adapter uses the public-client signOut API, not just browser-cache removal', async () => {
  const f = libraries();
  const r = await runtime(f);
  const client = await r.getClient('broker');
  await client.removeAccount({ nativeAccountId: 'native-id' });
  assert.deepEqual(f.events.at(-1), ['signOut', { account: { nativeAccountId: 'native-id' } }]);
});

test('system-browser launcher never uses a shell and rejects a foreign or insecure authorization URL', async () => {
  const calls = [];
  const launch = async (file, args, options) => { calls.push({ file, args, options }); };
  const url = `https://login.microsoftonline.com/${config.tenantId}/oauth2/v2.0/authorize?x=1&y=2`;
  await openSystemBrowser(url, config.tenantId, 'win32', launch);
  assert.match(calls[0].file, /rundll32(?:\.exe)?$/);
  assert.equal(calls[0].args.at(-1), url);
  assert.equal(calls[0].options.shell, false);
  for (const invalid of ['http://login.microsoftonline.com/', 'https://evil.example.test/',
    `https://evil.example.test/${config.tenantId}/oauth2/v2.0/authorize`,
    'https://login.microsoftonline.com.evil.example.test/', 'https://login.microsoftonline.com/another-tenant/authorize']) {
    await assert.rejects(() => openSystemBrowser(invalid, config.tenantId, 'win32', launch), /browser|authority/i);
  }
  assert.equal(calls.length, 1);
});
