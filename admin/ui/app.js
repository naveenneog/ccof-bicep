// Existing project editor, with React-based v2 operator panels in v2.jsx.
// API values are inserted as text, never HTML.
import { InteractionRequiredAuthError, PublicClientApplication } from "@azure/msal-browser";
import { hasV2Draft, mountV2 } from "./v2.jsx";

const API = "/api";
const FAMILY_LABELS = { haiku: "Haiku", sonnet: "Sonnet", opus: "Opus", fable: "Fable", mythos: "Mythos" };
const FAMILY_ORDER = ["opus", "sonnet", "haiku", "fable", "mythos"];
const PERIODS = ["Hourly", "Daily", "Weekly", "Monthly", "Yearly"];
const PERIOD_UNIT = { Hourly: "hour", Daily: "day", Weekly: "week", Monthly: "month", Yearly: "year" };
const ID_RE = /^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/;
const GUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SYNC_NOTE = "Developers get the change after the next entitlement sync.";

const $ = (id) => document.getElementById(id);
const nf = new Intl.NumberFormat("en-US");

function el(tag, props = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (value === undefined || value === null || value === false) continue;
    if (key === "class") node.className = value;
    else if (key === "text") node.textContent = value;
    else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
    else if (key in node && typeof value !== "string") node[key] = value;
    else node.setAttribute(key, value === true ? "" : value);
  }
  for (const child of children.flat()) {
    if (child === null || child === undefined || child === false) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

/* ── Authentication ──────────────────────────────────── */

const auth = { mode: null, pca: null, account: null, scope: null, demoAs: null };

async function initAuth(config) {
  if (config.demo) {
    auth.mode = "demo";
    auth.demoAs = new URLSearchParams(location.search).get("as") === "reader" ? "reader" : "editor";
    return true;
  }
  auth.mode = "msal";
  auth.scope = config.scope;
  auth.pca = new PublicClientApplication({
    auth: { clientId: config.clientId, authority: `https://login.microsoftonline.com/${config.tenantId}`, redirectUri: `${location.origin}/api/console` },
    cache: { cacheLocation: "sessionStorage" },
  });
  await auth.pca.initialize();
  const result = await auth.pca.handleRedirectPromise();
  auth.account = result?.account ?? auth.pca.getAllAccounts()[0] ?? null;
  return auth.account !== null;
}

async function token() {
  if (auth.mode === "demo") return `demo-${auth.demoAs}`;
  try {
    return (await auth.pca.acquireTokenSilent({ scopes: [auth.scope], account: auth.account })).accessToken;
  } catch (err) {
    if (err instanceof InteractionRequiredAuthError) {
      await auth.pca.acquireTokenRedirect({ scopes: [auth.scope], account: auth.account });
    }
    throw err;
  }
}

function displayName() {
  if (auth.mode === "demo") return auth.demoAs === "reader" ? "Demo reader" : "Demo editor";
  return auth.account?.name || auth.account?.username || "Signed in";
}

async function call(method, path, { body, etag, ifNoneMatch } = {}) {
  const headers = { authorization: `Bearer ${await token()}` };
  if (body !== undefined) headers["content-type"] = "application/json";
  if (etag) headers["if-match"] = etag;
  if (ifNoneMatch) headers["if-none-match"] = ifNoneMatch;
  let response;
  try {
    response = await fetch(`${API}${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  } catch {
    return { status: 0, data: { error: "network_error" }, etag: null };
  }
  let data = null;
  try { data = await response.json(); } catch { data = null; }
  return { status: response.status, data, etag: response.headers.get("etag") };
}

/* ── Messages ────────────────────────────────────────── */

const ERRORS = {
  network_error: ["Can't reach the admin app", "Check your connection, then try again."],
  registry_unavailable: ["Can't reach the project registry", "The admin app couldn't connect to Cosmos DB. This usually means its private network path or data role isn't set up yet. Nothing was changed."],
  project_store_not_configured: ["Registry not configured", "The admin app has no Cosmos DB settings. Nothing was changed."],
  admin_auth_not_configured: ["Sign-in isn't configured on the server", "Ask your Azure administrator to set the ADMIN_* settings on the admin app."],
  administrator_not_allowed: ["You're signed in, but not an admin", "Ask for the CCOF.Projects.Read or CCOF.Projects.Write role on the CCOF Admin app."],
  oauth_client_denied: ["This app isn't allowed to call the API", "Add this app's client ID to ADMIN_ALLOWED_CLIENT_IDS."],
  delegated_scope_required: ["Missing API permission", "Sign out and sign in again to grant the Projects.Manage permission."],
  invalid_access_token: ["Your sign-in has expired", "Sign out and sign in again."],
  tenant_or_user_denied: ["This account's directory isn't allowed", "Sign in with an account from the organization's directory."],
  write_permission_required: ["You have read-only access", "Editing needs the CCOF.Projects.Write role."],
  project_not_found: ["Project not found", "It may have been removed from the registry. Pick another project."],
  project_exists: ["That project ID is taken", "Project IDs are permanent. Choose a different ID."],
  etag_mismatch: ["Someone else changed this project", "Load the latest version, then make your change again. Your edit wasn't saved."],
  if_match_required: ["Couldn't confirm the version you edited", "Load the latest version and try again."],
  classification_not_found: ["Classification not found", "Load the latest version of the project."],
  invalid_project: ["Some values need fixing", "Nothing was saved."],
  body_too_large: ["The request is too large", "Projects are limited to 64 KB."],
};

function errorInfo(result) {
  const code = result.data?.error ?? `http_${result.status}`;
  const [title, detail] = ERRORS[code] ?? ["Something went wrong", "Try again. If it keeps happening, share the request ID with your administrator."];
  return { code, title, detail, requestId: result.data?.requestId, problems: result.data?.problems ?? [] };
}

const DETAIL_TEXT = {
  invalid_family_policy: "token limits must be whole numbers above zero, or empty for no limit; a quota and its period go together",
  unknown_family: "unknown model family",
  model_family_mismatch: "a model is listed under the wrong family",
  restricted_family: "this family is only available to the CYB classification",
};

function describeProblem(problem) {
  const [path, code] = problem.split(":");
  const cls = /^classifications\.([^.]+)/.exec(path)?.[1];
  const known = {
    "projectId:invalid": "Project ID: use letters, numbers, - or _ (up to 80), starting with a letter or number.",
    "id:not_equal_to_projectId": "The document ID must match the project ID.",
    "status:not_active": "New projects must be active.",
    "backendId:invalid": "Backend ID: use letters, numbers, - or _.",
    "displayName:invalid": "Display name is required (up to 200 characters).",
    "designatedSubscriptionId:invalid": "Foundry subscription ID must be a GUID.",
    "classifications:group_reused": "Each Entra group can be used by only one classification.",
    "classifications:empty": "Add at least one classification.",
    "document:unexpected_key": "The document has fields the registry doesn't accept.",
  }[problem];
  if (known) return known;
  if (cls && path.endsWith(".groupId")) return `${cls}: the group Object ID must be a GUID.`;
  if (cls && path.includes("familyPolicy")) return `${cls} models and limits: ${DETAIL_TEXT[code] ?? code.replaceAll("_", " ")}.`;
  if (cls && path.endsWith("Budget")) return `${cls}: budget needs an amount of zero or more.`;
  return `${path}: ${code?.replaceAll("_", " ") ?? "invalid"}.`;
}

function notice(kind, title, body = [], actions = []) {
  return el("div", { class: `notice notice-${kind}`, role: kind === "danger" ? "alert" : "status" },
    el("p", { class: "notice-title", text: title }),
    ...body,
    actions.length ? el("div", { class: "actions" }, ...actions) : null);
}

function errorNotice(info, actions = []) {
  const body = [el("p", { text: info.detail })];
  if (info.problems.length) body.push(el("ul", {}, info.problems.map((p) => el("li", { text: describeProblem(p) }))));
  if (info.requestId) body.push(el("p", { class: "muted mono", text: `Request ID ${info.requestId}` }));
  return notice("danger", info.title, body, actions);
}

let toastTimer;
function toast(message) {
  const t = $("toast");
  t.textContent = message;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, 6000);
}

/* ── Formatting ──────────────────────────────────────── */

const fmtTpm = (v) => (v === null || v === undefined ? "No limit" : nf.format(v));
const fmtQuota = (limit) => (limit?.tokenQuota == null ? "No quota" : `${nf.format(limit.tokenQuota)} / ${PERIOD_UNIT[limit.tokenQuotaPeriod] ?? limit.tokenQuotaPeriod}`);
const fmtBudget = (b) => (b ? `${b.currency === "USD" ? "$" : ""}${nf.format(b.amount)}${b.currency === "USD" ? "" : ` ${b.currency}`} / month` : "No cap");
const familiesOf = (policy) => Object.keys(policy.families ?? {}).sort((a, b) => FAMILY_ORDER.indexOf(a) - FAMILY_ORDER.indexOf(b));

/* ── State ───────────────────────────────────────────── */

const state = {
  canWrite: false,
  projects: [],
  listError: null,
  current: null, // { doc, etag }
  code: null,
  editing: null, // draft family policy
  reviewing: false,
  saving: false,
  saveError: null,
  cursor: null,
  catalog: null,
  listEpoch: 0,
  creating: false,
};

/* ── Project list ────────────────────────────────────── */

const FILTER_IDS = ["search", "tag-filter", "backend-filter"];
const queryActive = () => FILTER_IDS.some((id) => $(id).value.trim() !== "");
const isSectionRoute = () => /^#\/(budgets|inventory|pricing|operations|audit)$/.test(location.hash);

function syncFilterSummary() {
  const active = ["tag-filter", "backend-filter"].filter((id) => $(id).value.trim() !== "").length;
  $("filter-count").textContent = active ? `${active} active` : "";
  $("filter-count").hidden = active === 0;
}

function clearFilters() {
  for (const id of FILTER_IDS) $(id).value = "";
  syncFilterSummary();
  $("search").focus();
  loadProjects().catch(() => { $("list-status").textContent = "Project search failed. Retry after checking connectivity."; });
}

async function loadProjects(append = false) {
  append = append === true;
  const epoch = append ? state.listEpoch : ++state.listEpoch;
  $("list-status").textContent = "";
  delete $("list-status").dataset.state;
  if (!append) $("project-list").replaceChildren(el("li", { class: "skeleton", "aria-hidden": "true" }, el("span"), el("span"), el("span"), el("span")));
  const params = new URLSearchParams({ search: $("search").value.trim(), tag: $("tag-filter").value.trim(), backendId: $("backend-filter").value.trim(), limit: "50" });
  if (append && state.cursor) params.set("cursor", state.cursor);
  const result = await call("GET", `/v2/projects?${params}`);
  if (epoch !== state.listEpoch) return;
  if (result.status !== 200) {
    state.projects = [];
    state.listError = errorInfo(result);
  } else {
    const items = result.data.projects.map((p) => ({ ...p, classifications: Object.keys(p.classifications ?? {}) }));
    state.projects = append ? [...state.projects, ...items] : items;
    state.cursor = result.data.cursor;
    state.listError = null;
  }
  renderList();
  $("load-more").hidden = !state.cursor || Boolean(state.listError);
  document.dispatchEvent(new CustomEvent("ccof:projects"));
  // Keep the Projects home in step with the list once it is on screen (filters, load more).
  if (lastView !== null && currentRoute().view === "home" && !isSectionRoute()) renderHome();
}

function renderList() {
  const list = $("project-list");
  const status = $("list-status");
  if (state.listError) {
    list.replaceChildren();
    status.replaceChildren(errorNotice(state.listError, [el("button", { class: "btn btn-small", type: "button", text: "Try again", onclick: loadProjects })]));
    status.dataset.state = "error";
    return;
  }
  const count = state.projects.length;
  const filtered = queryActive();
  if (count === 0 && filtered) {
    if (status.dataset.state !== "no-match") {
      status.replaceChildren("No projects match.", el("button", { class: "btn btn-small", type: "button", text: "Clear filters", onclick: clearFilters }));
      status.dataset.state = "no-match";
    }
  } else {
    const summary = count === 0 ? (state.cursor ? "This page is empty. Load more to continue." : "")
      : `${count} ${filtered ? "matching " : ""}project${count === 1 ? "" : "s"}${state.cursor ? " loaded · more available" : ""}`;
    // Rewriting identical text would make the live region announce it again on every route change.
    if (status.dataset.state !== "summary" || status.textContent !== summary) status.textContent = summary;
    status.dataset.state = "summary";
  }
  const selected = currentRoute().id;
  list.replaceChildren(...state.projects.map((p) =>
    el("li", {}, el("button", {
      class: "project-item", type: "button", "aria-current": p.projectId === selected ? "true" : "false",
      onclick: () => navigate(`#/p/${encodeURIComponent(p.projectId)}`),
    }, el("span", { class: "name", text: p.displayName || p.projectId }),
       el("span", { class: "meta", text: `${p.projectId} · ${p.classifications.join(", ")}${p.adminTags?.length ? ` · ${p.adminTags.join(", ")}` : ""}` })))));
}

