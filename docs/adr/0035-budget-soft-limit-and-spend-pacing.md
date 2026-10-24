# ADR 0035: Budget soft limit and spend pacing

Status: accepted, 2026-10-24.
Branch: `feat/budget-soft-limit`.

## Context

A person's monthly budget is enforced by the reconciler's `exhausted` flag. The reconciler reads
the Log Analytics ledger, so the flag trails real spend by the ingestion delay plus one timer
interval. The 2026-10-23 Fabrikam lab run measured about nine minutes before spend appeared in
every report (session evidence `files\usage-test`).

The reconciler also writes `realtimeCeilingTokensPerMinute` into each `budgetState` document, and the resolver
returns it as `personCeilingTokensPerMinute`. [COST-MODEL](../COST-MODEL.md) intends this
ceiling to bound spend between reconciler runs. Before this ADR the gateway applied no budget-derived
token limit:

- `claude-messages.template.xml` built the person `tokens-per-minute` from the static family policy only.
- The policy rebuilt the resolver decision from selected fields and left the ceiling out.
- The ceiling was the whole remaining budget per minute, which bounds nothing within one delay.

In that state, a person with budget left could spend at the full per-minute family limit until the next
reconciler run after ingestion caught up.

## Options

1. **Block at a lower threshold** (e.g. exhausted at 90%). Simple, but a user loses budget they were
   given, and the delay still allows overshoot of an unknown size.
2. **Pace with the existing ceiling, plus a soft-limit warning (chosen).** The ceiling lets no more than
   the remaining budget be spent within one pacing window. From the soft limit on, half of that.
   The gateway applies it as its own rate-only token limit.
3. **A fast per-request counter in Cosmos** (COST-MODEL "fast, approximate" signal). Closest bound,
   but it adds a write to the request path. Not in scope.

## Decision

- Two optional reconciler settings, read only as a pair: `RECONCILER_SOFT_LIMIT_PERCENT` (1-99) and
  `RECONCILER_PACING_WINDOW_MINUTES` (1-120, at least the timer interval). With neither set, documents and the
  ceiling are unchanged from before (ADR-0018 decision 9: no hidden default).
- With pacing set, the person ceiling is `floor(remaining / window / worstCaseCcuPerToken)`, and
  `window` doubles once `spent >= budget * percent / 100`. The result is rounded down to a power of two
  (see "Live test" below). While budget remains, the ceiling is at least 1. It is 0 once exhausted, as before.
- The person `budgetState` gains `softLimitPercent` and `softLimitReached`. The `ccof.reconciler.budget.v1`
  line gains `softLimitReached` (person: boolean or null; group: null).
- The gateway copies a whole-number ceiling from 0 to 2,147,483,647 into its cached decision. When it is
  above 0, the gateway applies `llm-token-limit` `ccof-limit-person-budget-pace` with counter key
  `pb:<project>:<oid>:<ceiling>`. Key and value change together because APIM v2 tiers require one
  `tokens-per-minute` value per counter key ([llm-token-limit][ltl]). The limit has no quota and no headers, and is
  additional to the family limits.
- The admin reconciler view reports `budgetState = "warning"` for a current person line with
  `softLimitReached` true. The own-usage API (`/me/usage`) and `ccof-usage` show the warning.

## Consequences

- **Bound.** With pacing, spend in any window can only reach the budget if the reconciler's delay is
  at most one window. The delay is ingestion plus reconciler interval plus the gateway decision cache
  (`allowTtlSeconds`): about 9 + 2 + 2 = 13 minutes with the shipped values. The halved pace past the
  soft limit does not cover a longer delay, because spend can cross the soft limit inside the
  unobserved delay. A review simulation (spend at the full ceiling from zero) reached about 149% of
  budget with a 10-minute window, 102-111% with 20 minutes and about 100% from 30; the examples use 30. Requests already admitted still complete,
  so overshoot is bounded, not zero.
