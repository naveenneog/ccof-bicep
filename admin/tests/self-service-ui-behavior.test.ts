import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, rm } from "node:fs/promises";
import { fileURLToPath, pathToFileURL } from "node:url";
import { join } from "node:path";
import { build } from "esbuild";

const GLOBAL = "__ccofSelfServiceTest";
const features = {
  "publish-routing": { state: "available", requirements: [] },
  apply: { state: "available", requirements: [] },
  history: { state: "available", requirements: [] },
};
const job = { id: "a".repeat(64), kind: "apply", projectId: "example", state: "queued", phase: "accepted" };
const props = { projectId: "example", etag: '"current"', readOnly: false, onChanged: () => {}, capabilities: features };

function find(tree: any, name: string, label?: string): any {
  if (Array.isArray(tree)) {
    for (const child of tree) { const result = find(child, name, label); if (result) return result; }
  } else if (tree && typeof tree === "object") {
    if (tree.type?.name === name && (label === undefined || tree.props.children === label)) return tree;
    return find(tree.props?.children, name, label);
  }
  return null;
}

function harness() {
  let index = 0;
  const slots: any[] = [];
  let effects: (() => void)[] = [];
  const timers = new Map<number, { run: () => Promise<void>; delay: number }>();
  const calls: { path: string; options: any }[] = [];
  const store = new Map<string, string>();
  let timerId = 0;
  const h: any = {
    calls, store, timers, queryPaths: [], reloads: 0,
    respond: async () => ({ status: 202, data: job, etag: null }),
    query: (path: string) => {
      h.queryPaths.push(path);
      return { data: { versions: [{ versionId: "saved-v1", sourceEtag: '"old"', createdAt: "2026-11-18T12:00:00Z" }] }, loading: false, error: null, reload: () => h.reloads++ };
    },
    request: (path: string, options: any) => { calls.push({ path, options }); return h.respond(path, options); },
    useState: (initial: any) => {
      const i = index++;
      if (!(i in slots)) slots[i] = typeof initial === "function" ? initial() : initial;
      return [slots[i], (value: any) => { slots[i] = typeof value === "function" ? value(slots[i]) : value; }];
    },
    useRef: (initial: any) => {
      const i = index++;
      if (!(i in slots)) slots[i] = { current: initial };
      return slots[i];
    },
    useEffect: (effect: () => any, deps: any[]) => {
      const i = index++;
      if (!slots[i] || deps.some((d, n) => !Object.is(d, slots[i].deps[n]))) {
        const old = slots[i];
        slots[i] = { deps };
        effects.push(() => { old?.cleanup?.(); slots[i].cleanup = effect(); });
      }
    },
    clock: {
      set: (run: () => Promise<void>, delay: number) => { timers.set(++timerId, { run, delay }); return timerId; },
      clear: (id: number) => timers.delete(id),
    },
    render: (component: any, p: any) => {
      index = 0;
      const tree = component(p);
      const pending = effects; effects = [];
      pending.forEach((effect) => effect());
      return tree;
    },
    flush: () => new Promise((resolve) => setImmediate(resolve)),
    dispose: () => slots.forEach((s) => s?.cleanup?.()),
  };
  (globalThis as any)[GLOBAL] = h;
  (globalThis as any).window = { localStorage: { getItem: (key: string) => store.get(key) ?? null, setItem: (key: string, value: string) => store.set(key, value), removeItem: (key: string) => store.delete(key) } };
  return h;
}

async function reviewedOperation(h: any, Operations: any, p = props) {
  let tree = h.render(Operations, p);
  find(tree, "OperationActions").props.onSelect("apply");
  tree = h.render(Operations, p);
  find(tree, "ReasonField").props.setReason("Apply the reviewed limits");
  tree = h.render(Operations, p);
  find(tree, "Button", "Review operation").props.onClick();
  return h.render(Operations, p);
}

