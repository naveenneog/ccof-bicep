import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mutations } from './ClientMutationCases.mjs';

const root = fileURLToPath(new URL('../../../', import.meta.url));
const work = path.join(root, 'client', '.test-work', `m-${randomUUID().slice(0, 8)}`);
const clone = path.join(work, 'fixture');
const env = { ...process.env, CCOF_LIVE_TESTS: '0' };
delete env.NODE_TEST_CONTEXT;
const reportPath = process.argv[2] ? path.resolve(process.argv[2])
  : path.join(root, 'client', '.test-work', 'mutation-results.json');
const escaped = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

function run(suite) {
  const processResult = suite === 'node'
    ? spawnSync(process.execPath, ['--test', '--test-reporter=tap', 'test/*.test.mjs'],
      { cwd: path.join(clone, 'client'), env, encoding: 'utf8', timeout: 120_000 })
    : spawnSync('pwsh', ['-NoProfile', '-File', path.join(clone, 'scripts', 'client', 'tests', 'Test-GatewayClients.ps1')],
      { cwd: clone, env, encoding: 'utf8', timeout: 120_000 });
  const output = processResult.stdout + processResult.stderr;
  const counts = suite === 'node'
    ? output.match(/# tests (\d+)[\s\S]*# pass (\d+)[\s\S]*# fail (\d+)[\s\S]*# cancelled (\d+)[\s\S]*# skipped (\d+)/)
    : output.match(/(\d+) passed, (\d+) failed/);
  return { status: processResult.status, output,
    total: counts ? suite === 'node' ? Number(counts[1]) : Number(counts[1]) + Number(counts[2]) : null,
    complete: !!counts && (suite !== 'node' || counts[4] === '0' && counts[5] === '0') };
}

function classify(result, baseline, mutation) {
  const targetFailed = mutation.suite === 'node'
    ? new RegExp(`not ok \\d+ - ${escaped(mutation.target)}`).test(result.output)
    : result.output.includes(`FAIL: ${mutation.target}`);
  if (!result.complete || result.total !== baseline.total) return 'invalid-test-run';
  if (result.status !== 0 && targetFailed) return 'caught';
  return result.status === 0 ? 'survived' : 'wrong-failure';
}

const records = [];
try {
  fs.mkdirSync(clone, { recursive: true });
  for (const relative of ['client/src', 'client/bin', 'client/test', 'scripts/client']) {
    fs.cpSync(path.join(root, relative), path.join(clone, relative), { recursive: true });
  }
  fs.copyFileSync(path.join(root, 'client', 'permissions.json'), path.join(clone, 'client', 'permissions.json'));
  const baseline = { node: run('node'), powershell: run('powershell') };
  for (const [suite, value] of Object.entries(baseline)) {
    assert.equal(value.status, 0, `${suite} baseline failed; no mutation claims are valid`);
    assert.ok(value.complete && value.total > 0, `${suite} baseline did not finish`);
  }
  process.stdout.write(`${JSON.stringify({ event: 'baseline', node: baseline.node.total, powershell: baseline.powershell.total })}\n`);
  const controlFile = path.join(clone, 'client', 'src', 'token-service.mjs');
  const controlSource = fs.readFileSync(controlFile, 'utf8');
  fs.writeFileSync(controlFile, `${controlSource}\nTHIS IS NOT VALID JAVASCRIPT;\n`);
  const control = run('node');
  fs.writeFileSync(controlFile, controlSource);
  assert.equal(classify(control, baseline.node, { suite: 'node', target: '' }), 'invalid-test-run',
    'A module-load failure must never count as a caught mutation');
  for (const mutation of mutations) {
    const file = path.join(clone, mutation.file);
    const original = fs.readFileSync(file, 'utf8');
    let mutated = original.replaceAll('\r\n', '\n');
    try {
      for (const [before, after] of mutation.changes) {
        assert.equal(mutated.split(before).length - 1, 1, `Unique anchor missing: ${mutation.name}`);
        mutated = mutated.replace(before, after);
      }
      fs.writeFileSync(file, mutated);
      const result = run(mutation.suite);
      const verdict = classify(result, baseline[mutation.suite], mutation);
      records.push({ name: mutation.name, suite: mutation.suite, verdict,
        baselineCount: baseline[mutation.suite].total, actualCount: result.total });
    } catch {
      records.push({ name: mutation.name, suite: mutation.suite, verdict: 'invalid-anchor-or-run' });
    } finally {
      fs.writeFileSync(file, original);
    }
    process.stdout.write(`${JSON.stringify(records.at(-1))}\n`);
  }
  fs.mkdirSync(path.dirname(reportPath), { recursive: true });
  fs.writeFileSync(reportPath, JSON.stringify({ baseline: { node: baseline.node.total, powershell: baseline.powershell.total },
    brokenLoadControl: 'correctly-rejected', mutations: records }, null, 2));
  const failures = records.filter((record) => record.verdict !== 'caught');
  process.stdout.write(`${JSON.stringify({ event: 'summary', caught: records.length - failures.length, total: records.length, failures: failures.map((record) => record.name) })}\n`);
  process.exitCode = failures.length ? 1 : 0;
} finally {
  fs.rmSync(work, { recursive: true, force: true });
}
