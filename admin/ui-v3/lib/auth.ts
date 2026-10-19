// Sign-in for the V3 console: the same Entra app registration and scope as V2, with
// /api/console-v3 as its SPA redirect URI. The local demo server returns { demo: true } and accepts
// "demo-editor" / "demo-reader" tokens only; production never does.
import { InteractionRequiredAuthError, PublicClientApplication } from "@azure/msal-browser";
import type { AccountInfo } from "@azure/msal-browser";

export interface AuthState {
  mode: "demo" | "msal" | "setup";
  account: AccountInfo | null;
  demoAs: "editor" | "reader";
}
const state: AuthState & { pca: PublicClientApplication | null; scope: string | null } = { mode: "setup", account: null, demoAs: "editor", pca: null, scope: null };
export const REDIRECT_PATH = "/api/console-v3";

export async function initAuth(): Promise<AuthState> {
  const res = await fetch(`${REDIRECT_PATH}/config`, { cache: "no-store" });
  if (!res.ok) throw new Error("config_unavailable");
  const config = await res.json();
  if (config.demo) {
    state.mode = "demo";
    state.demoAs = new URLSearchParams(location.search).get("as") === "reader" ? "reader" : "editor";
    return state;
  }
  if (!config.configured) { state.mode = "setup"; return state; }
  state.mode = "msal";
  state.scope = config.scope;
  state.pca = new PublicClientApplication({
    auth: { clientId: config.clientId, authority: `https://login.microsoftonline.com/${config.tenantId}`, redirectUri: `${location.origin}${REDIRECT_PATH}` },
    cache: { cacheLocation: "sessionStorage" },
  });
  await state.pca.initialize();
  const result = await state.pca.handleRedirectPromise();
  state.account = result?.account ?? state.pca.getAllAccounts()[0] ?? null;
  if (state.account) state.pca.setActiveAccount(state.account);
  return state;
}

export function signIn() {
  return state.pca?.loginRedirect({ scopes: [state.scope ?? ""], redirectUri: `${location.origin}${REDIRECT_PATH}` });
}

export function signOut() {
  if (state.mode === "demo") {
    const next = state.demoAs === "editor" ? "?as=reader" : "";
    location.href = `${location.pathname}${next}${location.hash}`;
    return;
  }
  state.pca?.logoutRedirect({ account: state.account, postLogoutRedirectUri: `${location.origin}${REDIRECT_PATH}` });
}

export async function token(): Promise<string> {
  if (state.mode === "demo") return `demo-${state.demoAs}`;
  if (!state.pca || !state.account) throw new Error("not_signed_in");
  try {
    return (await state.pca.acquireTokenSilent({ scopes: [state.scope ?? ""], account: state.account })).accessToken;
  } catch (err) {
    if (err instanceof InteractionRequiredAuthError) {
      await state.pca.acquireTokenRedirect({ scopes: [state.scope ?? ""], account: state.account });
    }
    throw err;
  }
}

export function userLabel(): string {
  if (state.mode === "demo") return state.demoAs === "reader" ? "Demo reader" : "Demo editor";
  return state.account?.name || state.account?.username || "Signed in";
}
export const authState = () => state;