/* ── Routing ─────────────────────────────────────────── */

function currentRoute() {
  const hash = location.hash;
  if (hash === "#/new") return { view: "new" };
  const m = /^#\/p\/(.+)$/.exec(hash);
  return m ? { view: "project", id: decodeURIComponent(m[1]) } : { view: "home" };
}

function navigate(hash) {
  if (location.hash === hash) {
    if ((state.editing || state.creating || hasV2Draft()) && !window.confirm("Discard unsaved changes?")) return;
    route();
  }
  else location.hash = hash;
}

async function route() {
  const r = currentRoute();
  const extended = isSectionRoute();
  $("detail").hidden = extended;
  $("v2-content").hidden = !extended;
  $("workspace").dataset.view = extended ? "section" : r.view;
  if (extended) {
    renderList();
    return;
  }
  lastView = null;
  state.editing = null;
  state.reviewing = false;
  state.saveError = null;
  state.creating = false;
  renderList();
  if (r.view === "new") return state.canWrite ? renderCreate() : renderHome();
  if (r.view === "project") return openProject(r.id);
  renderHome();
}

// A new view fades in and starts at the top; re-rendering the same view keeps scroll and doesn't animate.
// Narrow layouts scroll <main> instead of the detail pane, so both positions are handled.
let lastView = null;
function setDetail(...children) {
  const view = location.hash || "#/";
  const fresh = view !== lastView;
  lastView = view;
  const inner = el("div", { class: `detail-inner${fresh ? " detail-enter" : ""}` }, ...children);
  const top = $("detail").scrollTop;
  const pageTop = $("main").scrollTop;
  $("detail").replaceChildren(inner);
  $("detail").scrollTop = fresh ? 0 : top;
  $("main").scrollTop = fresh ? 0 : pageTop;
}

