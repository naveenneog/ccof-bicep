# Playwright checks for the staged deployment guide

Not part of `npm test`: these open Microsoft Edge. Install once in this folder:
`npm install --no-save playwright-core`.

| Script | What it checks |
| --- | --- |
| `render-docs.py` + `doctest.cjs` | Renders the staged guide and run reports, loads them in Edge, and reports broken images, anchors and local links and page errors |
| `make-portal-steps.py` | From a staged run's configuration and `state.json`, writes the Portal deep link and expected text for each manual Portal step of the guide |
| `keepopen.cjs` | Opens a dedicated Edge profile on the Portal with a local debugging port; the operator signs in and leaves it open (Portal sessions do not survive closing the window) |
| `portal-walk.cjs` | Attaches to that window, reuses its signed-in Portal tab, visits each step, records `pass`, `mismatch`, `error` or `blocked_sign_in`, masks GUIDs in every frame and saves a screenshot |

Steps can set `menu` (a resource menu entry, opened through the blade's menu search, for blades with
no stable deep link) and `click` (a tab to select, for example IAM **Role assignments**). The walker
reuses the existing Portal tab because a new tab can stop at the account picker, which needs the
operator.

```powershell
python tests/playwright/render-docs.py . $env:TEMP\docs.json
node tests/playwright/doctest.cjs $env:TEMP\docs.json $env:TEMP\doc-report.json
python tests/playwright/make-portal-steps.py <config.json> <state.json> steps.json
node tests/playwright/keepopen.cjs <new-profile-dir> <tenant-domain> 9341    # sign in, leave open
node tests/playwright/portal-walk.cjs http://127.0.0.1:9341 <tenant-domain> steps.json <out-dir>
```

The profile directory must be a new, dedicated one: Edge ignores the debugging port on the default
profile. Screenshots mask GUIDs only; review them before publishing.
