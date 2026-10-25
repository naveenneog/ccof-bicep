# Admin console V3 bug bash (2026-10-19)

> **Test record from 19 October 2026, kept for reference.** Current behaviour: [ADMIN-V3](ADMIN-V3.md).

Scope: the V3 console (`/api/console-v3`) and the admin Function App only. No resolver, sync or
reconciler code or host settings were changed. V2 (`/api/console`) is unchanged and still works.

| ID | Area | Bug | Fix | Check |
| --- | --- | --- | --- | --- |
| BB-01 | Controls | Foundry backend and other pickers used a browser `<datalist>`, which rendered as a dark, unthemed popup unlike every other dropdown | Shared `ChoiceInput`: a normal themed `<select>` with "Enter another ID…" for manual entry; `<option>` colours follow the Light/Dark theme | `v3-bug-bash.test.ts` BB-01; browser: 0 datalists, option colours match the theme in Light and Dark |
| BB-02 | Budget assistant | Planned from a group budget divided by a guessed member count, although group size isn't known in advance | Plans from a **per-user** monthly budget. A whole-group budget is an optional, independent cap; when off, Apply keeps existing group limits. The API requires `budgetBasis: "person"` and rejects `members` | BB-02, `token-planner.test.ts`, `v3.test.ts` |
| BB-03 | New project | Default classifications were STD/INT/CYB/EXT; CCOF uses STD/PRM/CYB. New groups also got a fixed $500 group budget | Offers STD, PRM, CYB; group budget starts empty (no cap) until set | Code review, build |
| BB-04 | Budget assistant | A 0 % family split or an extreme budget could round to a 1-token or overflowing limit | Such plans are marked not applicable and Apply refuses them with a clear message | BB-04 |
| BB-05 | Budget assistant | "Guaranteed" sizing used the base prompt tier only, so long prompts at the higher tier could exceed the budget | Conservative sizing uses the highest rate across all prompt tiers | BB-05 |
| BB-06 | Rate cards | A failure reading the saved catalog was silently replaced by the packaged rate card, so plans and chargeback could use the wrong prices without warning | The read error is surfaced as unavailable instead of falling back | `v3.test.ts` |
| BB-07 | Performance | Every page reload re-ran every query | Short-lived, size-bounded client read cache that is cleared on any change, plus the existing server cache; **Refresh** bypasses both (`x-ccof-refresh`) | BB-07, `v3.test.ts` |
| BB-08 | Overview | Overview showed cost by model family only, not which projects cost most | Adds month-to-date cost for all projects, highest first; projects without telemetry show unknown, not $0 | Browser |
| BB-09 | Navigation | Opening the site root didn't land on V3 | When V3 is enabled, `/` redirects to `/api/console-v3#/overview` (otherwise `/api/console`). Only the admin host's route prefix changed; every existing URL keeps `/api/...`. The root route uses `{root:maxlength(0)?}` because a route template can't start with `/` | BB-09; demo redirect verified |
| BB-10 | Help | Help was a side drawer of text | Guided overlay: dims the page, highlights each part in turn and explains it | Browser |
| BB-13 | Themes | An old or invalid saved theme name could leave controls in the wrong colour scheme | Unknown values fall back to System | BB-13 |

## Regression run

- Admin: 87 tests pass; `npm run build` succeeds.
- Full repository regression (root suites and workbook scripts): pass, exit 0.
- Browser (Edge, 1440×900, Light and Dark): root redirects to V3 Overview; no datalists; themed
  options; budget assistant shows "Monthly budget per user" and no member count; no horizontal
  overflow; no page or console errors. V2 console loads with its project list.

## Not covered

- Live deployment of the root redirect on Azure Functions Flex: verified by route-template review
  and tests, not on a deployed host. Check `https://<admin-app>/` after deploying.
- Assistive-technology audit and a 10,000-project load test.
