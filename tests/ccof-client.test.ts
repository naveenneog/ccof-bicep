import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

test('isolated client suite passes without loading native MSAL or making live Azure calls', () => {
  const root = fileURLToPath(new URL('../client/', import.meta.url));
  const env: NodeJS.ProcessEnv = { ...process.env, CCOF_LIVE_TESTS: '0' };
  delete env.NODE_TEST_CONTEXT;
  const result = spawnSync(process.execPath, ['--test', '--test-reporter=tap', 'test/*.test.mjs'], {
    cwd: root, encoding: 'utf8', timeout: 120_000,
    env,
  });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /# fail 0/);
  assert.match(result.stdout, /# cancelled 0/);
  assert.match(result.stdout, /# skipped 0/);
});
