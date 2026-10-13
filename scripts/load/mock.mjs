import { createServer } from 'node:http';

export const mockTokens = Object.freeze({ successToken: 'synthetic-load', deniedToken: 'synthetic-denied', quotaToken: 'synthetic-quota' });

// Loopback only: this is a driver fixture, not an APIM-reachable backend.
export async function startMock({ delayMs = 0, status, bypassAuth = false } = {}) {
  const timers = new Set();
  const server = createServer((req, res) => {
    let bytes = 0;
    req.on('data', chunk => { bytes += chunk.length; if (bytes > 4096) req.destroy(); });
    req.on('end', () => {
      const auth = req.headers.authorization;
      let code = 200;
      let error;
      if (!bypassAuth) {
        if (!Object.values(mockTokens).some(token => auth === `Bearer ${token}`)) code = 401;
        else if (auth === `Bearer ${mockTokens.deniedToken}` || req.headers['x-ccof-project'] === 'LOAD-DENIED') code = 403;
        else if (auth === `Bearer ${mockTokens.quotaToken}`) { code = 403; error = 'budget_exhausted'; }
      }
      if (status !== undefined && (bypassAuth || code === 200)) code = status;
      const timer = setTimeout(() => {
        timers.delete(timer);
        if (!res.destroyed) {
          res.writeHead(code, { 'content-type': 'application/json', ...(code === 302 ? { location: 'http://127.0.0.1:1/' } : {}) });
          res.end(JSON.stringify(error ? { error } : { ok: code === 200 }));
        }
      }, delayMs);
      timers.add(timer);
      res.on('close', () => { clearTimeout(timer); timers.delete(timer); });
    });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return {
    endpoint: `http://127.0.0.1:${server.address().port}/messages`,
    async close() {
      for (const timer of timers) clearTimeout(timer);
      server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
    },
  };
}