const backLink = () => el("a", { class: "back-link", href: "#/" }, el("span", { "aria-hidden": "true", text: "←" }), "All projects");

const PROJECT_GUIDE = [
  ["Access groups", "One Entra security group per classification, such as STD, PRM or CYB. Membership is managed in Entra; developers get changes after the next entitlement sync."],
  ["Models and token limits", "The deployments each model family may use, with per-person and whole-group tokens per minute and quotas. A request must fit both the all-models limit and its family's limit."],
  ["Budgets", "Monthly per-person and whole-group budgets. Month-to-date consumption is the reconciler's calculation, not an invoice; 100 CCU = USD 1."],
  ["Organization", "Custom tags and the single APIM backend the project uses. Tags organize the list; they never grant access."],
];
const SECTION_GUIDE = [
  ["#/budgets", "Group budgets", "Month-to-date consumption against every access group's budget, across all projects."],
  ["#/inventory", "Foundry inventory", "Foundry resources, their deployed models and the APIM backends that point at them."],
  ["#/pricing", "Cost definitions", "The model catalog and the versioned USD token rate card."],
  ["#/operations", "Health & operations", "Control-plane state, endpoint probes and reconciler runs, reported separately."],
  ["#/audit", "Audit", "Recent admin changes and refusals from configured telemetry."],
];

function renderHome() {
  if (state.listError) return setDetail(el("div", { class: "empty" }, el("h1", { text: "Projects" }), el("p", { class: "muted", text: "The project list couldn't be loaded. Its message explains what went wrong and lets you try again." })));
  if (state.projects.length === 0 && state.cursor) return setDetail(el("div", { class: "empty" },
    el("h1", { text: "Continue the project search" }), el("p", { text: "This query page was empty. Use Load more projects to continue; the registry has not been confirmed empty." })));
  if (state.projects.length === 0 && queryActive()) return setDetail(el("div", { class: "empty" },
    el("h1", { text: "No projects match" }),
    el("p", { text: "Search matches project names and IDs. Tag and backend ID filters need the exact value. The registry itself has not been confirmed empty." }),
    el("div", { class: "toolbar" }, el("button", { class: "btn", type: "button", text: "Clear filters", onclick: clearFilters }))));
  if (state.projects.length === 0) {
    return setDetail(el("div", { class: "empty" },
      el("h1", { text: "No projects yet" }),
      el("p", { text: "A project ties an Entra group to the Claude models its members may use and the token limits they get." }),
      el("p", { class: "muted", text: "Before you start, have ready:" }),
      el("ol", {},
        el("li", { text: "The Entra group's Object ID (Entra admin center → Groups → your group → Overview)." }),
        el("li", { text: "The backend ID and Foundry subscription ID used by your existing project." }),
        el("li", { text: "The exact model deployment names, for example claude-sonnet-4-5." })),
      state.canWrite ? el("div", {}, el("button", { class: "btn btn-primary", type: "button", text: "Create the first project", onclick: () => navigate("#/new") })) : el("p", { class: "muted", text: "You have read-only access." })));
  }
  const n = state.projects.length;
  setDetail(el("div", { class: "home" },
    el("header", { class: "page-head" },
      el("h1", { text: "Projects" }),
      el("p", { class: "section-note", text: `${n} ${queryActive() ? "matching " : ""}project${n === 1 ? "" : "s"} loaded${state.cursor ? "; more are available with Load more projects" : ""}. ` +
        `Choose one from the project list to review its access groups, models, token limits and budgets${state.canWrite ? ", or add one with New project" : ""}.` }),
      state.canWrite ? null : el("p", { class: "section-note", text: "You have read-only access. Editing needs the CCOF.Projects.Write role." })),
    el("section", { class: "section", "aria-labelledby": "guide-project" },
      el("h2", { id: "guide-project", text: "What a project defines" }),
      el("dl", { class: "guide" }, PROJECT_GUIDE.flatMap(([term, text]) => [el("dt", { text: term }), el("dd", { text })]))),
    el("section", { class: "section", "aria-labelledby": "guide-sections" },
      el("h2", { id: "guide-sections", text: "Across all projects" }),
      el("dl", { class: "guide" }, SECTION_GUIDE.flatMap(([href, term, text]) => [el("dt", {}, el("a", { href, text: term })), el("dd", { text })])))));
}

/* ── Project detail ──────────────────────────────────── */

async function openProject(id) {
  setDetail(el("div", { class: "skeleton", "aria-busy": "true", "aria-label": "Loading project" }, el("span"), el("span"), el("span"), el("span"), el("span")));
  const result = await call("GET", `/projects/${encodeURIComponent(id)}`);
  if (result.status !== 200) {
    state.current = null;
    return setDetail(errorNotice(errorInfo(result), [el("button", { class: "btn btn-small", type: "button", text: "Try again", onclick: () => openProject(id) })]));
  }
  state.current = { doc: result.data, etag: result.etag };
  const codes = Object.keys(result.data.classifications ?? {}).sort();
  if (!codes.includes(state.code)) state.code = codes[0] ?? null;
  renderProject();
}

function renderProject() {
  const { doc } = state.current;
  const codes = Object.keys(doc.classifications).sort();
  const cls = doc.classifications[state.code];

  const head = el("header", { class: "page-head" },
    backLink(),
    el("div", { class: "row" }, el("h1", { text: doc.displayName || doc.projectId }), el("span", { class: "pill pill-ok", text: doc.status === "active" ? "Active" : doc.status })),
    el("dl", { class: "facts" },
      el("div", {}, el("dt", { text: "Project ID" }), el("dd", { text: doc.projectId })),
      el("div", {}, el("dt", { text: "Backend" }), el("dd", { text: doc.backendId })),
      el("div", {}, el("dt", { text: "Foundry subscription" }), el("dd", { text: doc.designatedSubscriptionId })),
      el("div", {}, el("dt", { text: "Tags" }), el("dd", { text: doc.adminTags?.length ? doc.adminTags.join(", ") : "None" }))));

  const tabs = codes.length > 1 ? el("div", { class: "tabs", role: "tablist", "aria-label": "Classifications" },
    codes.map((code, i) => el("button", {
      class: "tab", role: "tab", type: "button", id: `tab-${code}`,
      "aria-selected": code === state.code ? "true" : "false", tabindex: code === state.code ? "0" : "-1",
      onclick: () => switchClassification(code),
      onkeydown: (e) => {
        const step = e.key === "ArrowRight" ? 1 : e.key === "ArrowLeft" ? -1 : 0;
        if (!step) return;
        e.preventDefault();
        const next = codes[(i + step + codes.length) % codes.length];
        switchClassification(next);
        requestAnimationFrame(() => $(`tab-${next}`)?.focus());
      },
    }, code))) : null;

  const extras = el("div", { id: "project-extras" });
  setDetail(head, tabs, renderClassification(cls), extras);
  document.dispatchEvent(new CustomEvent("ccof:project", { detail: { ...state.current, editing: Boolean(state.editing) } }));
}

