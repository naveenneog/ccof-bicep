import { performance } from 'node:perf_hooks';
import { setTimeout as sleep } from 'node:timers/promises';
import { pathToFileURL } from 'node:url';
import { mockTokens, startMock } from './mock.mjs';

const numeric = {
  duration: [15, 0.05, 30], concurrency: [20, 1, 100],
  'max-requests': [3000, 5, 10000], 'wall-seconds': [90, 0.1, 120],
  'timeout-ms': [2000, 10, 10000], 'max-error-rate': [0.05, 0, 1],
  'p95-ms': [2000, 1, 10000], 'max-rss-mb': [256, 1, 1024],
};
const names = { 'max-requests': 'maxRequests', 'wall-seconds': 'wallSeconds',
  'timeout-ms': 'timeoutMs', 'max-error-rate': 'maxErrorRate', 'p95-ms': 'p95Ms', 'max-rss-mb': 'maxRssMb' };
const text = new Set(['target', 'endpoint', 'rates', 'project', 'denied-project', 'quota-project', 'model', 'person-id', 'quota-status', 'quota-error']);

export function parseOptions(args) {
  const values = {};
  for (let i = 0; i < args.length; i++) {
    const key = args[i].replace(/^--/, '');
    if (!args[i].startsWith('--') || Object.hasOwn(values, key)) throw new Error('invalid_option');
    if (['confirm-isolated-mock', 'token-stdin'].includes(key)) values[key] = true;
    else if (numeric[key] || text.has(key)) {
      if (!args[i + 1] || args[i + 1].startsWith('--')) throw new Error('missing_option_value');
      values[key] = args[++i];
    } else throw new Error('unknown_option');
  }
  const options = { target: values.target ?? 'local-mock', endpoint: values.endpoint,
    rates: (values.rates ?? '10,50,100').split(',').map(Number),
    project: values.project ?? 'LOAD-ALLOW', deniedProject: values['denied-project'] ?? 'LOAD-DENIED',
    quotaProject: values['quota-project'] ?? 'LOAD-QUOTA', model: values.model ?? 'load-mock-model',
    personId: values['person-id'], quotaStatus: Number(values['quota-status'] ?? 403),
    quotaError: values['quota-error'] ?? 'budget_exhausted', tokenStdin: !!values['token-stdin'] };
  for (const [key, [fallback, min, max]] of Object.entries(numeric)) {
    const value = Number(values[key] ?? fallback);
    if (!Number.isFinite(value) || value < min || value > max ||
      (['concurrency', 'max-requests', 'timeout-ms'].includes(key) && !Number.isInteger(value))) throw new Error('invalid_bound');
    options[names[key] ?? key] = value;
  }
  if (!['local-mock', 'gateway-mock', 'resolver-mock'].includes(options.target)) throw new Error('invalid_target');
  if (!options.rates.length || options.rates.length > 3 || options.rates.some(r => !Number.isFinite(r) || r < 1 || r > 100)) throw new Error('invalid_rates');
  if (![403, 429].includes(options.quotaStatus)) throw new Error('invalid_quota_status');
  for (const value of [options.project, options.deniedProject, options.quotaProject, options.model, options.quotaError]) {
    if (!/^[A-Za-z0-9_.-]{1,64}$/.test(value)) throw new Error('invalid_identifier');
  }
  if (options.target === 'local-mock') {
    if (options.endpoint || options.tokenStdin) throw new Error('local_mock_has_no_external_endpoint_or_credentials');
  } else {
    if (!values['confirm-isolated-mock'] || !options.endpoint) throw new Error('isolated_mock_confirmation_required');
    const url = new URL(options.endpoint);
    if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash ||
      /(^|\.)(ai\.azure\.com|cognitiveservices\.azure\.com|openai\.azure\.com|anthropic\.com)$/.test(url.hostname)) throw new Error('unsafe_endpoint');
    if (options.target === 'resolver-mock' && !/^[0-9a-f-]{36}$/i.test(options.personId ?? '')) throw new Error('resolver_person_id_required');
    if (!options.tokenStdin) throw new Error('tokens_must_use_stdin');
  }
  return options;
}

