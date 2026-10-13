import fs from 'node:fs/promises';

function unknownSchema() {
  return new Error('Desktop schema is unrecognized or incomplete; no profile may be written.');
}

export function extractSchema(source) {
  const keys = [...new Set([...source.matchAll(/\bflatKey\s*:\s*["']([A-Za-z][A-Za-z0-9]+)["']/g)]
    .map((match) => match[1]))];
  for (const key of ['inferenceProvider', 'inferenceGatewayBaseUrl', 'inferenceCredentialKind']) {
    if (!keys.includes(key)) throw unknownSchema();
  }
  const kindDefinition = source.match(/[\w$]+\((\[[^\]]+\]|[\w$]+)\)\.optional\(\)\s*,\s*\{\s*flatKey\s*:\s*["']inferenceCredentialKind["']/);
  if (!kindDefinition) throw unknownSchema();
  const expression = kindDefinition[1];
  const literal = expression.startsWith('[') ? expression
    : source.match(new RegExp(`(?:^|[^\\w$])${expression.replaceAll('$', '\\$')}\\s*=\\s*(\\[[^\\]]+\\])`))?.[1];
  if (!literal || !/^\[\s*["'][a-z-]+["'](?:\s*,\s*["'][a-z-]+["'])*\s*\]$/.test(literal)) throw unknownSchema();
  const credentialKinds = [...literal.matchAll(/["']([a-z-]+)["']/g)].map((match) => match[1]);
  if (!credentialKinds.includes('helper-script') && !credentialKinds.includes('external-idp')) throw unknownSchema();
  return { keys: keys.sort(), credentialKinds };
}

export async function readDesktopSchema(asarPath) {
  const file = await fs.open(asarPath, 'r');
  try {
    const stat = await file.stat();
    async function read(size, offset) {
      if (!Number.isSafeInteger(size) || !Number.isSafeInteger(offset) ||
          size < 0 || offset < 0 || size > 64 * 1024 * 1024 || offset + size > stat.size) throw unknownSchema();
      const buffer = Buffer.alloc(size);
      const { bytesRead } = await file.read(buffer, 0, size, offset);
      if (bytesRead !== size) throw unknownSchema();
      return buffer;
    }
    const header = await read(16, 0);
    const dataStart = 8 + header.readUInt32LE(4);
    const jsonSize = header.readUInt32LE(12);
    if (header.readUInt32LE(0) !== 4 || dataStart < 16 + jsonSize) throw unknownSchema();
    const tree = JSON.parse((await read(jsonSize, 16)).toString('utf8'));
    const files = tree.files?.['.vite']?.files?.build?.files;
    if (!files) throw unknownSchema();
    const names = Object.keys(files).filter((name) => name.endsWith('.js'));
    names.sort((a, b) => Number(b === 'index.pre.js') - Number(a === 'index.pre.js'));
    for (const name of names) {
      const entry = files[name];
      if (entry.unpacked || entry.link || !entry.size || !/^\d+$/.test(entry.offset)) continue;
      const source = (await read(entry.size, dataStart + Number(entry.offset))).toString('utf8');
      if (!/flatKey\s*:\s*["']inferenceCredentialKind["']/.test(source)) continue;
      return extractSchema(source);
    }
    throw unknownSchema();
  } finally {
    await file.close();
  }
}
