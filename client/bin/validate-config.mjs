import { loadConfig } from '../src/config.mjs';

try {
  const { config } = await loadConfig(process.argv[2]);
  process.stdout.write(`${JSON.stringify(config)}\n`);
} catch {
  process.stderr.write('Client configuration is missing or invalid. Review docs/CLIENTS.md.\n');
  process.exitCode = 1;
}