function switchClassification(code) {
  if (state.editing && !confirmDiscard()) return;
  state.code = code;
  state.editing = null;
  state.reviewing = false;
  state.saveError = null;
  renderProject();
}

function confirmDiscard() {
  return changesBetween(currentPolicy(), state.editing).length === 0 || window.confirm("Discard your unsaved changes?");
}

const currentPolicy = () => state.current.doc.classifications[state.code].familyPolicy;

function renderClassification(cls) {
  const groupName = cls.classificationGroupDisplayName;
  const access = el("section", { class: "section", "aria-labelledby": "access-title" },
    el("div", { class: "section-head" }, el("h2", { id: "access-title", text: `${state.code} access group` })),
    el("dl", { class: "kv" },
      el("dt", { text: "Group" }), el("dd", { text: groupName || "Name not recorded" }),
      el("dt", { text: "Object ID" }), el("dd", {}, el("code", { text: cls.groupId }),
        el("button", { class: "btn btn-quiet btn-small", type: "button", text: "Copy", "aria-label": "Copy group Object ID",
          onclick: async () => { try { await navigator.clipboard.writeText(cls.groupId); toast("Group Object ID copied."); } catch { toast("Couldn't copy. Select the ID and copy it manually."); } } }))),
    el("p", { class: "section-note", text: "Membership comes from this Entra group. To change who has access, change the group's members in Entra." }));

  const budgets = el("section", { class: "section", "aria-labelledby": "budget-title" },
    el("h2", { id: "budget-title", text: "Budgets" }),
    el("dl", { class: "kv" },
      el("dt", { text: "Per person" }), el("dd", { text: fmtBudget(cls.personBudget) }),
      el("dt", { text: "Whole group" }), el("dd", { text: fmtBudget(cls.aggregateBudget) }),
      el("dt", { text: "Group budget mode" }), el("dd", { text: cls.aggregateMode === "strict" ? "Strict (block when exceeded)" : "Notify only" }),
      el("dt", { text: "New members" }), el("dd", { text: cls.onboardingMode === "block" ? "Blocked until budget state exists" : "Allowed with a warning" })),
    el("p", { class: "section-note", text: "In token-limits-only mode, budgets are reported, not enforced. Use Organization & consumption below to review changes." }));

  return el("div", { class: "detail-inner" }, renderLimits(), access, budgets);
}

/* ── Limits: view, edit, review, save ────────────────── */

function renderLimits() {
  const editing = state.editing !== null;
  const policy = editing ? state.editing : currentPolicy();
  const rows = [
    { key: "aggregate", title: "All models", sub: "Applies across every model below", target: policy.aggregateLimits },
    ...familiesOf(policy).map((family) => ({ key: family, title: FAMILY_LABELS[family] ?? family, family, target: policy.families[family] })),
  ];

  const actions = [];
  if (!editing && state.canWrite) actions.push(el("button", { class: "btn btn-primary", type: "button", text: "Edit limits and models", onclick: startEdit }));
  if (editing && !state.reviewing) {
    actions.push(el("button", { class: "btn btn-quiet", type: "button", text: "Cancel", onclick: cancelEdit }));
    actions.push(el("button", { class: "btn btn-primary", type: "button", text: "Review changes", onclick: startReview }));
  }

  const table = el("table", { class: "limits" },
    el("caption", { class: "visually-hidden", text: `Token limits for ${state.code}` }),
    el("thead", {},
      el("tr", {}, el("th", { scope: "col", rowspan: "2", text: "Scope" }),
        el("th", { scope: "colgroup", colspan: "2", class: "group-head sep", text: "Each person" }),
        el("th", { scope: "colgroup", colspan: "2", class: "group-head sep", text: "Whole group combined" })),
      el("tr", {}, el("th", { scope: "col", class: "n sep", text: "Tokens / min" }), el("th", { scope: "col", class: "n", text: "Quota" }),
        el("th", { scope: "col", class: "n sep", text: "Tokens / min" }), el("th", { scope: "col", class: "n", text: "Quota" }))),
    el("tbody", {}, rows.map((row) => el("tr", {},
      el("th", { scope: "row" },
        el("div", { class: "scope-title", text: row.title }),
        row.sub ? el("div", { class: "scope-sub", text: row.sub }) : null,
        row.family ? modelChips(row.family, row.target.models ?? [], editing && !state.reviewing) : null),
      ...["person", "group"].flatMap((scope) => limitCells(row, scope, editing && !state.reviewing))))));

  const parts = [
    el("div", { class: "section-head" },
      el("div", {}, el("h2", { id: "limits-title", text: "Models and token limits" }),
        el("p", { class: "section-note", text: "A request must fit both the all-models limit and its model family's limit." })),
      el("div", { class: "toolbar" }, ...actions)),
  ];
  if (state.saveError) parts.push(state.saveError);
  if (state.reviewing) parts.push(reviewPanel());
  parts.push(el("div", { class: "table-wrap" }, table));
  if (!state.canWrite) parts.push(el("p", { class: "section-note", text: "You have read-only access. Editing needs the CCOF.Projects.Write role." }));
  return el("section", { class: "section", "aria-labelledby": "limits-title" }, ...parts);
}

