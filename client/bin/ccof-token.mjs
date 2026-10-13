#!/usr/bin/env node
import { runCli } from '../src/cli.mjs';

const exitCode = await runCli(process.argv.slice(2));
await Promise.all([new Promise((resolve) => process.stdout.write('', resolve)),
  new Promise((resolve) => process.stderr.write('', resolve))]);
process.exit(exitCode);
