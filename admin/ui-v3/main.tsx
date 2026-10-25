import { StrictMode, useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { initAuth, signIn } from "./lib/auth.ts";
import type { AuthState } from "./lib/auth.ts";
import { api } from "./lib/api.ts";
import { useRoute } from "./lib/router.ts";
import { applyTheme } from "./lib/prefs.ts";
import type { ThemeChoice } from "./lib/prefs.ts";
import { SessionContext, Shell } from "./components/shell.tsx";
import type { Session } from "./components/shell.tsx";
import { Button, ErrorNote, ToastHost } from "./components/ui.tsx";
import { Overview } from "./pages/overview.tsx";
import { Projects } from "./pages/projects.tsx";
import { ProjectDetail } from "./pages/project-detail.tsx";
import { NewProject } from "./pages/new-project.tsx";
import { Chargeback } from "./pages/chargeback.tsx";
import { Budgets } from "./pages/budgets.tsx";
import { Reconciler } from "./pages/reconciler.tsx";
import { Foundry } from "./pages/foundry.tsx";
import { Health } from "./pages/health.tsx";
import { Audit } from "./pages/audit.tsx";
import { RemovalLimits } from "./pages/removal-limits.tsx";
import { Backends } from "./pages/backends.tsx";
import { CostDefinitions } from "./pages/cost-definitions.tsx";
import { HelpPage } from "./pages/help.tsx";
import { UserDirectoryProvider } from "./components/user-identity.tsx";

try { applyTheme((localStorage.getItem("ccof.v3.theme") as ThemeChoice) || "system"); } catch { applyTheme("system"); }

function Page() {
  const route = useRoute();
  const [first, second, third] = route.parts;
  // Focus moves to the page title when the page changes, not when a tab within it changes.
  const pageKey = first === "projects" ? `${first}/${second ?? ""}` : first ?? "overview";
  useEffect(() => {
    const t = setTimeout(() => document.getElementById("page-title")?.focus({ preventScroll: true }), 0);
    document.getElementById("main")?.scrollTo({ top: 0 });
    return () => clearTimeout(t);
  }, [pageKey]);
  let page;
  switch (first ?? "overview") {
    case "overview": page = <Overview />; break;
    case "projects": page = second === "new" ? <NewProject /> : second ? <ProjectDetail id={second} tab={third ?? "overview"} /> : <Projects query={route.query} />; break;
    case "chargeback": page = <Chargeback query={route.query} />; break;
    case "budgets": page = <Budgets />; break;
    case "reconciler": page = <Reconciler />; break;
    case "foundry": page = <Foundry />; break;
    case "health": page = <Health />; break;
    case "audit": page = <Audit query={route.query} />; break;
    case "removal-limits": page = <RemovalLimits />; break;
    case "backends": page = <Backends />; break;
    case "cost-definitions": page = <CostDefinitions />; break;
    case "help": page = <HelpPage />; break;
    default: page = <div className="page"><h1 id="page-title" tabIndex={-1}>Page not found</h1><p><a href="#/overview">Go to the overview</a></p></div>;
  }
  return <Shell route={route}>{page}</Shell>;
}

function Center({ children }: { children: React.ReactNode }) {
  return <main className="center-state" id="main"><div className="state-body">{children}</div></main>;
}

function App() {
  const [auth, setAuth] = useState<AuthState | null>(null);
  const [session, setSession] = useState<Session | null>(null);
  const [error, setError] = useState<unknown>(null);
  useEffect(() => { initAuth().then(setAuth, setError); }, []);
  useEffect(() => {
    if (!auth || auth.mode === "setup" || (auth.mode === "msal" && !auth.account)) return;
    api("/api/v3/capabilities").then((r) => setSession({ canWrite: Boolean(r.data.canWrite), features: r.data.features ?? {} }), setError);
  }, [auth]);
  if (error) return <Center><h1>The admin console couldn't start</h1><ErrorNote error={error} retry={() => location.reload()} /></Center>;
  if (!auth) return <Center><p className="muted" role="status">Loading the admin console…</p></Center>;
  if (auth.mode === "setup") {
    return (
      <Center>
        <h1>Sign-in isn't set up yet</h1>
        <p>Set these application settings on the admin Function App, then reload:</p>
        <dl className="settings-list">
          <div><dt><code>ADMIN_TENANT_ID</code></dt><dd>Directory (tenant) ID</dd></div>
          <div><dt><code>ADMIN_UI_CLIENT_ID</code></dt><dd>Client ID of the "CCOF Admin" app registration</dd></div>
          <div><dt><code>ADMIN_UI_SCOPE</code></dt><dd><code>api://&lt;client-id&gt;/Projects.Manage</code></dd></div>
        </dl>
        <p className="muted">Add <code>https://&lt;admin-host&gt;/api/console-v3</code> as a SPA redirect URI. See docs/ADMIN-V3.md.</p>
      </Center>
    );
  }
  if (auth.mode === "msal" && !auth.account) {
    return (
      <Center>
        <h1>Manage CCOF projects</h1>
        <p>Projects, limits, budgets and chargeback in one place. Sign in with your work account.</p>
        <Button variant="primary" onClick={() => signIn()}>Sign in with Microsoft</Button>
      </Center>
    );
  }
  if (!session) return <Center><p className="muted" role="status">Checking your access…</p></Center>;
  return <SessionContext.Provider value={session}><UserDirectoryProvider><ToastHost><Page /></ToastHost></UserDirectoryProvider></SessionContext.Provider>;
}

createRoot(document.getElementById("root")!).render(<StrictMode><App /></StrictMode>);
