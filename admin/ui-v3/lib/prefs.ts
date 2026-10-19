import { useEffect, useState } from "react";

// Local, per-browser preferences only: theme and sidebar state. Nothing sensitive is stored.
export type ThemeChoice = "light" | "dark" | "system";
const THEME_KEY = "ccof.v3.theme";
const SIDEBAR_KEY = "ccof.v3.sidebar";
const HELP_KEY = "ccof.v3.help";

const get = (key: string) => { try { return localStorage.getItem(key); } catch { return null; } };
const put = (key: string, value: string) => { try { localStorage.setItem(key, value); } catch { /* private mode */ } };

const media = () => matchMedia("(prefers-color-scheme: dark)");
export function applyTheme(choice: ThemeChoice) {
  const resolved = choice === "system" ? (media().matches ? "dark" : "light") : choice;
  document.documentElement.dataset.theme = resolved;
  document.documentElement.dataset.themeChoice = choice;
  document.querySelector('meta[name="color-scheme"]')?.setAttribute("content", resolved);
}

export function useTheme(): [ThemeChoice, (t: ThemeChoice) => void] {
  const [choice, setChoice] = useState<ThemeChoice>(() => (get(THEME_KEY) as ThemeChoice) || "system");
  useEffect(() => {
    applyTheme(choice);
    if (choice !== "system") return;
    const m = media();
    const on = () => applyTheme("system");
    m.addEventListener("change", on);
    return () => m.removeEventListener("change", on);
  }, [choice]);
  return [choice, (t) => { put(THEME_KEY, t); setChoice(t); }];
}

export function usePersistentFlag(key: "sidebar" | "help", initial: boolean): [boolean, (v: boolean) => void] {
  const storageKey = key === "sidebar" ? SIDEBAR_KEY : HELP_KEY;
  const [value, setValue] = useState<boolean>(() => { const v = get(storageKey); return v === null ? initial : v === "1"; });
  return [value, (v) => { put(storageKey, v ? "1" : "0"); setValue(v); }];
}

export function useMediaQuery(query: string): boolean {
  const [match, setMatch] = useState(() => matchMedia(query).matches);
  useEffect(() => {
    const m = matchMedia(query);
    const on = () => setMatch(m.matches);
    m.addEventListener("change", on);
    on();
    return () => m.removeEventListener("change", on);
  }, [query]);
  return match;
}