function limitCells(row, scope, editable) {
  const limit = row.target[scope] ?? { tokensPerMinute: null, tokenQuota: null, tokenQuotaPeriod: null };
  const label = `${row.title}, ${scope === "person" ? "each person" : "whole group"}`;
  const who = scope === "person" ? "Each person" : "Whole group";
  if (!editable) {
    return [
      el("td", { class: `n sep ${limit.tokensPerMinute == null ? "none" : ""}`, "data-label": `${who} · tokens/min`, text: fmtTpm(limit.tokensPerMinute) }),
      el("td", { class: `n ${limit.tokenQuota == null ? "none" : ""}`, "data-label": `${who} · quota`, text: fmtQuota(limit) }),
    ];
  }
  const set = (patch) => { row.target[scope] = { ...limit, ...patch }; Object.assign(limit, patch); };
  const num = (value, field, aria) => el("input", {
    class: "input num w-num", type: "text", inputmode: "numeric", value: value == null ? "" : nf.format(value), placeholder: "No limit", "aria-label": aria,
    onblur: (e) => { const raw = e.target.value.replaceAll(",", "").trim(); if (/^[1-9]\d{0,14}$/.test(raw)) e.target.value = nf.format(Number(raw)); },
    oninput: (e) => {
      const raw = e.target.value.replaceAll(",", "").trim();
      const ok = raw === "" || /^[1-9]\d{0,14}$/.test(raw);
      e.target.setAttribute("aria-invalid", ok ? "false" : "true");
      set({ [field]: raw === "" ? null : ok ? Number(raw) : raw });
    },
  });
  const quota = num(limit.tokenQuota, "tokenQuota", `${label}, quota`);
  quota.disabled = limit.tokenQuotaPeriod == null;
  if (quota.disabled) quota.placeholder = "No quota";
  const period = el("select", {
    class: "select w-period", "aria-label": `${label}, quota period`,
    onchange: (e) => {
      const value = e.target.value || null;
      quota.disabled = value === null;
      quota.placeholder = value === null ? "No quota" : "Tokens";
      if (value === null) { quota.value = ""; set({ tokenQuotaPeriod: null, tokenQuota: null }); }
      else set({ tokenQuotaPeriod: value });
    },
  }, el("option", { value: "", text: "No quota" }), PERIODS.map((p) => el("option", { value: p, text: `per ${PERIOD_UNIT[p]}`, selected: p === limit.tokenQuotaPeriod })));
  return [
    el("td", { class: "n sep editing", "data-label": `${who} · tokens/min` }, num(limit.tokensPerMinute, "tokensPerMinute", `${label}, tokens per minute`)),
    el("td", { class: "editing", "data-label": `${who} · quota` }, el("div", { class: "quota-pair" }, quota, period)),
  ];
}

function modelChips(family, models, editable) {
  const list = el("div", { class: "chips", "aria-label": `${FAMILY_LABELS[family] ?? family} model deployments` },
    models.map((model) => el("span", { class: "chip" }, model,
      editable ? el("button", {
        type: "button", "aria-label": `Remove ${model}`, text: "×", disabled: models.length === 1,
        title: models.length === 1 ? "A family needs at least one model" : undefined,
        onclick: () => { state.editing.families[family].models = models.filter((m) => m !== model); renderProject(); },
      }) : null)));
  if (!editable) return list;
  const input = el("input", { class: "input", type: "text", placeholder: "Add deployment name", "aria-label": `Add a ${FAMILY_LABELS[family] ?? family} deployment` });
  const add = () => {
    const name = input.value.trim();
    if (!name || models.includes(name)) return;
    state.editing.families[family].models = [...models, name];
    renderProject();
    requestAnimationFrame(() => document.querySelector(`[aria-label="Add a ${FAMILY_LABELS[family] ?? family} deployment"]`)?.focus());
  };
  input.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); add(); } });
  const options = (state.catalog?.models ?? []).filter((m) => m.family === family &&
    (!m.backendId || m.backendId === state.current.doc.backendId));
  const choice = el("select", { class: "select", "aria-label": `Configured ${family} deployment`, onchange: (e) => {
    if (e.target.value) { input.value = e.target.value; add(); }
  } }, el("option", { value: "", text: "Choose configured deployment…" }),
    options.map((m) => el("option", { value: m.deployment, text: `${m.deployment} (${m.model})` })));
  return el("div", {}, list, choice, el("div", { class: "chip-add" }, input, el("button", { class: "btn btn-small", type: "button", text: "Add", onclick: add })));
}

function startEdit() {
  state.editing = structuredClone(currentPolicy());
  state.saveError = null;
  renderProject();
  requestAnimationFrame(() => document.querySelector(".limits input")?.focus());
}

function cancelEdit() {
  if (!confirmDiscard()) return;
  state.editing = null;
  state.reviewing = false;
  state.saveError = null;
  renderProject();
}

function changesBetween(before, after, labels = [], out = []) {
  if (after === null || after === undefined) return out;
  const isObj = (v) => v && typeof v === "object" && !Array.isArray(v);
  if (isObj(before) && isObj(after)) {
    for (const key of new Set([...Object.keys(before), ...Object.keys(after)])) changesBetween(before[key], after[key], [...labels, key], out);
  } else if (JSON.stringify(before) !== JSON.stringify(after)) {
    out.push({ labels, before, after });
  }
  return out;
}

function describeChange({ labels, before, after }) {
  const names = { aggregateLimits: "All models", person: "each person", group: "whole group", tokensPerMinute: "tokens/min", tokenQuota: "quota", tokenQuotaPeriod: "quota period", models: "models" };
  const words = labels.filter((k) => k !== "families").map((k) => names[k] ?? FAMILY_LABELS[k] ?? k);
  const show = (v) => (Array.isArray(v) ? v.join(", ") || "none" : v === null || v === undefined ? "none" : typeof v === "number" ? nf.format(v) : String(v));
  return el("li", { class: "diff" }, `${words.join(" · ")}: `, el("span", { class: "from", text: show(before) }), " → ", el("span", { class: "to", text: show(after) }));
}

function localProblems(policy) {
  const problems = [];
  const scopes = [["All models", policy.aggregateLimits], ...familiesOf(policy).map((f) => [FAMILY_LABELS[f] ?? f, policy.families[f]])];
  for (const [name, target] of scopes) {
    for (const scope of ["person", "group"]) {
      const l = target[scope] ?? {};
      const who = scope === "person" ? "each person" : "whole group";
      for (const field of ["tokensPerMinute", "tokenQuota"]) {
        if (l[field] !== null && l[field] !== undefined && !(Number.isInteger(l[field]) && l[field] > 0)) problems.push(`${name}, ${who}, ${field === "tokenQuota" ? "quota" : "tokens per minute"}: use a whole number above zero, or leave it empty.`);
      }
      if (l.tokenQuotaPeriod && (l.tokenQuota === null || l.tokenQuota === undefined)) problems.push(`${name}, ${who}: enter a quota for the chosen period, or pick "No quota".`);
    }
  }
  return [...new Set(problems)];
}

function startReview() {
  const problems = localProblems(state.editing);
  if (problems.length) {
    state.saveError = notice("danger", "Some values need fixing", [el("ul", {}, problems.map((p) => el("li", { text: p })))]);
    return renderProject();
  }
  const changes = changesBetween(currentPolicy(), state.editing);
  if (changes.length === 0) {
    state.editing = null;
    state.saveError = null;
    toast("No changes to save.");
    return renderProject();
  }
  state.saveError = null;
  state.reviewing = true;
  renderProject();
  requestAnimationFrame(() => document.querySelector(".notice-review .btn-primary")?.focus());
}

