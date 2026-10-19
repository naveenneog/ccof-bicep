import { useEffect, useState } from "react";

// Hash routing keeps the Functions route model: /api/console-v3 serves one document; #/path selects the page.
export interface Route { path: string; parts: string[]; query: URLSearchParams }
const read = (): Route => {
  const raw = location.hash.replace(/^#/, "") || "/overview";
  const [path, search = ""] = raw.split("?");
  return { path, parts: path.split("/").filter(Boolean).map(decodeURIComponent), query: new URLSearchParams(search) };
};

export function useRoute(): Route {
  const [route, setRoute] = useState(read);
  useEffect(() => {
    const on = () => setRoute(read());
    addEventListener("hashchange", on);
    return () => removeEventListener("hashchange", on);
  }, []);
  return route;
}

export const navigate = (path: string) => { location.hash = path; };
export const href = (path: string) => `#${path}`;