export function summarize(samples, seconds) {
  const durations = samples.map(s => s.ms).sort((a, b) => a - b);
  const percentile = p => durations.length ? Math.round(durations[Math.ceil(durations.length * p) - 1] * 100) / 100 : null;
  const errors = {};
  const statusCounts = {};
  let successful = 0;
  for (const sample of samples) {
    statusCounts[sample.status] = (statusCounts[sample.status] ?? 0) + 1;
    if (sample.category === 'success') successful++;
    else errors[sample.category] = (errors[sample.category] ?? 0) + 1;
  }
  return { completed: samples.length, successful, errors, statusCounts,
    completedRps: seconds > 0 ? samples.length / seconds : 0,
    successRps: seconds > 0 ? successful / seconds : 0,
    latencyMs: { p50: percentile(0.5), p95: percentile(0.95), p99: percentile(0.99) } };
}

function category(status) {
  if (status === 200) return 'success';
  if (status === 401) return 'auth401';
  if (status === 403) return 'refusal403';
  if (status === 429) return 'quota429';
  if (status >= 300 && status < 400) return 'redirect';
  if (status >= 500) return 'server5xx';
  return 'otherHttp';
}

async function request(endpoint, options, token, project, signal) {
  const start = performance.now();
  const timeout = AbortSignal.timeout(options.timeoutMs);
  try {
    const response = await fetch(endpoint, {
      method: 'POST', redirect: 'manual', signal: AbortSignal.any([signal, timeout]),
      headers: { 'content-type': 'application/json', 'x-ccof-project': project,
        'anthropic-version': '2023-06-01', ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: JSON.stringify(options.target === 'resolver-mock' ? { personId: options.personId, projectId: project } :
        { model: options.model, max_tokens: 1, stream: false, messages: [{ role: 'user', content: 'OK' }] }),
    });
    const chunks = [];
    let bytes = 0;
    for await (const chunk of response.body ?? []) {
      bytes += chunk.length;
      if (bytes > 65536) throw new Error('response_limit');
      chunks.push(chunk);
    }
    let code;
    try { const body = JSON.parse(Buffer.concat(chunks).toString()); code = typeof body.error === 'string' ? body.error : body.error?.type; } catch { /* Bodies are never reported. */ }
    return { ms: performance.now() - start, status: response.status, category: category(response.status), code };
  } catch (error) {
    return { ms: performance.now() - start, status: 0,
      category: signal.aborted ? 'cancelled' : timeout.aborted ? 'timeout' : error.message === 'response_limit' ? 'responseLimit' : 'network' };
  }
}

export async function runLoad(options, injected = {}) {
  let mock;
  if (!injected.endpoint && options.target === 'local-mock') mock = await startMock();
  const endpoint = injected.endpoint ?? mock?.endpoint ?? options.endpoint;
  const tokens = injected.tokens ?? mockTokens;
  const start = performance.now();
  const controller = new AbortController();
  let stopReason = 'completed';
  let requestsStarted = 0, peakConcurrency = 0, peakRssBytes = process.memoryUsage().rss;
  const stop = reason => { if (!controller.signal.aborted) { stopReason = reason; controller.abort(); } };
  const wall = setTimeout(() => stop('wall-time'), options.wallSeconds * 1000);
  const interrupt = () => stop('interrupted');
  process.on('SIGINT', interrupt);
  process.on('SIGTERM', interrupt);
  const samples = [], stages = [], checks = [];
  const pending = new Set();
  let dropped = 0;
  const launch = (token, project) => {
    if (controller.signal.aborted || requestsStarted >= options.maxRequests) return null;
    requestsStarted++;
    peakConcurrency = Math.max(peakConcurrency, pending.size + 1);
    return request(endpoint, options, token, project, controller.signal);
  };
  try {
    if (!injected.skipChecks) {
      for (const [name, token, project, status] of [
        ['no-auth', null, options.project, 401], ['invalid-auth', 'invalid', options.project, 401],
        ['cross-project', tokens.successToken, options.deniedProject, 403],
        ['denied-identity', tokens.deniedToken, options.project, 403],
        ['quota', tokens.quotaToken, options.quotaProject, options.quotaStatus],
      ]) {
        const sample = await launch(token, project);
        const passed = sample?.status === status && (name !== 'quota' || sample.code === options.quotaError);
        checks.push({ name, expectedStatus: status, actualStatus: sample?.status ?? 0, passed });
        if (!passed) { stop('correctness'); break; }
      }
    }
    for (const rate of options.rates) {
      if (controller.signal.aborted) break;
      const stageStart = performance.now(), offset = samples.length;
      const attempts = Math.ceil(rate * options.duration);
      let stageDropped = 0;
      for (let slot = 0; slot < attempts && !controller.signal.aborted; slot++) {
        const wait = stageStart + slot * 1000 / rate - performance.now();
        if (wait > 0) await sleep(wait, undefined, { signal: controller.signal }).catch(() => {});
        if (controller.signal.aborted) break;
        peakRssBytes = Math.max(peakRssBytes, process.memoryUsage().rss);
        if (peakRssBytes > options.maxRssMb * 1024 * 1024) { stop('memory'); break; }
        if (requestsStarted >= options.maxRequests) { stop('request-cap'); break; }
        if (pending.size >= options.concurrency) { dropped++; stageDropped++; continue; }
        const task = launch(tokens.successToken, options.project).then(sample => {
          samples.push(sample);
          if (sample.status === 401 || sample.status === 403) stop('steady-authorization');
          const current = samples.slice(offset);
          if (current.length >= 20) {
            const summary = summarize(current, (performance.now() - stageStart) / 1000);
            if ((current.length - summary.successful) / current.length > options.maxErrorRate) stop('error-rate');
            else if (summary.latencyMs.p95 > options.p95Ms) stop('p95-latency');
          }
        }).finally(() => pending.delete(task));
        pending.add(task);
        peakConcurrency = Math.max(peakConcurrency, pending.size);
      }
      await Promise.all(pending);
      const hold = stageStart + options.duration * 1000 - performance.now();
      if (hold > 0 && !controller.signal.aborted) await sleep(hold, undefined, { signal: controller.signal }).catch(() => {});
      const stageSummary = summarize(samples.slice(offset), (performance.now() - stageStart) / 1000);
      stages.push({ offeredRps: rate, dropped: stageDropped, ...stageSummary });
      if (stageSummary.latencyMs.p95 > options.p95Ms) stop('p95-latency');
    }
  } finally {
    clearTimeout(wall);
    process.removeListener('SIGINT', interrupt);
    process.removeListener('SIGTERM', interrupt);
    await Promise.all(pending);
    if (mock) await mock.close();
  }
  const elapsedSeconds = (performance.now() - start) / 1000;
  const correctness = { passed: injected.skipChecks ? false : checks.length === 5 && checks.every(c => c.passed), checks };
  const steadySeconds = stages.reduce((sum, stage) => sum + (stage.completedRps ? stage.completed / stage.completedRps : options.duration), 0);
  return { schema: 'ccof.bounded-load.v1', target: options.target,
    evidence: options.target === 'local-mock' ? 'driver-fixture-only' : 'mock-backed-control-plane-only',
    passed: correctness.passed && stopReason === 'completed' && samples.length > 0 && samples.every(s => s.status === 200) && dropped === 0,
    stopReason, elapsedSeconds, requestsStarted, peakConcurrency, dropped,
    bounds: { maxRequests: options.maxRequests, concurrency: options.concurrency, wallSeconds: options.wallSeconds, timeoutMs: options.timeoutMs },
    memory: { peakRssBytes: Math.max(peakRssBytes, process.memoryUsage().rss), endHeapBytes: process.memoryUsage().heapUsed },
    correctness, steady: summarize(samples, steadySeconds), stages };
}

async function readTokens(options) {
  let input = '';
  const timer = setTimeout(() => process.stdin.destroy(), 10000);
  try {
    for await (const chunk of process.stdin) {
      input += chunk;
      if (input.length > 32768) throw new Error('token_input_too_large');
    }
    const tokens = JSON.parse(input);
    const duration = Math.ceil(options.wallSeconds + 30);
    for (const key of Object.keys(mockTokens)) {
      if (typeof tokens[key] !== 'string' || !/^[A-Za-z0-9_.-]+$/.test(tokens[key])) throw new Error('invalid_token_input');
      const claims = JSON.parse(Buffer.from(tokens[key].split('.')[1], 'base64url').toString());
      const remaining = claims.exp - Date.now() / 1000;
      if (!Number.isFinite(remaining) || remaining < duration || remaining > 7200) throw new Error('short_lived_token_required');
    }
    return tokens;
  } finally { input = ''; clearTimeout(timer); }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const options = parseOptions(process.argv.slice(2));
    const tokens = options.tokenStdin ? await readTokens(options) : undefined;
    const report = await runLoad(options, tokens ? { tokens } : {});
    console.log(JSON.stringify(report));
    process.exitCode = report.passed ? 0 : 1;
  } catch {
    console.log(JSON.stringify({ schema: 'ccof.bounded-load.v1', passed: false, stopReason: 'invalid-config-or-token-input' }));
    process.exitCode = 2;
  }
}
