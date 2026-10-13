import fs from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { ClientError } from './errors.mjs';

async function launch(file, args, options) {
  await new Promise((resolve, reject) => {
    const child = spawn(file, args, options);
    child.once('error', reject);
    child.once('exit', (code) => code === 0 ? resolve() : reject(new Error('browser_start_failed')));
  });
}

export async function openSystemBrowser(url, tenantId, platform = process.platform, start = launch) {
  const authority = new URL(url);
  if (authority.protocol !== 'https:' || authority.hostname !== 'login.microsoftonline.com' ||
      authority.username || authority.password || !authority.pathname.startsWith(`/${tenantId}/`)) {
    throw new ClientError('invalid_browser_authority', 'Refusing to open an unexpected sign-in browser authority.');
  }
  const command = platform === 'win32' ? ['rundll32.exe', 'url.dll,FileProtocolHandler', url]
    : platform === 'darwin' ? ['open', url] : ['xdg-open', url];
  await start(command[0], command.slice(1), { shell: false, stdio: 'ignore', windowsHide: true });
}

async function loadLibraries() {
  const [msal, extensions] = await Promise.all([
    import('@azure/msal-node'), import('@azure/msal-node-extensions'),
  ]);
  return { msal, extensions };
}

export async function createRuntime(config, configPath, {
  platform = process.platform, loadLibraries: load = loadLibraries, mkdir = fs.mkdir,
  report = () => {},
} = {}) {
  if (!['win32', 'darwin', 'linux'].includes(platform)) {
    throw new ClientError('unsupported_platform', 'This helper requires Windows, macOS, or Linux secure storage.');
  }
  const { msal, extensions } = await load();
  const namespace = createHash('sha256').update(JSON.stringify([
    config.tenantId, config.clientId, config.scope, config.gatewayUrl, path.resolve(configPath),
  ])).digest('hex');
  const directory = path.join(path.dirname(configPath), 'cache', namespace);
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const loggerOptions = { loggerCallback: () => {}, piiLoggingEnabled: false };
  async function persistence(name) {
    try {
      return await extensions.PersistenceCreator.createPersistence({
        cachePath: path.join(directory, `${name}.bin`),
        dataProtectionScope: extensions.DataProtectionScope.CurrentUser,
        serviceName: `ccof-token-${namespace}`, accountName: name,
        usePlaintextFileOnLinux: false, loggerOptions,
      });
    } catch {
      throw new ClientError('secure_cache_unavailable',
        'The OS secure cache is unavailable. Unlock the Windows profile, Keychain, or Secret Service and run ccof-token login. Plaintext fallback is disabled.');
    }
  }
  const statePersistence = await persistence('account');
  const lockOptions = { retryNumber: config.tokenTimeoutSeconds, retryDelay: 1000 };
  const clients = new Map();
  let transaction, queue = Promise.resolve();
  function activeTransaction() {
    if (!transaction) throw new ClientError('cache_transaction_required', 'Secure cache access requires a transaction.');
    return transaction;
  }
  return {
    brokerAvailable: platform === 'win32',
    report,
    openBrowser: (url) => openSystemBrowser(url, config.tenantId, platform),
    state: {
      async load() { return activeTransaction().value; },
      async save(value) { Object.assign(activeTransaction(), { value, dirty: true }); },
      async clear() { Object.assign(activeTransaction(), { value: null, dirty: true }); },
    },
    runExclusive(operation) {
      const run = queue.then(async () => {
        const state = { value: null, dirty: false };
        const plugin = new extensions.PersistenceCachePlugin(statePersistence, lockOptions);
        const context = { cacheHasChanged: true, tokenCache: {
          serialize: () => JSON.stringify(state.value),
          deserialize: (text) => {
            try { state.value = JSON.parse(text); }
            catch { throw new ClientError('secure_cache_invalid', 'The secure cache is unreadable. Restore or reset it before ccof-token login.'); }
          },
        } };
        try {
          await plugin.beforeCacheAccess(context);
          transaction = state;
          return await operation();
        } finally {
          context.cacheHasChanged = state.dirty;
          await plugin.afterCacheAccess(context);
          transaction = undefined;
        }
      });
      queue = run.catch(() => {});
      return run;
    },
    async getClient(mode) {
      if (!['broker', 'browser'].includes(mode)) throw new ClientError('invalid_sign_in_method', 'Unknown sign-in method.');
      if (clients.has(mode)) return clients.get(mode);
      let nativeBrokerPlugin;
      if (mode === 'broker') {
        if (platform !== 'win32') throw new ClientError('broker_unavailable', 'Windows broker is unavailable.');
        nativeBrokerPlugin = new extensions.NativeBrokerPlugin();
        nativeBrokerPlugin.setLogger?.(loggerOptions);
        if (!nativeBrokerPlugin.isBrokerAvailable) {
          throw new ClientError('broker_unavailable', 'Windows broker is unavailable; use ccof-token login for browser fallback.');
        }
      }
      const pca = new msal.PublicClientApplication({
        auth: { clientId: config.clientId, authority: `https://login.microsoftonline.com/${config.tenantId}` },
        cache: { cachePlugin: new extensions.PersistenceCachePlugin(await persistence('tokens'), lockOptions) },
        system: { loggerOptions },
        ...(nativeBrokerPlugin ? { broker: { nativeBrokerPlugin } } : {}),
      });
      const client = {
        acquireTokenSilent: (request) => pca.acquireTokenSilent(request),
        acquireTokenInteractive: (request) => pca.acquireTokenInteractive(request),
        acquireTokenByDeviceCode: (request) => pca.acquireTokenByDeviceCode(request),
        removeAccount: (account) => pca.signOut({ account }),
      };
      clients.set(mode, client);
      return client;
    },
  };
}
