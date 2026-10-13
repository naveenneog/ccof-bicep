import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

// Node runs the real path of its entry script; compare real paths so a junction or symlink checkout
// still runs the command instead of silently doing nothing and exiting 0.
export function isMain(moduleUrl: string, entry: string | undefined = process.argv[1]): boolean {
  if (!entry) return false;
  try {
    return realpathSync(entry) === realpathSync(fileURLToPath(moduleUrl));
  } catch {
    return false;
  }
}