function reviewPanel() {
  const changes = changesBetween(currentPolicy(), state.editing);
  const saveButton = el("button", { class: "btn btn-primary", type: "button", text: state.saving ? "Saving" : `Save ${changes.length} change${changes.length === 1 ? "" : "s"}`, "aria-busy": state.saving ? "true" : "false", disabled: state.saving, onclick: saveChanges });
  return notice("review", `Review changes to ${state.code}`, [el("ul", {}, changes.map(describeChange)), el("p", { text: SYNC_NOTE })], [
    saveButton,
    el("button", { class: "btn", type: "button", text: "Keep editing", disabled: state.saving, onclick: () => { state.reviewing = false; renderProject(); } }),
  ]);
}

async function saveChanges() {
  state.saving = true;
  renderProject();
  const { doc, etag } = state.current;
  const result = await call("PUT", `/projects/${encodeURIComponent(doc.projectId)}/classifications/${encodeURIComponent(state.code)}/family-policy`, { body: state.editing, etag });
  state.saving = false;
  if (result.status === 200) {
    state.current = { doc: result.data.project, etag: result.etag };
    state.editing = null;
    state.reviewing = false;
    state.saveError = null;
    renderProject();
    toast(result.data.changed ? `Saved. ${SYNC_NOTE}` : "No changes to save.");
    return;
  }
  const info = errorInfo(result);
  state.reviewing = false;
  const actions = info.code === "etag_mismatch"
    ? [el("button", { class: "btn btn-small", type: "button", text: "Load latest version", onclick: () => { state.editing = null; state.saveError = null; openProject(doc.projectId); } })]
    : [];
  state.saveError = errorNotice(info, actions);
  renderProject();
}

/* ── Create project ──────────────────────────────────── */

function field(id, label, opts = {}) {
  const input = el("input", { class: `input ${opts.num ? "num" : ""}`, id, name: id, type: "text", value: opts.value ?? "", placeholder: opts.placeholder, inputmode: opts.num ? "numeric" : undefined, autocomplete: "off", spellcheck: "false", "aria-describedby": `${id}-hint ${id}-error` });
  const error = el("p", { class: "field-error", id: `${id}-error`, "aria-live": "polite" });
  const check = () => {
    const message = opts.validate ? opts.validate(input.value.trim()) : "";
    error.textContent = message || "";
    input.setAttribute("aria-invalid", message ? "true" : "false");
    return !message;
  };
  input.addEventListener("blur", check);
  input.addEventListener("input", () => { if (input.getAttribute("aria-invalid") === "true") check(); opts.onInput?.(); });
  return { node: el("div", { class: "field" }, el("label", { for: id, text: label }), input, opts.hint ? el("p", { class: "hint", id: `${id}-hint`, text: opts.hint }) : null, error), input, check };
}

const required = (msg) => (v) => (v ? "" : msg);
const vId = (v) => (!v ? "Required." : ID_RE.test(v) ? "" : "Use letters, numbers, - or _; start with a letter or number.");
const vGuid = (v) => (!v ? "Required." : GUID_RE.test(v) ? "" : "Paste a GUID, like 1f2e3d4c-....");
const vCount = (v) => (v === "" || /^[1-9]\d{0,14}$/.test(v.replaceAll(",", "")) ? "" : "Whole number above zero, or empty for no limit.");
const vMoney = (v) => (/^\d+(\.\d{1,2})?$/.test(v) ? "" : "Enter an amount, like 10 or 12.50.");

function periodSelect(id, label) {
  return el("div", { class: "field" }, el("label", { for: id, text: label }),
    el("select", { class: "select", id }, el("option", { value: "", text: "No quota" }), PERIODS.map((p) => el("option", { value: p, text: `per ${PERIOD_UNIT[p]}`, selected: p === "Monthly" }))));
}

