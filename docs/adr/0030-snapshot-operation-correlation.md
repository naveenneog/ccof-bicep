# ADR-0030: Correlate no-VM snapshot completion to an operator handoff

- Status: Integration decision; five independent fix reviews passed, final gate pending
- Packet: WP-CORE-INTEGRATION snapshot council reconciliation
- Does not amend: snapshot validation, membership attestation, lease/removal safeguards

## Evidence and contradiction

Real Architect, Coder, QA and operator UX reviews blocked the snapshot delta:
hash-only selection could accept a previous handoff or replace an applied snapshot
with a subsequent timer replay refusal. A swallowed hostname-read error permanently
prevented wake. The ten-minute wording excluded serial request/CLI time.
Security passed with notes, explicitly retaining the app-settings trust boundary.

## Decision

Each operator invocation generates a fresh temporary operation ID. The Function
echoes it on all snapshot run summaries, including early configuration refusals.
The operator query and selector require the current operation; an observed success
is not overwritten by a later replay refusal. Both helper and Function must be
deployed together. SHA-256 remains content integrity, not directory attestation.

Read the wake hostname with at most three attempts before settings mutation.
Refuse missing hostname with a named remediation error. Keep existing disable/delete
cleanup, additionally removing the operation setting. Document polls plus request
time rather than inventing an overall elapsed deadline.

## Tests and consequences

RED: operation telemetry was undefined and the selector lacked OperationId.
GREEN: 36 coupled Node checks, 24 original helper checks, ten new correlation,
hostname, re-wake and cleanup checks, and full typecheck. Every old assertion remains.
This is counts/control telemetry only, not P-18 telemetry-profile implementation.
Independent follow-up: Architect PASS, Coder PASS, QA PASS, UX PASS-WITH-NOTES,
Security PASS-WITH-NOTES. QA identified script-local fixture callback coupling;
after its self-contained correction, File and child-scope tests both pass ten.
New live acceptance and the exact final-tip gate remain separate. The 61 original
unknowns and customer prerequisites are not waived.
