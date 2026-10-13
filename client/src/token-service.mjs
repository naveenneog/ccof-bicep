import { bounded, ClientError, signInRequired } from './errors.mjs';

export function createTokenService(config, runtime, { now = Date.now } = {}) {
  const scopes = [config.scope];
  function checkResult(result, expectedAccount) {
    if (!result || typeof result.accessToken !== 'string' || !result.accessToken ||
        /\s/.test(result.accessToken) || !(result.expiresOn instanceof Date) ||
        !Number.isFinite(result.expiresOn.getTime()) || !result.account?.homeAccountId ||
        result.account.tenantId !== config.tenantId ||
        (expectedAccount && result.account.homeAccountId !== expectedAccount.homeAccountId) ||
        !result.scopes?.some((scope) => scope.toLowerCase() === config.scope.toLowerCase())) {
      throw new ClientError('invalid_token_result', 'No valid gateway token was returned. Run ccof-token login.');
    }
  }
  function sufficientLifetime(result) {
    return result.expiresOn.getTime() - now() > config.minimumTokenLifetimeSeconds * 1000;
  }
  function selectedState(result, mode) {
    const { homeAccountId, localAccountId, tenantId, environment, username, nativeAccountId } = result.account;
    return { mode, account: { homeAccountId, localAccountId, tenantId, environment, username, nativeAccountId },
      expiresAt: result.expiresOn.toISOString() };
  }
  async function selection() {
    const saved = await runtime.state.load();
    if (!saved || !['broker', 'browser'].includes(saved.mode) ||
        saved.account?.tenantId !== config.tenantId || !saved.account?.homeAccountId) throw signInRequired();
    return saved;
  }
  function statusOf(saved) {
    return { signedIn: !!saved, accountId: saved?.account.homeAccountId ?? null,
      method: saved?.mode ?? null, expiresAt: saved?.expiresAt ?? null,
      expired: saved ? Date.parse(saved.expiresAt) <= now() : null };
  }
  const methods = {
    async login({ deviceCode = false, onDeviceCode = () => {} } = {}) {
      let mode = 'browser', result;
      if (!deviceCode && runtime.brokerAvailable) {
        try {
          const broker = await runtime.getClient('broker');
          result = await bounded(() => broker.acquireTokenInteractive({ scopes }), config.loginTimeoutSeconds);
          mode = 'broker';
        } catch (error) {
          if (['user_cancelled', 'user_canceled', 'authentication_canceled'].includes(error?.errorCode)) {
            throw new ClientError('sign_in_cancelled', 'Sign-in was cancelled. Run ccof-token login when ready.');
          }
          runtime.report?.('broker_unavailable_using_browser');
        }
      }
      if (!result) {
        const browser = await runtime.getClient('browser');
        result = await bounded(() => deviceCode
          ? browser.acquireTokenByDeviceCode({ scopes, deviceCodeCallback: onDeviceCode })
          : browser.acquireTokenInteractive({ scopes, openBrowser: runtime.openBrowser }),
        config.loginTimeoutSeconds);
      }
      checkResult(result);
      if (!sufficientLifetime(result)) {
        throw new ClientError('token_lifetime_too_short',
          'The token lifetime is shorter than the configured helper cache. Ask the administrator to review TTLs.');
      }
      const state = selectedState(result, mode);
      await runtime.state.save(state);
      return statusOf(state);
    },
    async token() {
      const saved = await selection();
      let result;
      try {
        const client = await runtime.getClient(saved.mode);
        result = await bounded(() => client.acquireTokenSilent({ scopes, account: saved.account }),
          config.tokenTimeoutSeconds);
        checkResult(result, saved.account);
        if (!sufficientLifetime(result)) {
          result = await bounded(() => client.acquireTokenSilent({ scopes, account: saved.account, forceRefresh: true }),
            config.tokenTimeoutSeconds);
          checkResult(result, saved.account);
        }
      } catch (error) {
        if (error instanceof ClientError) throw error;
        throw signInRequired();
      }
      if (!sufficientLifetime(result)) {
        throw new ClientError('token_lifetime_too_short',
          'No token outlives the helper cache. Run ccof-token login or ask the administrator to review TTLs.');
      }
      await runtime.state.save(selectedState(result, saved.mode));
      return result.accessToken;
    },
    async status() {
      const saved = await runtime.state.load();
      return statusOf(saved);
    },
    async logout() {
      const saved = await runtime.state.load();
      // Clear the local selection even when the broker is offline; token then refuses.
      await runtime.state.clear();
      if (saved) {
        const client = await runtime.getClient(saved.mode);
        await client.removeAccount(saved.account);
      }
      return { signedIn: false };
    },
  };
  return Object.fromEntries(Object.entries(methods).map(([name, method]) => [
    name, (...args) => runtime.runExclusive
      ? runtime.runExclusive(() => method(...args)) : method(...args),
  ]));
}
