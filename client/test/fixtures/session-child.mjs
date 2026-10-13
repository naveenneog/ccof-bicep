import fs from 'node:fs/promises';
import { createTokenService } from '../../src/token-service.mjs';
import { runCli } from '../../src/cli.mjs';

const [file, command] = process.argv.slice(2);
const config = { tenantId: '11111111-1111-4111-8111-111111111111',
  scope: 'api://33333333-3333-4333-8333-333333333333/access_as_user',
  helperTtlSeconds: 300, minimumTokenLifetimeSeconds: 360, loginTimeoutSeconds: 10, tokenTimeoutSeconds: 10 };
const account = { homeAccountId: 'fixture-account', localAccountId: 'fixture-local',
  tenantId: config.tenantId, environment: 'login.microsoftonline.com', username: 'fixture-private-label' };
const result = () => ({ account, accessToken: 'synthetic-process-credential',
  expiresOn: new Date(Date.now() + 3_600_000), scopes: [config.scope] });
const state = {
  async load() { try { return JSON.parse(await fs.readFile(file, 'utf8')); } catch (error) { if (error.code === 'ENOENT') return null; throw error; } },
  async save(value) { await fs.writeFile(file, JSON.stringify(value)); },
  async clear() { await fs.writeFile(file, 'null'); },
};
const client = {
  async acquireTokenInteractive() { if (command !== 'login') throw new Error('Unexpected interactive call'); return result(); },
  async acquireTokenSilent(request) {
    if (!(await state.load()) || request.account.homeAccountId !== account.homeAccountId) throw new Error('No fixture session');
    return result();
  },
  async acquireTokenByDeviceCode() { throw new Error('Device code not requested'); },
  async removeAccount() {},
};
const service = createTokenService(config, { state, brokerAvailable: false,
  async getClient() { return client; }, async openBrowser() { throw new Error('No real browser in tests'); } });
process.exitCode = await runCli([command], { loadService: async () => service });
