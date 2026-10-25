---
name: usage
description: Show your CCOF budget for this month - spend, budget and what is left per project - from the CCOF gateway. Use when the user asks about their usage, spend, budget, quota or remaining allowance.
---

Run this command and show its output to the user exactly as printed:

```
ccof-usage
```

If `ccof-usage` is not on PATH, run `node "<CCOF helper folder>/bin/ccof-usage.mjs"` with the folder the
CCOF helper was installed to (the folder that holds `ccof-token`).

- The figures are the user's own CCOF budget per project, as of the last reconciler run (usually a
  few minutes old). Usage not yet priced is not included.
- For this session's token counts and local cost estimate, the built-in screen is `/cost`.
- If the command reports `sign_in_required`, tell the user to run `ccof-token login`.
- If it reports `usage_not_deployed`, the gateway does not have the usage API yet; tell the user to
  contact the CCOF administrators.
- Do not guess or calculate figures yourself.