test("self-service review, recovery, polling and independent history controls", async (t) => {
  const directory = await mkdtemp(fileURLToPath(new URL("./.self-service-ui-", import.meta.url)));
  const priorWindow = (globalThis as any).window;
  try {
    const output = join(directory, "behavior.mjs");
    const hGlobal = `globalThis.${GLOBAL}`;
    await build({
      stdin: { contents: `export * from "./self-service-operations.tsx"; export * from "./self-service-history.tsx"; export * from "./self-service-shared.tsx"; export { ApiFailure } from "../lib/api.ts";`,
        resolveDir: fileURLToPath(new URL("../ui-v3/components", import.meta.url)), loader: "tsx" },
      outfile: output, bundle: true, packages: "external", platform: "node", format: "esm", jsx: "automatic", logLevel: "silent",
      banner: { js: `const setTimeout = (...args) => ${hGlobal}.clock.set(...args); const clearTimeout = (...args) => ${hGlobal}.clock.clear(...args);` },
      plugins: [{ name: "controlled-hooks-and-transport", setup(b) {
        b.onResolve({ filter: /^react$/ }, () => ({ path: "hooks", namespace: "test" }));
        b.onResolve({ filter: /\/lib\/api\.ts$/ }, () => ({ path: "api", namespace: "test" }));
        b.onLoad({ filter: /.*/, namespace: "test" }, ({ path }) => ({ contents: path === "hooks" ?
          `export const useState = (...a) => ${hGlobal}.useState(...a), useRef = (...a) => ${hGlobal}.useRef(...a), useEffect = (...a) => ${hGlobal}.useEffect(...a);
           export const createContext = (value) => ({ value }), useContext = (context) => context.value, useId = () => "test-id";` :
          `export class ApiFailure extends Error { constructor(status, body) { super(body.error); this.status = status; this.body = body; this.code = body.error; } }
           export const api = (...a) => ${hGlobal}.request(...a), useQuery = (...a) => ${hGlobal}.query(...a), errorMessage = (e) => e.message;` }));
      } }],
    });
    const ui = await import(pathToFileURL(output).href);

    await t.test("network retry keeps the reviewed body, ETag and key; 202 is pending until polled completion", async () => {
      const h = harness();
      let changed = 0;
      const p = { ...props, onChanged: () => changed++ };
      let postCount = 0, getCount = 0;
      h.respond = async (_path: string, options: any) => {
        if (options.method === "POST") {
          if (++postCount === 1) throw new TypeError("Connection lost");
          return { status: 202, data: job, etag: null };
        }
        return { status: 200, data: { ...job, state: ++getCount === 1 ? "running" : "succeeded", phase: "sync_requested" }, etag: null };
      };
      let tree = await reviewedOperation(h, ui.Operations, p);
      await find(tree, "Review").props.onConfirm();
      tree = h.render(ui.Operations, { ...p, etag: '"newer"' });
      assert.equal(find(tree, "Review").props.confirmLabel, "Retry same request");
      await find(tree, "Review").props.onConfirm();
      assert.equal(changed, 0, "HTTP acceptance must not refresh as a completed mutation");
      const posts = h.calls.filter((c: any) => c.options.method === "POST");
      assert.deepEqual(posts[1], posts[0]);
      assert.equal(posts[1].options.ifMatch, '"current"');
      assert.match(posts[1].options.idempotencyKey, /^[A-Za-z0-9_-]{8,128}$/);
      assert.ok(Object.isFrozen(posts[1].options.body));
      tree = h.render(ui.Operations, p);
      await h.flush();
      tree = h.render(ui.Operations, p);
      assert.equal(find(tree, "OperationProgress").props.job.state, "running");
      assert.equal(changed, 0);
      assert.equal(h.store.get("ccof:self-service:last-job:example"), job.id);
      const [id, timer] = [...h.timers.entries()][0] as any;
      assert.equal(timer.delay, 5_000);
      h.timers.delete(id);
      await timer.run();
      h.render(ui.Operations, p);
      assert.equal(changed, 1);
      assert.equal(h.timers.size, 0, "terminal jobs stop polling");
      assert.equal(postCount, 2, "polling must never repeat side effects");
      h.dispose();
    });

    await t.test("resumes a stored job; blocked grants stay visible and no job is restarted", async () => {
      const h = harness();
      h.store.set("ccof:self-service:last-job:example", job.id);
      const requirements = [{ action: "Microsoft.Web/sites/hostruntime/host/action", scope: "/approved/active-worker" }];
      h.respond = async () => ({ data: { ...job, state: "blocked", reasonCode: "permission_required", requirements }, status: 200 });
      h.render(ui.Operations, props);
      await h.flush();
      const tree = h.render(ui.Operations, props);
      assert.equal(h.calls[0].path, `/api/v3/self-service/jobs/${job.id}`);
      assert.deepEqual(find(tree, "OperationProgress").props.job.requirements, requirements);
      assert.equal(h.timers.size, 0);
      assert.equal(h.calls.length, 1);
      h.dispose();
    });

    await t.test("a late permission denial disables only the rejected operation", async () => {
      const h = harness();
      const requirements = [{ action: "worker/invoke", scope: "/active/only" }];
      h.respond = async () => { throw new ui.ApiFailure(403, { error: "permission_required", requirements }); };
      let tree = await reviewedOperation(h, ui.Operations);
      await find(tree, "Review").props.onConfirm();
      tree = h.render(ui.Operations, props);
      const controls = find(tree, "OperationActions").props;
      assert.equal(controls.capabilities.apply.state, "permission_required");
      assert.deepEqual(controls.capabilities.apply.requirements, requirements);
      assert.equal(controls.capabilities["publish-routing"].state, "available");
      assert.equal(controls.busy, false);
      assert.equal(find(tree, "Review"), null);
      h.dispose();
    });

    await t.test("expired persisted jobs can be dismissed without retrying an operation", async () => {
      const h = harness();
      h.store.set("ccof:self-service:last-job:example", job.id);
      h.respond = async () => { throw new ui.ApiFailure(404, { error: "job_not_found" }); };
      h.render(ui.Operations, props);
      await h.flush();
      let tree = h.render(ui.Operations, props);
      find(tree, "Button", "Dismiss expired job").props.onClick();
      tree = h.render(ui.Operations, props);
      assert.equal(find(tree, "OperationActions").props.busy, false);
      assert.equal(h.store.has("ccof:self-service:last-job:example"), false);
      assert.equal(h.calls.length, 1);
      h.dispose();
    });

    await t.test("the native nested API permission body keeps exact grants and unrelated controls", async () => {
      const h = harness();
      const requirements = [{ action: "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/create", scope: "/dbs/ccof/colls/adminConfig" }];
      h.respond = async () => { throw new ui.ApiFailure(403, {
        error: "feature_unavailable", capability: { state: "permission_required", requirements },
      }); };
      let tree = await reviewedOperation(h, ui.Operations);
      await find(tree, "Review").props.onConfirm();
      tree = h.render(ui.Operations, props);
      const controls = find(tree, "OperationActions").props;
      assert.equal(controls.capabilities.apply.state, "permission_required");
      assert.deepEqual(controls.capabilities.apply.requirements, requirements);
      assert.equal(controls.capabilities["publish-routing"].state, "available");
      assert.equal(find(tree, "Review"), null);
      assert.deepEqual(ui.failureRequirements(new ui.ApiFailure(403, {
        error: "permission_required", capability: { requirements: [null, { action: 42, scope: "bad" }, ...requirements] },
      })), requirements);
      h.dispose();
    });

    await t.test("losing editor access during review prevents submission", async () => {
      const h = harness();
      await reviewedOperation(h, ui.Operations);
      const tree = h.render(ui.Operations, { ...props, readOnly: true });
      assert.equal(find(tree, "Review"), null);
      assert.equal(find(tree, "OperationActions").props.readOnly, true);
      assert.equal(h.calls.length, 0);
      h.dispose();
    });

    await t.test("history uses preview's current ETag and the reviewed reason, not the historical source", async () => {
      const h = harness();
      let changed = 0;
      const p = { ...props, capability: features.history, onChanged: () => changed++ };
      const preview = { versionId: "saved-v1", etag: '"current"', changes: [{ path: "displayName", before: "Current", after: "Saved" }] };
      h.respond = async (path: string) => path.endsWith("/preview") ? { data: preview } :
        { data: { project: { projectId: "example" } }, etag: '"restored"' };
      let tree = h.render(ui.ConfigurationHistory, p);
      await find(tree, "HistoryVersions").props.onPreview("saved-v1");
      tree = h.render(ui.ConfigurationHistory, p);
      find(tree, "ReasonField").props.setReason("Recover reviewed configuration");
      tree = h.render(ui.ConfigurationHistory, p);
      find(tree, "Button", "Review restore").props.onClick();
      tree = h.render(ui.ConfigurationHistory, p);
      assert.deepEqual(find(tree, "Review").props.changes, preview.changes);
      await find(tree, "Review").props.onConfirm();
      assert.equal(h.calls[1].options.ifMatch, '"current"');
      assert.deepEqual(h.calls[1].options.body, { reason: "Recover reviewed configuration" });
      assert.equal(changed, 1);
      assert.equal(h.reloads, 1);
      h.dispose();
    });

    await t.test("readers can list history but cannot preview; stale previews cannot restore", async () => {
      const h = harness();
      const p = { ...props, capability: features.history };
      let tree = h.render(ui.ConfigurationHistory, { ...p, readOnly: true });
      const list = find(tree, "HistoryVersions");
      assert.equal(list.props.readOnly, true);
      await list.props.onPreview("saved-v1");
      assert.equal(h.calls.length, 0);
      tree = h.render(ui.ConfigurationHistory, p);
      h.respond = async () => ({ data: { versionId: "saved-v1", etag: '"different"', changes: [{ path: "displayName", before: "Now", after: "Old" }] } });
      await find(tree, "HistoryVersions").props.onPreview("saved-v1");
      tree = h.render(ui.ConfigurationHistory, p);
      assert.equal(find(tree, "Review"), null);
      assert.equal(find(tree, "Button", "Review restore"), null);
      assert.ok(find(tree, "Button", "Preview current changes"));
      h.dispose();
    });

    await t.test("restore permission refusal preserves history and preview plus its exact required grant", async () => {
      const h = harness();
      const p = { ...props, capability: features.history };
      const requirements = [{ action: "history/restore", scope: "/approved/project-store" }];
      h.respond = async (path: string) => {
        if (path.endsWith("/restore")) throw new ui.ApiFailure(403, { error: "permission_required", requirements });
        return { data: { versionId: "saved-v1", etag: '"current"', changes: [{ path: "displayName", before: "Now", after: "Old" }] } };
      };
      let tree = h.render(ui.ConfigurationHistory, p);
      await find(tree, "HistoryVersions").props.onPreview("saved-v1");
      tree = h.render(ui.ConfigurationHistory, p);
      find(tree, "ReasonField").props.setReason("Recover saved configuration");
      tree = h.render(ui.ConfigurationHistory, p);
      find(tree, "Button", "Review restore").props.onClick();
      tree = h.render(ui.ConfigurationHistory, p);
      await find(tree, "Review").props.onConfirm();
      tree = h.render(ui.ConfigurationHistory, p);
      assert.equal(find(tree, "HistoryVersions").props.readOnly, false);
      await find(tree, "HistoryVersions").props.onPreview("saved-v1");
      tree = h.render(ui.ConfigurationHistory, p);
      assert.equal(find(tree, "Review"), null);
      assert.deepEqual(find(tree, "FailureRequirements").props.error.body.requirements, requirements);
      h.dispose();
    });

    await t.test("invalid stored IDs and unavailable storage are ignored; control-only reasons fail", () => {
      const h = harness();
      h.store.set("ccof:self-service:last-job:example", "../another-project");
      assert.equal(ui.rememberJob("example"), null);
      (globalThis as any).window.localStorage.getItem = () => { throw new Error("storage blocked"); };
      assert.equal(ui.rememberJob("example"), null);
      assert.equal(ui.validReason("valid reason"), true);
      for (const reason of ["tiny", " \n\n\n\n ", "valid\nreason", "x".repeat(501)]) assert.equal(ui.validReason(reason), false);
      h.dispose();
    });
  } finally {
    delete (globalThis as any)[GLOBAL];
    (globalThis as any).window = priorWindow;
    await rm(directory, { recursive: true, force: true });
  }
});

