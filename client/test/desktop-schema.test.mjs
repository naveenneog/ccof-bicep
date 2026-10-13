import assert from 'node:assert/strict';
import test from 'node:test';
import { extractSchema } from '../src/desktop-schema.mjs';

const base = (kinds, extra = '') => `kinds=[${kinds.map((kind) => JSON.stringify(kind)).join(',')}],
  credential=U(R(kinds).optional(),{flatKey:"inferenceCredentialKind"}),
  provider=U(R(providers).optional(),{flatKey:"inferenceProvider"}),
  url=U(S.optional(),{flatKey:"inferenceGatewayBaseUrl"}),
  helper=U(S.optional(),{flatKey:"inferenceCredentialHelper"})${extra}`;

test('Desktop support comes from flatKey schema and its linked enum, not incidental strings', () => {
  const source = base(['static', 'helper-script', 'interactive']) + ' docs="external-idp inferenceIdpOidc";';
  const schema = extractSchema(source);
  assert.equal(schema.credentialKinds.includes('external-idp'), false);
  assert.equal(schema.keys.includes('inferenceIdpOidc'), false);
  assert.ok(schema.keys.includes('inferenceGatewayBaseUrl'));
});

test('Desktop newer schema reports external-idp only when actually declared', () => {
  const schema = extractSchema(base(['helper-script', 'external-idp'],
    ', oidc=U(S.optional(),{flatKey:"inferenceIdpOidc"}), flow=U(S.optional(),{flatKey:"inferenceIdpAuthFlow"})'));
  assert.ok(schema.credentialKinds.includes('external-idp'));
  assert.ok(schema.keys.includes('inferenceIdpOidc'));
  assert.ok(schema.keys.includes('inferenceIdpAuthFlow'));
});

test('unrecognized or incomplete Desktop schema is a refusal, never guessed from a version', () => {
  for (const source of [
    'inferenceProvider inferenceCredentialKind helper-script',
    base(['helper-script']).replace('kinds=[', 'other=['),
    base(['helper-script']).replace('flatKey:"inferenceProvider"', 'flatKey:"unrelated"'),
  ]) assert.throws(() => extractSchema(source), /schema/i);
});