function renderCreate() {
  const inventoryChoices = [];
  const deploymentPickers = [];
  let discoveredModels = [];
  const preview = el("pre", {});
  const f = {
    projectId: field("projectId", "Project ID", { hint: "For example PROJECT02. Permanent; developers send it in the x-ccof-project header.", validate: vId }),
    displayName: field("displayName", "Display name", { hint: "Shown to admins, for example Payments platform.", validate: required("Required.") }),
    backendId: field("backendId", "Backend ID", { hint: "Choose the single APIM backend for this project. Multiple projects may share it.", validate: vId }),
    subscription: field("subscription", "Foundry subscription ID", { hint: "Subscription that pays for this project's model use.", validate: vGuid }),
  };
  const status = el("div", { "aria-live": "polite" });
  const submit = el("button", { class: "btn btn-primary", type: "submit", text: "Create project" });
  const count = (input) => { const v = input.value.replaceAll(",", "").trim(); return v === "" ? null : Number(v); };
  const limit = (tpm, quota, period) => {
    return { tokensPerMinute: count(tpm), tokenQuota: period ? count(quota) : null, tokenQuotaPeriod: period };
  };
  const classificationForms = ["STD", "PRM", "CYB"].map((code) => {
    const groupId = field(`${code}-groupId`, "Entra group Object ID", {
      hint: "Entra admin center → Groups → your group → Overview → Object ID.", validate: vGuid,
    });
    const groupName = field(`${code}-groupName`, "Group display name", {
      hint: `For example PROJECT02-${code}. Access uses the Object ID.`, validate: required("Required."),
    });
    const directory = el("div", { class: "directory-search" });
    const searchText = el("input", { class: "input", type: "search", "aria-label": `${code} directory group name`, placeholder: "Find an Entra group by name" });
    const searchStatus = el("div", { role: "status" });
    const searchButton = el("button", { class: "btn", type: "button", text: "Search directory", onclick: async () => {
      searchButton.disabled = true; searchStatus.textContent = "Searching…";
      try {
        const r = await call("GET", `/v2/groups?q=${encodeURIComponent(searchText.value.trim())}`);
        if (r.status !== 200 || r.data.state !== "available") {
          searchStatus.textContent = `Directory lookup unavailable (${r.data?.reason ?? r.data?.error ?? "request failed"}). Enter the Object ID manually. ${r.data?.permission ?? ""}`;
          return;
        }
        const groups = r.data.data.groups;
        searchStatus.replaceChildren(...groups.map((g) => el("button", { class: "btn btn-small", type: "button", text: `${g.displayName} — ${g.id}${g.securityEnabled ? "" : " (not a security group)"}`, disabled: !g.securityEnabled, onclick: () => {
          groupId.input.value = g.id; groupName.input.value = g.displayName;
          groupId.check(); groupName.check(); refresh(); searchStatus.textContent = `Selected ${g.displayName}. Membership is not changed.`;
        } })));
        if (!groups.length) searchStatus.textContent = "No matching groups. Manual Object ID entry remains available.";
        if (r.data.data.more) searchStatus.append(el("p", { text: "First 25 matches. Refine the group name to narrow results." }));
      } catch { searchStatus.textContent = "Directory request failed. Enter the Object ID manually."; }
      finally { searchButton.disabled = false; }
    } });
    directory.append(searchText, searchButton, searchStatus);
    const models = field(`${code}-models`, "Model deployment names", {
      hint: "Exact deployment names, separated by commas.", validate: required("Add at least one deployment."),
    });
    const quotaCheck = (periodId) => (v) => {
      const basic = vCount(v);
      return basic || (document.getElementById(periodId)?.value && !v ? "Enter a quota, or choose No quota." : "");
    };
    const pTpm = field(`${code}-pTpm`, "Tokens per minute", { num: true, value: "10000", validate: vCount });
    const pQuota = field(`${code}-pQuota`, "Quota", { num: true, value: "1000000", validate: quotaCheck(`${code}-pPeriod`) });
    const gTpm = field(`${code}-gTpm`, "Tokens per minute", { num: true, value: "50000", validate: vCount });
    const gQuota = field(`${code}-gQuota`, "Quota", { num: true, value: "10000000", validate: quotaCheck(`${code}-gPeriod`) });
    const pBudget = field(`${code}-pBudget`, "Per person (USD / month)", { num: true, value: "10", validate: vMoney });
    const gBudget = field(`${code}-gBudget`, "Whole group (USD / month)", { num: true, value: "100", validate: vMoney });
    const fields = { groupId, groupName, models, pTpm, pQuota, gTpm, gQuota, pBudget, gBudget };
    const families = code === "CYB" ? ["sonnet", "opus", "haiku", "fable", "mythos"] : ["sonnet", "opus", "haiku"];
    const family = el("select", { class: "select", id: `${code}-family` },
      families.map((k) => el("option", { value: k, text: FAMILY_LABELS[k] })));
    const catalogSelect = el("select", { class: "select", "aria-label": `${code} configured deployment`, onchange: (e) => {
      if (e.target.value) { const current = models.input.value.split(",").map((m) => m.trim()).filter(Boolean); models.input.value = [...new Set([...current, e.target.value])].join(", "); refresh(); }
    } });
    const updateChoices = () => catalogSelect.replaceChildren(el("option", { value: "", text: "Add a deployment from cost definitions…" }),
      [...(state.catalog?.models ?? []), ...discoveredModels].filter((m) => m.family === family.value && (!m.backendId || m.backendId === f.backendId.input.value.trim())).map((m) => el("option", { value: m.deployment, text: `${m.deployment} (${m.model})` })));
    deploymentPickers.push(updateChoices);
    family.addEventListener("change", updateChoices); f.backendId.input.addEventListener("input", updateChoices); updateChoices();
    const pPeriod = periodSelect(`${code}-pPeriod`, "Quota period");
    const gPeriod = periodSelect(`${code}-gPeriod`, "Quota period");
    const enabled = el("input", { type: "checkbox", id: `include-${code}`, checked: code === "STD",
      "aria-controls": `settings-${code}` });
    const panel = el("fieldset", { class: "fieldset classification-settings", id: `settings-${code}`,
      disabled: !enabled.checked, hidden: !enabled.checked },
      el("legend", { class: "visually-hidden", text: `${code} settings` }),
      el("div", { class: "fields" }, groupId.node, groupName.node),
      directory,
      el("h3", { text: "Models" }),
      el("div", { class: "fields" },
        el("div", { class: "field" }, el("label", { for: `${code}-family`, text: "Model family" }), family), models.node), catalogSelect,
      el("h3", { text: "Each person" }),
      el("div", { class: "limit-grid" }, pTpm.node, pQuota.node, pPeriod),
      el("h3", { text: "Whole group combined" }),
      el("div", { class: "limit-grid" }, gTpm.node, gQuota.node, gPeriod),
      el("h3", { text: "Budgets" }),
      el("p", { class: "section-note", text: "Reported, not enforced, while the gateway is in token-limits-only mode." }),
      el("div", { class: "fields" }, pBudget.node, gBudget.node));
    enabled.addEventListener("change", () => {
      panel.hidden = !enabled.checked;
      panel.disabled = !enabled.checked;
      enabled.setAttribute("aria-expanded", String(enabled.checked));
      status.replaceChildren();
      refresh();
    });
    enabled.setAttribute("aria-expanded", String(enabled.checked));
    const section = el("section", { class: "classification-create", "aria-label": `${code} classification` },
      el("label", { class: "check classification-toggle", for: enabled.id }, enabled,
        el("strong", { text: code }), el("span", { class: "muted", text: `Include ${code} access group` })),
      panel);
    const buildClassification = () => {
      const person = limit(pTpm.input, pQuota.input, pPeriod.querySelector("select").value || null);
      const group = limit(gTpm.input, gQuota.input, gPeriod.querySelector("select").value || null);
      return {
        groupId: groupId.input.value.trim(),
        classificationGroupDisplayName: groupName.input.value.trim(),
        familyPolicy: {
          aggregateLimits: { person, group },
          families: { [family.value]: {
            models: models.input.value.split(",").map((m) => m.trim()).filter(Boolean),
            person: { ...person }, group: { ...group },
          } },
        },
        personBudget: { amount: Number(pBudget.input.value || 0), currency: "USD", period: "monthly" },
        aggregateBudget: { amount: Number(gBudget.input.value || 0), currency: "USD", period: "monthly" },
        aggregateMode: "strict", onboardingMode: "block",
      };
    };
    return { code, enabled, fields, section, buildClassification };
  });
  const build = () => {
    const id = f.projectId.input.value.trim();
    return {
      id, projectId: id, displayName: f.displayName.input.value.trim(), status: "active",
      backendId: f.backendId.input.value.trim(), designatedSubscriptionId: f.subscription.input.value.trim(),
      supersedes: null, retiredAt: null,
      classifications: Object.fromEntries(classificationForms.filter((c) => c.enabled.checked).map((c) => [c.code, c.buildClassification()])),
    };
  };
  const refresh = () => { preview.textContent = JSON.stringify(build(), null, 2); };

  const form = el("form", { class: "form", novalidate: true,
    onsubmit: async (e) => {
      e.preventDefault();
      const selected = classificationForms.filter((c) => c.enabled.checked);
      if (selected.length === 0) {
        status.replaceChildren(notice("danger", "Select at least one classification", [el("p", { text: "Include STD, PRM or CYB before creating the project." })]));
        classificationForms[0].enabled.focus();
        return;
      }
      const activeFields = [...Object.values(f), ...selected.flatMap((c) => Object.values(c.fields))];
      const ok = activeFields.map((x) => x.check()).every(Boolean);
      if (!ok) {
        status.replaceChildren(notice("danger", "Some values need fixing", [el("p", { text: "Check the highlighted fields. Nothing was saved." })]));
        form.querySelector('[aria-invalid="true"]:not(:disabled)')?.focus();
        return;
      }
      const groupIds = selected.map((c) => c.fields.groupId.input.value.trim().toLowerCase());
      if (new Set(groupIds).size !== groupIds.length) {
        status.replaceChildren(notice("danger", "Use a different group for each classification", [el("p", { text: "STD, PRM and CYB cannot share the same Entra group Object ID." })]));
        return;
      }
      submit.disabled = true;
      submit.setAttribute("aria-busy", "true");
      submit.textContent = "Creating";
      const doc = build();
      const result = await call("POST", "/projects", { body: doc });
      submit.disabled = false;
      submit.setAttribute("aria-busy", "false");
      submit.textContent = "Create project";
      if (result.status === 201) {
        state.creating = false;
        toast(`Project ${doc.projectId} created. Members get access after the next entitlement sync.`);
        await loadProjects();
        navigate(`#/p/${encodeURIComponent(doc.projectId)}`);
        return;
      }
      status.replaceChildren(errorNotice(errorInfo(result)));
      status.scrollIntoView({ block: "nearest" });
    } },
    el("fieldset", { class: "fieldset" }, el("legend", { text: "Project" }),
      el("div", { class: "fields" }, f.projectId.node, f.displayName.node, f.backendId.node, f.subscription.node)),
    el("section", { class: "section", "aria-labelledby": "create-classifications" },
      el("h2", { id: "create-classifications", text: "Classification groups" }),
      el("p", { class: "section-note", text: "Include one, two or all three groups in this project. Each has its own Object ID, models, token limits and budgets. Use assigned security groups; a person must not belong to more than one classification in the same project." }),
      el("p", { class: "section-note", text: "The numbers below are examples, not approved quotas. Each group's initial limits apply both across all models and to its selected model family." }),
      ...classificationForms.map((c) => c.section)),
    el("details", { class: "json" }, el("summary", { text: "Preview the registry document" }), preview),
    status,
    el("div", { class: "toolbar" }, submit, el("button", { class: "btn btn-quiet", type: "button", text: "Cancel", onclick: () => navigate("#/") })));

  form.addEventListener("input", () => { state.creating = true; refresh(); });
  form.addEventListener("change", refresh);
  const backendChoices = el("datalist", { id: "create-backend-ids" });
  f.backendId.input.setAttribute("list", "create-backend-ids");
  f.backendId.node.append(backendChoices);
  f.backendId.input.addEventListener("change", async () => {
    const backendId = f.backendId.input.value.trim();
    const resource = inventoryChoices.find((r) => r.backendIds?.includes(backendId));
    discoveredModels = [];
    deploymentPickers.forEach((update) => update());
    if (!resource) return;
    try {
      const r = await call("GET", `/v2/deployments?resourceId=${encodeURIComponent(resource.id)}`);
      if (f.backendId.input.value.trim() !== backendId || r.status !== 200 || r.data.state !== "available") return;
      discoveredModels = r.data.data.deployments.filter((d) => d.state === "Succeeded").map((d) => ({
        model: d.model, deployment: d.name, backendId,
        family: (state.catalog?.models ?? []).find((m) => m.model === d.model)?.family ?? /^claude-(haiku|sonnet|opus|fable|mythos)-/.exec(d.model)?.[1],
      }));
      deploymentPickers.forEach((update) => update());
    } catch { status.textContent = "Deployment discovery failed. Existing manual deployment fields remain available."; }
  });
  call("GET", "/v2/inventory").then((r) => {
    if (r.status !== 200 || !["available", "partial"].includes(r.data.state)) return;
    inventoryChoices.push(...r.data.data.resources);
    backendChoices.replaceChildren(...r.data.data.backends.map((b) => el("option", { value: b.backendId, text: b.host })));
  }).catch(() => { status.textContent = "Backend discovery failed. Enter the approved backend ID manually."; });
  setDetail(el("header", { class: "page-head" }, backLink(), el("h1", { text: "New project" }),
    el("p", { class: "section-note", text: "Project ID and access group can't be changed after creation." })), form);
  refresh();
  f.projectId.input.focus();
}

