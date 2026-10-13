import assert from 'node:assert/strict';
import test from 'node:test';
import path from 'node:path';
import { defaultConfigPath, validateConfig } from '../src/config.mjs';

export const settings = {
  schemaVersion: 1,
  tenantId: '11111111-1111-4111-8111-111111111111',
  clientId: '22222222-2222-4222-8222-222222222222',
  scope: 'api://33333333-3333-4333-8333-333333333333/access_as_user',
  gatewayUrl: 'https://gateway.example.test/anthropic',
  helperTtlSeconds: 300,
  minimumTokenLifetimeSeconds: 360,
  loginTimeoutSeconds: 120,
  tokenTimeoutSeconds: 30,
  disableNonessentialTraffic: true,
  models: {
    default: 'deployment-sonnet',
    opus: 'deployment-opus',
    sonnet: 'deployment-sonnet',
    haiku: 'deployment-haiku',
    available: ['deployment-opus', 'deployment-sonnet', 'deployment-haiku'],
    capabilities: { opus: 'thinking,adaptive_thinking', sonnet: 'thinking,adaptive_thinking' },
  },
  desktop: { profileId: '44444444-4444-4444-8444-444444444444', profileName: 'Test gateway' },
};

test('configuration is explicit, preserves the API prefix, and normalizes only trailing slash', () => {
  const config = validateConfig({ ...settings, gatewayUrl: `${settings.gatewayUrl}/` });
  assert.equal(config.gatewayUrl, settings.gatewayUrl);
  assert.equal(config.scope, settings.scope);
  assert.equal(config.models.haiku, 'deployment-haiku');
});

test('every required setting fails closed, without echoing values', () => {
  for (const key of Object.keys(settings)) {
    const config = structuredClone(settings);
    delete config[key];
    assert.throws(() => validateConfig(config), /configuration/i, key);
  }
  assert.throws(() => validateConfig(Object.create(settings)), /configuration/i);
  for (const invalid of [null, [], 'private-input', 7]) assert.throws(() => validateConfig(invalid), /configuration/i);
});

test('configuration rejects invalid identity, URL, scope, lifetime, models and unknown keys', () => {
  const cases = [
    { schemaVersion: 2 },
    { tenantId: 'common' }, { clientId: 'not-an-id' },
    { gatewayUrl: 'http://gateway.example.test/anthropic' },
    { gatewayUrl: 'https://user:credential@gateway.example.test/anthropic' },
    { gatewayUrl: 'https://gateway.example.test/anthropic?credential=hidden' },
    { gatewayUrl: 'https://gateway.example.test/anthropic#hidden' },
    { gatewayUrl: 'https://gateway.example.test/anthropic/v1/messages' },
    { gatewayUrl: 'https://gateway.example.test/anthropic/v1' },
    { scope: 'openid profile' }, { scope: 'file:///hidden' },
    { scope: 'ftp://gateway.example.test/scope' },
    { scope: 'api://scope-only' }, { scope: 'https://user:private@gateway.example.test/scope' },
    { scope: 'https://gateway.example.test/scope?value=private' },
    { scope: 'https://gateway.example.test/scope#private' },
    { gatewayUrl: 'not a URL' }, { gatewayUrl: 'https://gateway.example.test/a b' },
    { helperTtlSeconds: 0 }, { helperTtlSeconds: '300' },
    { helperTtlSeconds: 2_147_484 }, { helperTtlSeconds: 1.5 },
    { minimumTokenLifetimeSeconds: 299 }, { minimumTokenLifetimeSeconds: 300 },
    { loginTimeoutSeconds: -1 }, { tokenTimeoutSeconds: 0 },
    { loginTimeoutSeconds: 2_147_484 },
    { disableNonessentialTraffic: 'true' },
    { models: { ...settings.models, haiku: 'missing-deployment' } },
    { models: { ...settings.models, available: [] } },
    { models: { ...settings.models, available: [...settings.models.available, settings.models.available[0]] } },
    { models: { ...settings.models, capabilities: { invalidAlias: 'thinking' } } },
    { models: { ...settings.models, capabilities: { opus: ['thinking'] } } },
    { models: { ...settings.models, default: 'bad\nmodel' } },
    { desktop: { ...settings.desktop, profileId: '../escape' } },
    { desktop: { ...settings.desktop, profileName: '' } },
    { desktop: { ...settings.desktop, profileName: 'line\nbreak' } },
    { desktop: { ...settings.desktop, token: 'must-not-echo-this' } },
    { models: { ...settings.models, token: 'must-not-echo-this' } },
    { accessToken: 'must-not-echo-this' },
  ];
  for (const patch of cases) {
    assert.throws(() => validateConfig({ ...settings, ...patch }), (error) =>
      /configuration/i.test(error.message) && !error.message.includes('must-not-echo-this'));
  }
});

test('config default is per-user and an explicit environment path wins', () => {
  assert.equal(defaultConfigPath({ CCOF_CONFIG_FILE: path.resolve('explicit.json') }),
    path.resolve('explicit.json'));
  assert.equal(defaultConfigPath({ LOCALAPPDATA: path.resolve('profile') }, 'win32', 'unused'),
    path.resolve('profile', 'ClaudeGateway', 'config.json'));
  assert.equal(defaultConfigPath({}, 'linux', path.resolve('home')),
    path.resolve('home', '.config', 'claude-gateway', 'config.json'));
  assert.throws(() => defaultConfigPath({ CCOF_CONFIG_FILE: 'relative.json' }), /absolute/i);
});

test('optional project profiles accept an explicit selector or explicit clearing, never credential headers', () => {
  const project = { id: 'CCOFPILOT01', selectorHeader: 'X-Test-Project' };
  assert.deepEqual(validateConfig({ ...settings, project }).project, project);
  assert.equal(validateConfig({ ...settings, project: { ...project, id: null } }).project.id, null);
  for (const value of [null, {}, { id: 'CCOFPILOT01' }, { ...project, id: '' },
    { ...project, id: 'other\r\nAuthorization: unsafe' }, { ...project, selectorHeader: 'Authorization' },
    { ...project, id: 'invalid.project' }, { ...project, id: 'A'.repeat(81) },
    { ...project, selectorHeader: 'x-api-key' }, { ...project, selectorHeader: 'bad:header' },
    { ...project, unexpected: true }]) {
    assert.throws(() => validateConfig({ ...settings, project: value }), /configuration/i);
  }
});
