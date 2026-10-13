# Bounded mock load — WP-LOAD-PREP

## Contract and unknowns (2026-10-13)

One scoped packet, based on `cb6967e`, owned paths `scripts/load/**`, `tests/load/**`,
the approved root discovery shim `tests/bounded-load.test.ts` and this document.
Shared ledger updates belong to the integration coordinator
(ROADMAP's work-package rule). Acceptance: offline executable 10/50/100 RPS ramp,
hard request/concurrency/wall-clock bounds, separate fail-closed and quota probes,
redacted percentile/error/throughput/memory reporting, tested without Azure traffic.

ASSUMED: owner peak RPS, latency budget and spend ceiling are unavailable; 10/50/100
RPS are **test settings, not capacity requirements**. There is no approval here for
paid inference or provisioning. Detector: explicit isolated-mock attestation for
every non-loopback run; no real-Foundry target option.

OPEN prerequisite for live proof, not for offline harness: APIM-reachable isolated
mock and dedicated load identity/group. Live-proof agent confirmed existing
`/anthropic-q2/v1/messages` routes to **real Foundry**, no mock exists, and quick-start
groups have no members. Do not point this harness at that route.

Reuse: Node's existing `node --test` runner, native HTTP/fetch and the gateway's
`x-ccof-project`/Anthropic request contract. Existing `Test-OwnerSmoke.ps1` remains
the sign-in helper. `infra/manual/Test-ManualLoad.ps1` in `ddec6fb` is a separate
confirmed **paid-inference** smoke test, not a safe mock ramp.

## Offline validation and council

Integration addendum: real independent QA review BLOCKED the wall-cancellation
regression proof because its 50 ms request timeout could satisfy the test before
the 200 ms shared wall abort. The strengthened test uses a longer request timeout,
requires cancelled results with zero request timeouts, and retains a separate
individual-timeout regression. No production constraint or assertion was weakened.
Integration review/gate outcomes are recorded in root STATUS, not inferred from
the scoped self-review below.

RED: `node --test tests\load\bounded-load.test.mjs` failed with
`ERR_MODULE_NOT_FOUND` for the not-yet-written harness. GREEN: all ten tests
pass, covering finite bounds, percentile math, request accounting, concurrency,
wall timeout, error/p95 aborts, failed auth preflight and redirect refusal.
Second RED found a small-sample latency-budget acceptance bug (`true !== false`);
GREEN now applies the final p95 budget even below 20 samples. Additional tests
cover saturated concurrency and credential-input refusal/redaction. Root import
shim ownership was approved by integration agent `e6c0e14d` so the existing
repository test command discovers this suite without altering the runner.

Scoped self-review council (no nested delegation):
Architect PASS — native runner, no application/policy changes or dependencies.
Coder PASS — finite scheduler, bounded samples and response bodies.
QA PASS — negative and stalled-response tests, no Azure calls.
UX PASS-WITH-NOTES — JSON-only reports, exact commands below; configuration failure
is deliberately redacted rather than echoing arguments.
Security PASS — credentials via stdin only, no redirects, HTTPS remote target,
explicit isolation confirmation, no response/prompt/token/endpoint logging.

## Exact offline commands (no Azure, no dependencies to install)

From the repository root on Node 22 or later:

```powershell
$env:CCOF_LIVE_TESTS = '0'
node --test tests\bounded-load.test.ts
node scripts\load\bounded-load.mjs --target local-mock --rates 10,50,100 --duration 15 --concurrency 20 --max-requests 3000 --wall-seconds 90 --timeout-ms 2000 --max-error-rate 0.05 --p95-ms 2000 --max-rss-mb 256
```

The default is an in-process loopback fixture, closed on completion. It validates
the **driver**, not production gateway/resolver performance. Five correctness
requests precede 2,400 offered steady-state requests in the default 45-second ramp.
The 3,000-request cap includes correctness probes. No retries or queued requests:
saturated slots are dropped and reported, never presented as achieved throughput.
Each stage drains in-flight requests before the next. Wall time includes probes,
stages and draining; abort cancels outstanding fetches. CLI stdin admission is
separately bounded at 10 seconds before the run. Exit 0 = all checks, latency
budget and steady responses pass with zero drops; 1 = failed test/stop; 2 =
configuration or token-input refusal. Ctrl+C/SIGTERM aborts admission.

## Live mock proof prerequisite — owner/live-proof agent only

1. Use a **non-current isolated APIM API/revision** with normal JWT, project
   membership, resolver, per-person/family/group limits and telemetry retained.
   Its backend must be a controlled, deterministic Anthropic-shape mock reachable
   **from APIM**, with DNS/TLS/network verified from that path. Loopback on this
   workstation is not reachable from APIM. No generic public echo service.
2. Confirm the mock receives **no developer Authorization/subscription key**:
   strip those at the backend boundary, omit Foundry OAuth token acquisition for
   this mock API only, and use a dedicated mock backend credential if required.
   Disable request/response body capture on the isolated API. Do not disable
   gateway authentication or change the current production API.
3. Prepare dedicated flat group `CCOFLOAD01STD` / project `CCOFLOAD01`, separate
   allowed, non-entitled and quota-exhausted test identities/scopes. Do not use
   customer memberships or owner/customer quota counters. Allow the synthetic
   model name only in this project's test policy. Set allowed test quotas high
   enough for the bounded run; preseed the separate exhausted scope for exactly
   one quota probe. Preserve all other policy enforcement.
4. Verify one allowed request returns 200 **from the mock**; one no-token and
   invalid-token request return 401; cross-project and denied test identity return
   403. Quota probe must return the expected 403/429 **and error code**, not a
   generic entitlement refusal. Select `--quota-status` / `--quota-error` to match
   the policy (gateway token-limit errors commonly use `rate_limit_error`).
5. Record API/revision/policy/mock deployment hashes, UTC run window, dedicated
   identity/scopes (no tokens), client host/runtime, and APIM/backend/resource
   metrics. Obtain explicit approval for any mock hosting cost or resource
   creation **before provisioning**; this package provisions nothing. Existing
   StandardV2 API gateway remains a cost-bearing service even with mock inference.

Remote launch, **only after all prerequisites**, in an interactive PowerShell
without transcript/debug logging. Obtain fresh JWTs for the three dedicated
contexts via approved SSO; paste only into secure prompts, never command-line
arguments, history, files or environment variables:

```powershell
$secure = @{}
$plain = @{}
try {
  foreach ($key in 'successToken', 'deniedToken', 'quotaToken') {
    $secure[$key] = Read-Host "Short-lived dedicated $key" -AsSecureString
    $plain[$key] = ConvertFrom-SecureString $secure[$key] -AsPlainText
  }
  $plain | ConvertTo-Json -Compress | node scripts\load\bounded-load.mjs --target gateway-mock --confirm-isolated-mock --token-stdin --endpoint https://ISOLATED-APIM-HOST/ISOLATED-API/v1/messages --project CCOFLOAD01 --denied-project CCOFLOADDENY --quota-project CCOFLOADQUOTA --model load-mock-model --quota-status 403 --quota-error rate_limit_error --rates 10,50,100 --duration 15 --concurrency 20 --max-requests 3000 --wall-seconds 90 --timeout-ms 2000 --max-error-rate 0.05 --p95-ms 2000 --max-rss-mb 256
} finally {
  $plain.Clear()
  foreach ($value in $secure.Values) { $value.Dispose() }
  $secure.Clear()
}
```

JWT expiry is inspected locally (not authentication) and must have between
`wall-seconds + 30` seconds and two hours remaining. Gateway/platform still
validates issuer/audience/signature. HTTPS URLs with userinfo, query credentials,
fragments and known Foundry/Anthropic hosts are refused; redirects are not followed.
`--confirm-isolated-mock` is an operator attestation, **not automatic proof of
backend isolation**. Do not pass real Foundry-backed APIM URLs.

`--target resolver-mock --person-id <dedicated-test-oid>` uses the existing
`{personId, projectId}` resolver body instead of an Anthropic message. Use only a
private isolated resolver clone/mock with its own registry and platform auth,
an approved caller token and configured negative/quota contexts. Do not grant a
load client direct access to the live resolver (APIM-only trust boundary,
ADR-0009), forge platform principal headers, or disable EasyAuth to make it run.

## Read the evidence honestly

JSON reports per-stage/aggregate nearest-rank p50/p95/p99 over **all completed
attempts**, success and completion RPS, HTTP counts, auth401/refusal403/quota429,
5xx, timeout, cancellation, network, response-size and redirect errors. Body
consumption is capped at 64 KiB. `quota429` is an HTTP category (rate/admission
may also return 429), not proof of a particular policy reason.
Correctness is reported separately; its expected refusals are never included
in steady-state error rates. RSS and heap are **load-client** memory, not server
memory. Observe APIM/resolver memory, CPU, request latency, Cosmos RU/throttles
and resolver-call/cache counts independently. The ramp is one identity and
warm cache; it does not prove cold-cache/fan-out load or multi-identity fairness.

Stops: any steady 401/403 immediately; wall/request/RSS cap; error rate > chosen
bound or p95 > budget after 20 completions; final stage p95 budget also applies
to smaller samples. Drops fail acceptance. A cap-triggered run is partial
evidence, never a capacity pass.

Mock-backed results measure **gateway/control-plane overhead only**, not real
inference throughput, token streaming/TTFT, Foundry quota or deployment capacity.
No 15,000-developer scale claim follows from a developer population: concurrent
active callers, requests/developer/second, token sizes/model mix, cache-hit ratio,
regional quota and admission limits must be measured/agreed separately.

Final-hour sequence before ~01:35 IST Oct 14: verify isolated mock+identity
prerequisites first; run correctness+ramp with limits unchanged; review JSON and
Azure telemetry; repeat only after reviewing the cumulative traffic/cost bound;
remove test identities/scopes/API through approved cleanup. If mock prerequisites
are unavailable, deliver offline driver evidence plus this blocker, **not** a
substituted paid-inference load run.

## Recorded offline evidence

Full default ramp executed on Windows, Node v26.1.0, 2026-10-13:
45.170 seconds; 2,405 total started (five checks + 2,400 steady);
2,400/2,400 steady HTTP 200; zero errors/drops; peak concurrency 10;
steady completion/success rate 53.283 RPS averaged across all three stages;
aggregate p50/p95/p99 16.53/45.44/121.09 ms;
client peak RSS 157,290,496 bytes and final heap 46,494,984 bytes.
Result: `passed=true`, `stopReason=completed`. This is **driver-fixture evidence
only**, not an Azure measurement.

`node --test tests\bounded-load.test.ts`: 10/10 passed.
`npm exec --no -- tsc -p tsconfig.typecheck.json`: passed after missing compiler
validation failed; restored lockfile with `npm ci --ignore-scripts --no-audit
--no-fund --quiet` (no manifest changes). `git diff --check`: passed.
First green implementation commit: `5339cfc`.
`node .ironclad\gate.mjs --stage packet --no-run`: audit passed (20 pass, four
skip, two warnings). Full packet gate failed **only** `tests.run`, which timed
out at the unchanged 900-second charter budget; audit/typecheck/build did not
fail. This is **not full packet acceptance**. The integration coordinator
acknowledged the historical >900-second shared-machine suite and requested
publication of the verified candidate while its combined release gate runs.
Duplicate retry was stopped on that request; no gate/charter was weakened.
Live proof remains blocked on the isolated mock prerequisite.
