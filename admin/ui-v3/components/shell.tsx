import { createContext, useContext, useEffect, useRef, useState } from "react";
import type { ReactNode } from "react";
import { Icon, Segmented } from "./ui.tsx";
import { href, navigate } from "../lib/router.ts";
import type { Route } from "../lib/router.ts";
import { useMediaQuery, usePersistentFlag, useTheme } from "../lib/prefs.ts";
import type { ThemeChoice } from "../lib/prefs.ts";
import { signOut, userLabel, authState } from "../lib/auth.ts";
import { GuidedHelp } from "./guided-help.tsx";

export interface Session { canWrite: boolean; features: Record<string, string> }
export const SessionContext = createContext<Session>({ canWrite: false, features: {} });
export const useSession = () => useContext(SessionContext);

export const NAV = [
  { id: "overview", label: "Overview", icon: "overview" },
  { id: "projects", label: "Projects", icon: "projects" },
  { id: "chargeback", label: "Chargeback", icon: "chargeback" },
  { id: "budgets", label: "Budgets", icon: "budgets" },
  { id: "reconciler", label: "Reconciler", icon: "reconciler" },
  { id: "foundry", label: "Foundry", icon: "foundry" },
  { id: "health", label: "Health", icon: "health" },
  { id: "audit", label: "Audit", icon: "audit" },
  { id: "cost-definitions", label: "Cost definitions", icon: "cost" },
  { id: "help", label: "Help", icon: "help" },
];

export function helpKey(route: Route): string {
  const [first, second] = route.parts;
  if (first === "projects" && second === "new") return "new-project";
  if (first === "projects" && second) return "project";
  return first ?? "overview";
}

function Breadcrumb({ route }: { route: Route }) {
  const [first, second] = route.parts;
  const section = NAV.find((n) => n.id === first) ?? NAV[0];
  const crumbs: { label: string; to?: string }[] = [{ label: section.label, to: second ? `/${section.id}` : undefined }];
  if (first === "projects" && second) crumbs.push({ label: second === "new" ? "New project" : second });
  return (
    <nav className="breadcrumb" aria-label="Breadcrumb">
      <ol>
        {crumbs.map((c, i) => (
          <li key={i}>{c.to ? <a href={href(c.to)}>{c.label}</a> : <span aria-current="page">{c.label}</span>}</li>
        ))}
      </ol>
    </nav>
  );
}


export function Shell({ route, children }: { route: Route; children: ReactNode }) {
  const session = useSession();
  const narrow = useMediaQuery("(max-width: 819.98px)");
  const [collapsed, setCollapsed] = usePersistentFlag("sidebar", false);
  const [helpOpen, setHelpOpen] = useState(false);
  const [drawer, setDrawer] = useState(false);
  const [theme, setTheme] = useTheme();
  const active = route.parts[0] ?? "overview";
  const topic = helpKey(route);
  const menuRef = useRef<HTMLButtonElement>(null);

  useEffect(() => { setDrawer(false); setHelpOpen(false); }, [route.path]);
  useEffect(() => {
    if (!drawer) return;
    const on = (e: KeyboardEvent) => { if (e.key === "Escape") { setDrawer(false); menuRef.current?.focus(); } };
    addEventListener("keydown", on);
    return () => removeEventListener("keydown", on);
  }, [drawer]);

  const sidebarState = narrow ? (drawer ? "drawer-open" : "drawer-closed") : collapsed ? "collapsed" : "expanded";
  const showLabels = narrow || !collapsed;
  return (
    <div className={`app sidebar-${sidebarState}`}>
      <a className="skip-link" href="#main" onClick={(e) => { e.preventDefault(); document.getElementById("page-title")?.focus(); }}>Skip to content</a>
      <header className="topbar">
        <div className="topbar-start">
          {narrow && (
            <button type="button" className="icon-btn" ref={menuRef} aria-label="Open navigation" aria-expanded={drawer} aria-controls="sidebar" onClick={() => setDrawer(!drawer)}>
              <Icon name="menu" />
            </button>
          )}
          <a className="brand" href={href("/overview")} aria-label="CCOF Admin, overview">
            <span className="brand-mark" aria-hidden="true"></span>
            <span className="brand-name">CCOF</span>
            <span className="brand-sub">Admin</span>
          </a>
          <Breadcrumb route={route} />
        </div>
        <div className="topbar-end">
          <button type="button" className={`btn btn-quiet btn-small help-toggle${helpOpen ? " is-on" : ""}`} aria-pressed={helpOpen} aria-label="Help" onClick={() => setHelpOpen(!helpOpen)}>
            <Icon name="help" size={16} /><span className="hide-narrow">Help</span>
          </button>
          <Segmented<ThemeChoice> label="Theme" value={theme} onChange={setTheme} options={[
            { value: "light", label: "Light", icon: "sun" }, { value: "dark", label: "Dark", icon: "moon" }, { value: "system", label: "System", icon: "system" },
          ]} />
          <div className="session">
            <span className="who hide-narrow"><Icon name="user" size={16} /> {userLabel()}</span>
            <span className={`pill ${session.canWrite ? "pill-primary" : "pill-neutral"}`} title={session.canWrite ? "Can read and change" : "Read only"}>{session.canWrite ? "Editor" : "Reader"}</span>
            <button type="button" className="btn btn-quiet btn-small" onClick={signOut}>{authState().mode === "demo" ? (session.canWrite ? "View as reader" : "View as editor") : "Sign out"}</button>
          </div>
        </div>
      </header>
      {narrow && drawer && <div className="scrim" onClick={() => setDrawer(false)} aria-hidden="true" />}
      <nav id="sidebar" className="sidebar" aria-label="Sections" inert={narrow && !drawer ? true : undefined}>
        <ul>
          {NAV.map((n) => (
            <li key={n.id}>
              <a href={href(`/${n.id}`)} className={`nav-item${active === n.id ? " is-active" : ""}`} aria-current={active === n.id ? "page" : undefined}
                aria-haspopup={n.id === "help" ? "dialog" : undefined}
                onClick={n.id === "help" ? (e) => { e.preventDefault(); setDrawer(false); setHelpOpen(true); } : undefined}
                data-tip={showLabels ? undefined : n.label} aria-label={showLabels ? undefined : n.label}>
                <Icon name={n.icon} />
                <span className="nav-label">{n.label}</span>
              </a>
            </li>
          ))}
        </ul>
        {!narrow && (
          <button type="button" className="nav-item collapse-btn" onClick={() => setCollapsed(!collapsed)} aria-expanded={!collapsed} aria-controls="sidebar"
            data-tip={collapsed ? "Expand sidebar" : undefined} aria-label={collapsed ? "Expand sidebar" : "Collapse sidebar"}>
            <Icon name={collapsed ? "expand" : "collapse"} />
            <span className="nav-label">Collapse</span>
          </button>
        )}
      </nav>
      <main id="main" className="content" inert={helpOpen ? true : undefined}>{children}</main>
      {helpOpen && <GuidedHelp topic={topic} onClose={() => setHelpOpen(false)} />}
    </div>
  );
}

export const go = navigate;
