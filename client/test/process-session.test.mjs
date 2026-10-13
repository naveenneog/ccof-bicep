import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

test('a fresh non-interactive process silently acquires after one injected sign-in and stops after logout', () => {
  const root = fileURLToPath(new URL('../', import.meta.url));
  const work = path.join(root, '.test-work', `process-${randomUUID()}`);
  fs.mkdirSync(work, { recursive: true });
  const session = path.join(work, 'fake-session.json');
  const env = { ...process.env };
  delete env.NODE_TEST_CONTEXT;
  const run = (command) => spawnSync(process.execPath,
    [path.join(root, 'test', 'fixtures', 'session-child.mjs'), session, command],
    { env, cwd: work, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 10_000 });
  try {
    const login = run('login');
    assert.equal(login.status, 0);
    assert.equal(JSON.parse(login.stdout).signedIn, true);
    assert.ok(!fs.readFileSync(session, 'utf8').includes('synthetic-process-credential'));
    const token = run('token');
    assert.equal(token.status, 0);
    assert.ok(token.stdout === 'synthetic-process-credential\n', 'Only the fake credential should reach stdout');
    assert.equal(token.stderr, '');
    const status = run('status');
    assert.equal(status.status, 0);
    assert.equal(JSON.parse(status.stdout).accountId, 'fixture-account');
    assert.ok(!status.stdout.includes('synthetic-process-credential'));
    assert.ok(!status.stdout.includes('fixture-private-label'));
    assert.equal(run('logout').status, 0);
    const after = run('token');
    assert.equal(after.status, 1);
    assert.equal(after.stdout, '');
    assert.match(after.stderr, /ccof-token login/);
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
});
