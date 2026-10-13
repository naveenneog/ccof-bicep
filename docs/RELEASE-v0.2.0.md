# v0.2.0 verification record

Implementation baseline: `953f41b64ccf46bdb3be9091ede095b4cdcc2512`.
Current candidate source: `e0565ab966205d0df19b0a18687c4fe57728d7bb`
(production runtime `eb1a33296902bd96c3aa2b6ef47b99a10575c82c`),
including snapshot registration/wake fixes and current-attempt correlation,
replay-success preservation and pre-mutation hostname retries.
The public candidate is an allowlisted export with consistent synthetic identity
substitutions, sanitized examples, a public test runner and public repository metadata.
Private ledgers, customer answers, gateway live configurations, generated deployment
artifacts and portal-capture tooling are not exported.

## Candidate checks

- Initial selection used 123 consistent identity substitutions. Final intended-file
  count and scans are measured before candidate publication.
- Initial reusable public-safe scan: zero hits. Final complete source-tree scan is
  required immediately before the source commit.
- All 27 exported Bicep templates compile: 27 pass, zero failures.
- Complete exported Node set: 1,044 tests, 1,038 pass, zero failures, six existing
  opt-in live skips. This includes 303 actual rendered C# behavioral vectors.
- Correction: the exact published `npm test` at `a59a09b` exited 1. Earlier
  reporting overstated the PowerShell result by relying on the final log tail.
  Quickstart fixtures inherited deliberately unresolved identity placeholders;
  the workbook example had an invalid prefixed resource GUID, and an issuer-case
  fixture lost its alphabetic characters during sanitization. These findings
  block full test sign-off until the unchanged assertions pass on repaired data.
  A later full rerun found a missing `Test-CoreFakes.psm1` dependency; it is now
  included. Four repaired suites pass 230 checks and complete CoreAuth passes 25.
  Snapshot helper/correlation selections pass 35 checks, including complete-catalog
  oversize guidance without widening any bound. Complete subsequent
  candidate commands exited 0; the final exact candidate is rerun after the explicit
  workbook placeholder correction. Earlier failing runs are not sign-off.
- Typecheck and build pass on the follow-up candidate.
- Exact exported candidate full command completed exit 0 after the latest helper
  guidance and workbook placeholder changes. Node 26 and separately Node 22.23.3
  each pass 1,038 of 1,044 checks with six existing opt-in live skips; all 16
  exported PowerShell suites pass. Typecheck/build and 27/27 Bicep builds pass.
- The intended 412-file tree passes unchanged generic/private safety rules and
  the exact owner-name/ID-prefix scan with zero hits.
- Source publication is separate from pending release tag/sign-off.

The first public full suite found five export-only failures: private fixture paths,
a missing lower-level budget example, and an email scrub that accidentally changed
an invalid URI-userinfo fixture into a valid host. Synthetic fixtures now replace
private configurations; the negative URI remains negative. The five affected suites
pass 116/116 without deleting or loosening assertions. The separate complete Node
set passed; that result does not imply every PowerShell suite passed.

The earlier private packet completed with 22 passed, two warnings, one failure and one
skip: `tests.run` exited 1 rather than timing out. Full output is being captured
for assertion-level triage. Its fixture output was inside the checked repository;
the strict output guard was retained and artifact placement corrected.
The untruncated diagnostic identified two private Stage3 fixtures still supplying
legacy policy fields. Their inputs now use the frozen familyPolicy contract,
preserving all assertions/models/caps; targeted Handoff15 and RegisterProject35
pass with five bounded reviews. The exact committed9b0c4ff private packet completed
exit 0: 23 PASS, two baseline warnings and one skip. The separate release unknowns
check exits 1 on the 61 unresolved historical entries; this is not release acceptance.
The owner clarified that release go-ahead is not blanket acceptance of historical
unknowns; their unresolved states and release gates remain preserved. This record
does not claim a full release-gate pass or individual risk acceptance.

## Required cloud CI before main update

Public main `a59a09b` had no Actions runs; an empty run list is not green CI.
The candidate adds a read-only, no-Azure-login workflow running the exact full tests,
typecheck/build and every Bicep template on Node 22/26 with .NET 10.
The configuration has test-first contract checks. Publication proceeds through a
sanitized branch/PR and requires actual CI evidence before main merge.
Private run 38451079745 was refused before any job steps because of account
payments/spending limits. That is a provider blocker, not a test failure or waiver.
No owner alternative is inferred from local success.

The bounded public CI/export-fixture council returned Architect PASS-WITH-NOTES,
Coder PASS, QA PASS-WITH-NOTES, UX PASS-WITH-NOTES and Security PASS. Their notes
retain the required exact merge regression and real Node 22/26 CI promotion gates.
QA explicitly blocks main promotion until that evidence exists, not the source
configuration itself. Neither these reviews nor YAML parsing count as a CI run.

All five snapshot fix reviews are now explicit: Architect PASS, Coder PASS, QA PASS,
operator UX PASS-WITH-NOTES, Security PASS-WITH-NOTES. QA's script-local fixture
callback was made self-contained; both File and child-scope execution pass ten
unchanged checks. These verdicts are not full-release or live approval.
Sample workbook identity is an explicit `REPLACE-workbook-resource-guid` rather
than a prefixed or fabricated deployment GUID; tests supply synthetic identity
separately, retaining the sample's no-customer-ID contract.

## Live evidence is separate

The candidate now includes the separately reviewed geography-sentinel and portal
time-context repairs. Exact case-sensitive body `not_available` is an absent
cross-check, never a pricing authority. Trusted deployment geography and real
mismatch guards are unchanged. Every query item uses a nonzero730-day portal
envelope rather than PT0S; KQL still enforces its UTC interval and retention.
This does not extend stored history or promise arbitrary older custom ranges.

The previous source checkpoint's draft PR1 and push CI actually passed:
https://github.com/naveenneog/ccof-bicep/actions/runs/38470532254 and
https://github.com/naveenneog/ccof-bicep/actions/runs/38470532328.
Their head was b9e8a2470acc1fdbd4b8784f41cce37f53258f0e. The real PR checkout
b1e6e62088df68a6f038a318d3d7189c1715237c has tree
e9fa4f0245cf95e61687861981a86aac9b84b306, exactly matching the tested prospective
merge tree. All four Node22/26 jobs succeeded. These are checkpoint receipts,
not CI proof for this newer candidate. Main remains a59a09b until fresh final-tip
full/merge tests and actual CI pass. Enterprise changes remain outside this candidate.

The new public regressions reproduced two PT0S builder failures and one absent
sentinel assertion before applying accepted production changes. Fresh complete
candidate totals and exact gates must supersede the older checks above before
publication; no complete chargeback, settled-billing or release claim is made.

Earlier seed-trigger resynchronization was reported live-passed. Current v3 client/
gateway/resolver E2E, a second designated-subscription route, workbook portal rendering,
real enforcement lag and load capacity are not proven by this export's offline tests.
The live-proof agent's completed results, if supplied, are recorded separately.

No new deployment, remote load, customer change or license choice is made by export.
