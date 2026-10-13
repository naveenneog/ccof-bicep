import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { ClientError } from './errors.mjs';

const guid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const deployment = /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$/;
const keys = ['schemaVersion', 'tenantId', 'clientId', 'scope', 'gatewayUrl',
  'helperTtlSeconds', 'minimumTokenLifetimeSeconds', 'loginTimeoutSeconds',
  'tokenTimeoutSeconds', 'disableNonessentialTraffic', 'models', 'desktop'];
const object = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const positiveInteger = (value) => Number.isSafeInteger(value) && value > 0;

function invalid(field) {
  throw new ClientError('invalid_configuration',
    `Invalid client configuration: ${field}. Review the administrator's config and run ccof-token login.`);
}

export function validateConfig(value) {
  if (!object(value) || Object.keys(value).some((key) => !keys.includes(key) && key !== 'project')) invalid('keys');
  for (const key of keys) if (!Object.hasOwn(value, key)) invalid(key);
  if (value.schemaVersion !== 1) invalid('schemaVersion');
  if (!guid.test(value.tenantId ?? '') || !guid.test(value.clientId ?? '')) invalid('tenantId/clientId');
  let gateway, scope;
  try { gateway = new URL(value.gatewayUrl); scope = new URL(value.scope); }
  catch { invalid('gatewayUrl/scope'); }
  if (typeof value.gatewayUrl !== 'string' || /\s/.test(value.gatewayUrl) ||
      gateway.protocol !== 'https:' || gateway.username || gateway.password ||
      gateway.search || gateway.hash || /\/v1(?:\/messages)?\/?$/.test(gateway.pathname)) invalid('gatewayUrl');
  if (typeof value.scope !== 'string' || /\s/.test(value.scope) ||
      !['api:', 'https:'].includes(scope.protocol) || !scope.hostname ||
      !scope.pathname || scope.pathname === '/' || scope.search || scope.hash ||
      scope.username || scope.password) invalid('scope');
  for (const key of ['helperTtlSeconds', 'minimumTokenLifetimeSeconds', 'loginTimeoutSeconds', 'tokenTimeoutSeconds']) {
    if (!positiveInteger(value[key]) || value[key] * 1000 > 2_147_483_647) invalid(key);
  }
  if (value.minimumTokenLifetimeSeconds <= value.helperTtlSeconds) invalid('minimumTokenLifetimeSeconds');
  if (typeof value.disableNonessentialTraffic !== 'boolean') invalid('disableNonessentialTraffic');
  const models = value.models;
  if (!object(models) || Object.keys(models).some((key) =>
      !['default', 'opus', 'sonnet', 'haiku', 'available', 'capabilities'].includes(key)) ||
      !Array.isArray(models.available) || !models.available.length ||
      models.available.some((model) => typeof model !== 'string' || !deployment.test(model)) ||
      new Set(models.available).size !== models.available.length) invalid('models.available');
  for (const alias of ['default', 'opus', 'sonnet', 'haiku']) {
    if (!models.available.includes(models[alias])) invalid(`models.${alias}`);
  }
  if (models.capabilities !== undefined && (!object(models.capabilities) ||
      Object.entries(models.capabilities).some(([alias, caps]) =>
        !['opus', 'sonnet', 'haiku'].includes(alias) || typeof caps !== 'string' ||
        !/^[a-z_]+(?:,[a-z_]+)*$/.test(caps)))) invalid('models.capabilities');
  if (!object(value.desktop) || Object.keys(value.desktop).some((key) => !['profileId', 'profileName'].includes(key)) ||
      !guid.test(value.desktop.profileId ?? '') ||
      typeof value.desktop.profileName !== 'string' || !value.desktop.profileName.trim() ||
      /[\r\n]/.test(value.desktop.profileName)) invalid('desktop');
  if (Object.hasOwn(value, 'project')) {
    const project = value.project;
    const reserved = ['authorization', 'proxy-authorization', 'x-api-key', 'api-key', 'cookie',
      'set-cookie', 'host', 'content-type', 'content-length', 'connection', 'transfer-encoding',
      'anthropic-version', 'anthropic-beta'];
    if (!object(project) || Object.keys(project).some((key) => !['id', 'selectorHeader'].includes(key)) ||
        !Object.hasOwn(project, 'id') || (project.id !== null &&
          (typeof project.id !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/.test(project.id))) ||
        typeof project.selectorHeader !== 'string' || !/^[A-Za-z][A-Za-z0-9-]{0,63}$/.test(project.selectorHeader) ||
        reserved.includes(project.selectorHeader.toLowerCase())) invalid('project');
  }
  return { ...value, gatewayUrl: gateway.toString().replace(/\/+$/, '') };
}

export function defaultConfigPath(env = process.env, platform = process.platform, home = os.homedir()) {
  if (Object.hasOwn(env, 'CCOF_CONFIG_FILE')) {
    if (!env.CCOF_CONFIG_FILE || !path.isAbsolute(env.CCOF_CONFIG_FILE)) {
      throw new ClientError('invalid_configuration', 'CCOF_CONFIG_FILE must be an absolute configuration file path.');
    }
    return env.CCOF_CONFIG_FILE;
  }
  if (platform === 'win32') {
    if (!env.LOCALAPPDATA) invalid('LOCALAPPDATA');
    return path.join(env.LOCALAPPDATA, 'ClaudeGateway', 'config.json');
  }
  if (platform === 'darwin') return path.join(home, 'Library', 'Application Support', 'ClaudeGateway', 'config.json');
  return path.join(env.XDG_CONFIG_HOME || path.join(home, '.config'), 'claude-gateway', 'config.json');
}

export async function loadConfig(configPath = defaultConfigPath()) {
  let value;
  try { value = JSON.parse((await fs.readFile(configPath, 'utf8')).replace(/^\uFEFF/, '')); }
  catch {
    throw new ClientError('configuration_unreadable',
      'Cannot read client configuration. Set CCOF_CONFIG_FILE to the administrator-provided JSON file.');
  }
  return { config: validateConfig(value), configPath: path.resolve(configPath) };
}