test("api forwards an optional idempotency key without changing existing requests", async () => {
  const directory = await mkdtemp(fileURLToPath(new URL("./.self-service-ui-", import.meta.url)));
  const previous = globalThis.fetch;
  try {
    const output = join(directory, "api.mjs");
    await build({
      entryPoints: [fileURLToPath(new URL("../ui-v3/lib/api.ts", import.meta.url))], outfile: output,
      bundle: true, packages: "external", platform: "node", format: "esm", logLevel: "silent",
      plugins: [{ name: "logged-out-test-token", setup(b) {
        b.onResolve({ filter: /^\.\/auth\.ts$/ }, () => ({ path: "auth", namespace: "test" }));
        b.onLoad({ filter: /.*/, namespace: "test" }, () => ({ contents: 'export const token = async () => "test-only";' }));
      } }],
    });
    const requests: RequestInit[] = [];
    globalThis.fetch = async (_input, options) => {
      requests.push(options!);
      return new Response("{}", { status: 202, headers: { "content-type": "application/json" } });
    };
    const { api } = await import(pathToFileURL(output).href);
    await api("/api/v3/projects/example/operations", { method: "POST", body: { kind: "apply", reason: "Reviewed change" }, ifMatch: '"current"', idempotencyKey: "same-request-123" });
    assert.equal((requests[0].headers as any)["idempotency-key"], "same-request-123");
    assert.equal((requests[0].headers as any)["if-match"], '"current"');
    await api("/api/projects/example");
    assert.equal((requests[1].headers as any)["idempotency-key"], undefined);
  } finally { globalThis.fetch = previous; await rm(directory, { recursive: true, force: true }); }
});