- **Counting.** APIM counts prompt and completion tokens only ([llm-token-limit][ltl]), and the ceiling prices
  every counted token at the worst output rate. Cache-write and cache-read tokens are not counted (BSL-02).
- **Throughput.** Pacing applies below the soft limit too. For example, $250 (25,000 CCU) at
  0.0011 CCU per token and a 10-minute window allows about 2.27M tokens per minute at zero spend.
- **Freshness.** The ceiling reaches the gateway with the decision cache (allow TTL plus last-known-good
  grace), so it can trail the reconciler by that time.
- **Opt-in.** Without both settings the reconciler output is unchanged. A gateway deployed with this
  policy applies that unpaced ceiling (the whole remaining budget per minute) in `budget-state`
  enforcement. In `token-limits-only` enforcement the resolver returns no ceiling and nothing changes.

## Live test (2026-10-24, lab deployment, Sonnet 5, 12 parallel streams, 80% / 30 minutes)

| Run | Budget | Spent before | Load | Final | Over budget |
| --- | --- | --- | --- | --- | --- |
| 1 | $25.00 | $10.09 | $16.94 | $27.03 (108.1%) | $2.03 |
| 2 | $35.00 | $27.03 | $10.08 | $37.11 (106.0%), stopped by the test's $9 cap | $2.11 |
| 3 | $52.11 | $37.11 | $15.19 | $52.29 (100.3%) | $0.18 |

In runs 1 and 2 the ledger total equalled the starting spend plus the client's own per-call total.
In run 3 it was 5229.485 CCU against 5229.614 expected (0.13 CCU short, ledger marked `partial`).

**Run 3** ($15 load on top of the earlier spend; ceiling rounded to a power of two, no per-request
reservation; 11:50-12:41 UTC):

- **Warning.** First `softLimitReached: true` at the 12:10 reconciler run (81.9%).
- **Pace.** 205 requests refused with the tokens-per-minute 429 between 11:57 and 12:36.
  The last successful request started at 12:31:54.
- **Block.** `exhausted` computed at 12:36:00; the first `budget_exhausted` refusal followed at
  12:36:05, and all 331 later requests were refused.
- **Other refusals.** 48 group daily-quota 403s (11:53-11:57, until the lab's group quota was raised),
  19 Foundry 429s and two 503s.

- **Warning.** `/usage` showed `softLimitReached: true` on the first reconciler run past 80% (run 1: 81.2%).
- **Block.** Run 1: `exhausted` at 08:32:01 UTC; every request from 08:39 was refused with
  `budget_exhausted` (708 refusals over 10 minutes). The client's token expired 08:29-08:39, so the
  exact first refused minute is not measured. The ledger delay in this run was 2-4 minutes.
- **Counter key.** Run 1 used the exact ceiling. It changed on every reconciler run, so every run
  opened a new counter: pace 429s appeared only in the first five minutes, while the ceiling was
  constant. The ceiling is now rounded down to a power of two. Run 2 returned 66 pace 429s.
- **Bursts.** APIM's gateway log recorded each streamed request as 16,000 completion tokens
  (`max_tokens`). A per-minute counter admits every waiting request at once when it refills or when
  the key changes, and counts them only when they finish. In run 2, 12 streams (about $1.92) were
  admitted together three times. Overshoot is therefore about one burst of a person's parallel
  requests, not a fraction of the budget (BSL-05). Two ways to bound the burst at the gateway were
  ruled out: a per-request reservation is counted only at the end of the outbound pipeline
  ([rate-limit-by-key](https://learn.microsoft.com/azure/api-management/rate-limit-by-key-policy)),
  and `limit-concurrency` releases its slot when a stream's headers arrive (BSL-06, measured).

Evidence: session `files\budget-live` (`run1`, `run2`, `run3`: calls, `/usage` samples, summaries, reconciler log).

[ltl]: https://learn.microsoft.com/azure/api-management/llm-token-limit-policy