/* ── Boot ────────────────────────────────────────────── */

function show(id) {
  for (const s of ["state-boot", "state-setup", "state-signin", "workspace"]) $(s).hidden = s !== id;
}

async function boot() {
  let config;
  try {
    config = await (await fetch(`${API}/console/config`, { cache: "no-store" })).json();
  } catch {
    config = { configured: false };
  }
  if (!config.configured) return show("state-setup");

  let signedIn = false;
  try {
    signedIn = await initAuth(config);
  } catch {
    $("signin-error").textContent = "Sign-in couldn't start. Reload the page and try again.";
    $("signin-error").hidden = false;
  }
  $("sign-in").addEventListener("click", async () => {
    $("sign-in").setAttribute("aria-busy", "true");
    await auth.pca.loginRedirect({ scopes: [auth.scope] });
  });
  if (!signedIn) return show("state-signin");

  const me = await call("GET", "/console/me");
  if (me.status !== 200) {
    const info = errorInfo(me);
    $("signin-error").textContent = `${info.title}. ${info.detail}`;
    $("signin-error").hidden = false;
    if (auth.mode === "msal") return show("state-signin");
  }
  state.canWrite = me.data?.canWrite === true;
  $("who").textContent = displayName();
  $("role").textContent = state.canWrite ? "Editor" : "Reader";
  $("role").className = state.canWrite ? "pill pill-primary" : "pill";
  $("session").hidden = false;
  $("new-project").hidden = !state.canWrite;
  $("new-project").addEventListener("click", () => navigate("#/new"));
  $("sign-out").addEventListener("click", () => {
    if (auth.mode === "demo") location.search = auth.demoAs === "editor" ? "?as=reader" : "";
    else auth.pca.logoutRedirect({ account: auth.account, postLogoutRedirectUri: `${location.origin}/api/console` });
  });
  if (auth.mode === "demo") $("sign-out").textContent = auth.demoAs === "editor" ? "Switch to reader" : "Switch to editor";
  let filterTimer;
  for (const id of FILTER_IDS) $(id).addEventListener("input", () => {
    syncFilterSummary();
    clearTimeout(filterTimer);
    filterTimer = setTimeout(() => { loadProjects().catch(() => { $("list-status").textContent = "Project search failed. Retry after checking connectivity."; }); }, 250);
  });
  $("load-more").addEventListener("click", async () => {
    $("load-more").disabled = true;
    try { await loadProjects(true); }
    finally { $("load-more").disabled = false; }
  });
  let acceptedHash = location.hash;
  window.addEventListener("hashchange", (e) => {
    const dirty = state.editing && changesBetween(currentPolicy(), state.editing).length || state.creating || hasV2Draft();
    if (dirty && !window.confirm("Discard unsaved changes?")) {
      e.stopImmediatePropagation();
      history.replaceState(null, "", acceptedHash || "#/");
      return;
    }
    acceptedHash = location.hash;
    route();
  });
  window.addEventListener("beforeunload", (e) => {
    if (state.editing && changesBetween(currentPolicy(), state.editing).length || state.creating || hasV2Draft()) e.preventDefault();
  });

  show("workspace");
  $("console-navigation").hidden = false;
  mountV2({ call, state, notify: toast, saved: async (id) => { await loadProjects(); await openProject(id); } });
  window.addEventListener("ccof:catalog-updated", async () => {
    try { const r = await call("GET", "/v2/catalog"); if (r.status === 200) state.catalog = r.data.catalog; }
    catch { toast("Catalog refresh failed. Reload before choosing newly configured deployments."); }
  });
  const catalog = await call("GET", "/v2/catalog");
  if (catalog.status === 200) state.catalog = catalog.data.catalog;
  await loadProjects();
  route();
}

boot();
