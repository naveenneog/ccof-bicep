import { createContext, useContext, useEffect, useState } from "react";
import type { ReactNode } from "react";
import { api } from "../lib/api.ts";
import { UserNames } from "../lib/user-names.ts";
import type { UserLabel } from "../lib/user-names.ts";
import type { DirectoryResult } from "../../src/user-directory.ts";

const Context = createContext<UserNames | null>(null);
export function UserDirectoryProvider({ children }: { children: ReactNode }) {
  const [names] = useState(() => new UserNames(async (objectIds, signal) =>
    (await api<DirectoryResult>("/api/v3/directory/users", { method: "POST", body: { objectIds }, signal })).data));
  return <Context.Provider value={names}>{children}</Context.Provider>;
}

// For exports: the same in-memory lookup the table cells use (null outside the provider).
export const useUserNames = () => useContext(Context);

export function UserIdentity({ objectId, showPrincipalName = true }: { objectId: unknown; showPrincipalName?: boolean }) {
  const names = useContext(Context);
  const id = typeof objectId === "string" ? objectId : "";
  const [user, setUser] = useState<UserLabel | null>(null);
  useEffect(() => {
    let active = true;
    let timer: ReturnType<typeof setTimeout> | undefined;
    setUser(null);
    const update = () => {
      if (names && id) {
        setUser(null);
        names.get(id).then((value) => {
          if (!active) return;
          setUser(value);
          timer = setTimeout(update, value.expiresAt ? Math.max(100, Math.min(300000, value.expiresAt - Date.now())) : 30000);
        });
      }
    };
    update();
    return () => { active = false; clearTimeout(timer); };
  }, [names, id]);
  if (!id) return <span className="muted">—</span>;
  const note = !user ? "Looking up user…" : user.state === "resolved" ? user.displayName || user.userPrincipalName
    : user.state === "not_found" ? "No directory user"
      : user.state === "disabled" ? "User names not enabled"
        : user.state === "permission_required" ? "Name lookup needs User.Read.All" : "Name unavailable";
  return <span className="user-identity">
    <span className={user?.state === "resolved" ? "user-identity-name" : "hint"} title={user?.reason ?? "Current Entra directory label; object ID is the accounting identity."}>{note}</span>
    {showPrincipalName && user?.state === "resolved" && user.userPrincipalName && user.userPrincipalName !== user.displayName &&
      <span className="hint user-identity-upn">{user.userPrincipalName}</span>}
    <code className="user-identity-id">{id}</code>
  </span>;
}
