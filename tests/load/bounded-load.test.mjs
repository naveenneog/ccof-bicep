import assert from 'node:assert/strict';
import test from 'node:test';
import { spawnSync } from 'node:child_process';
import { parseOptions, runLoad, summarize } from '../../scripts/load/bounded-load.mjs';
import { startMock } from '../../scripts/load/mock.mjs';

test('safe default and strict finite ceilings', () => {
  const options = parseOptions([]);
  assert.equal(options.target, 'local-mock');
  assert.deepEqual(options.rates, [10, 50, 100]);
  for (const args of [
    ['--target', 'foundry'], ['--duration', 'NaN'], ['--concurrency', '101'],
    ['--max-requests', '10001'], ['--wall-seconds', '121'], ['--rates', '101'],
    ['--unknown', 'x'], ['--duration', '0'],
    ['--timeout-ms', '10.5'],
    ['--target', 'gateway-mock', '--endpoint', 'https://gateway.example/messages'],
    ['--target', 'gateway-mock', '--confirm-isolated-mock', '--endpoint', 'https://example-foo.services.ai.azure.com/messages'],
    ['--target', 'gateway-mock', '--confirm-isolated-mock', '--endpoint', 'https://user:secret-at-gateway.example/messages'],
  ]) assert.throws(() => parseOptions(args));
});

test('nearest-rank metrics distinguish refusals from success', () => {
  const report = summarize([
    { ms: 10, category: 'success', status: 200 },
    { ms: 20, category: 'auth401', status: 401 },
    { ms: 30, category: 'quota429', status: 429 },
    { ms: 40, category: 'timeout', status: 0 },
  ], 2);
  assert.deepEqual(report.latencyMs, { p50: 20, p95: 40, p99: 40 });
  assert.equal(report.successRps, 0.5);
  assert.equal(report.completedRps, 2);
  assert.equal(report.errors.timeout, 1);
  assert.equal(report.errors.auth401, 1);
});

test('offline ramp obeys request cap, auth/quota preflight and redaction', async () => {
  const options = parseOptions(['--duration', '0.15', '--max-requests', '12']);
  const report = await runLoad(options);
  assert.equal(report.correctness.passed, true);
  assert.equal(report.correctness.checks.length, 5);
  assert.ok(report.steady.completed <= 7); // Five correctness requests share the cap.
  assert.ok(report.requestsStarted <= 12);
  assert.ok(report.peakConcurrency <= options.concurrency);
  assert.ok(report.memory.peakRssBytes > 0);
  assert.ok(report.steady.latencyMs.p99 !== null);
  const output = JSON.stringify(report);
  assert.ok(!output.includes('Bearer'));
  assert.ok(!output.includes('synthetic-load'));
  assert.ok(!output.includes('messages'));
});

test('wall timeout aborts a stalled response without queue growth', async () => {
  const mock = await startMock({ delayMs: 2000 });
  try {
    const options = parseOptions(['--duration', '1', '--wall-seconds', '0.2', '--timeout-ms', '1000']);
    const report = await runLoad(options, { endpoint: mock.endpoint, skipChecks: true });
    assert.equal(report.stopReason, 'wall-time');
    assert.ok(report.elapsedSeconds < 1);
    assert.ok(report.steady.errors.cancelled >= 1);
    assert.equal(report.steady.errors.timeout ?? 0, 0);
    assert.ok(report.requestsStarted <= options.maxRequests);
  } finally { await mock.close(); }
});

test('individual request timeout remains distinct from shared wall cancellation', async () => {
  const mock = await startMock({ delayMs: 2000 });
  try {
    const options = parseOptions(['--rates', '10', '--duration', '0.1', '--wall-seconds', '1', '--timeout-ms', '50']);
    const report = await runLoad(options, { endpoint: mock.endpoint, skipChecks: true });
    assert.ok(report.steady.errors.timeout >= 1);
    assert.equal(report.steady.errors.cancelled ?? 0, 0);
    assert.equal(report.stopReason, 'completed');
  } finally { await mock.close(); }
});

test('error and p95 stop conditions halt admission', async () => {
  for (const failure of [{ status: 500 }, { delayMs: 30 }]) {
    const mock = await startMock(failure);
    try {
      const options = parseOptions(['--rates', '100', '--duration', '1', '--p95-ms', '1']);
      const report = await runLoad(options, { endpoint: mock.endpoint, skipChecks: true });
      assert.ok(['error-rate', 'p95-latency'].includes(report.stopReason));
      assert.ok(report.requestsStarted < 100);
    } finally { await mock.close(); }
  }
});

test('failed authorization correctness forbids steady traffic', async () => {
  const mock = await startMock({ status: 200, bypassAuth: true });
  try {
    const report = await runLoad(parseOptions(['--duration', '0.1']), { endpoint: mock.endpoint });
    assert.equal(report.correctness.passed, false);
    assert.equal(report.stopReason, 'correctness');
    assert.equal(report.steady.completed, 0);
    assert.equal(report.peakConcurrency, 1);
  } finally { await mock.close(); }
});

test('redirect is never followed with credentials', async () => {
  const mock = await startMock({ status: 302 });
  try {
    const report = await runLoad(parseOptions(['--duration', '0.1']), { endpoint: mock.endpoint, skipChecks: true });
    assert.ok(report.steady.errors.redirect > 0);
  } finally { await mock.close(); }
});

test('small samples still fail the final latency budget', async () => {
  const mock = await startMock({ delayMs: 30 });
  try {
    const report = await runLoad(parseOptions(['--rates', '10', '--duration', '0.1', '--p95-ms', '1']), { endpoint: mock.endpoint });
    assert.equal(report.passed, false);
    assert.equal(report.stopReason, 'p95-latency');
  } finally { await mock.close(); }
});

test('saturation drops offered slots rather than queuing above concurrency cap', async () => {
  const mock = await startMock({ delayMs: 50 });
  try {
    const report = await runLoad(parseOptions(['--rates', '100', '--duration', '0.3', '--concurrency', '1']), { endpoint: mock.endpoint });
    assert.equal(report.peakConcurrency, 1);
    assert.ok(report.dropped > 0);
    assert.equal(report.passed, false);
  } finally { await mock.close(); }
});

test('remote token-input refusal emits no credentials and makes no request', () => {
  const fixture = 'memory-only-not-a-jwt';
  const result = spawnSync(process.execPath, ['scripts/load/bounded-load.mjs',
    '--target', 'gateway-mock', '--confirm-isolated-mock', '--token-stdin',
    '--endpoint', 'https://gateway.example/messages'],
  { cwd: new URL('../..', import.meta.url), input: JSON.stringify({ successToken: fixture, deniedToken: fixture, quotaToken: fixture }), encoding: 'utf8' });
  assert.equal(result.status, 2);
  assert.equal(result.stderr, '');
  assert.ok(!result.stdout.includes(fixture));
  assert.equal(JSON.parse(result.stdout).stopReason, 'invalid-config-or-token-input');
});
