import { readDesktopSchema } from '../src/desktop-schema.mjs';

try {
  process.stdout.write(`${JSON.stringify(await readDesktopSchema(process.argv[2]))}\n`);
} catch {
  process.stderr.write('Cannot verify the installed Desktop schema. No profile should be written.\n');
  process.exitCode = 1;
}
