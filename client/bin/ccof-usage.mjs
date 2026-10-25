#!/usr/bin/env node
// ccof-usage [--json]: the signed-in developer's own CCOF budget use (docs/USAGE-SELF-SERVICE.md).
import { ClientError } from '../src/errors.mjs';
import { loadConfig } from '../src/config.mjs';
import { createTokenService } from '../src/token-service.mjs';
import { fetchUsage, formatUsage, usageUrl } from '../src/usage.mjs';

const args = process.argv.slice(2);
let exitCode = 0;
if (args.length > 1 || (args.length === 1 && args[0] !== '--json')) {
  process.stderr.write('Usage: ccof-usage [--json]\n');
  exitCode = 2;
} else {
  try {
    const { config, configPath } = await loadConfig();
    const { createRuntime } = await import('../src/msal-runtime.mjs');
    const runtime = await createRuntime(config, configPath, { report: (code) => process.stderr.write(`${code}\n`) });
    const token = await createTokenService(config, runtime).token();
    const usage = await fetchUsage(usageUrl(config), token);
    process.stdout.write(args[0] === '--json' ? `${JSON.stringify(usage, null, 2)}\n` : formatUsage(usage));
  } catch (error) {
    process.stderr.write(error instanceof ClientError ? `${error.code}: ${error.message}\n`
      : 'usage_unavailable: Cannot read usage. Run ccof-token login and retry.\n');
    exitCode = 1;
  }
}
await new Promise((resolve) => process.stdout.write('', resolve));
process.exit(exitCode);
