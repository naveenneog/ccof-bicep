import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

test('the C-9 client contribution requests no Azure, Cosmos or Graph application grants', () => {
  const data = JSON.parse(fs.readFileSync(new URL('../permissions.json', import.meta.url), 'utf8'));
  assert.deepEqual(data, { schemaVersion: 1, kind: 'ccof.assignments', package: 'WP-CLIENT',
    cosmosRoleDefinitions: [], assignments: [] });
});
