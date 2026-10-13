# v0.2.0 verification record

Implementation baseline: `953f41b64ccf46bdb3be9091ede095b4cdcc2512`.
Published follow-up source: `deb6728b29db4bdaf3dd623e3b717e4c5310bf48`,
including the live-agent no-VM snapshot commits and their fixture/selector correction.
The public candidate is an allowlisted export with consistent synthetic identity
substitutions, sanitized examples, a public test runner and public repository metadata.
Private ledgers, customer answers, gateway live configurations, generated deployment
artifacts and portal-capture tooling are not exported.

## Candidate checks

- Sanitized source selection: 397 source files; 123 identity substitutions.
- Initial reusable public-safe scan: zero hits. Final complete source-tree scan is
  required immediately before the source commit.
- All 27 exported Bicep templates compile: 27 pass, zero failures.
- Complete exported Node set: 1,040 tests, 1,034 pass, zero failures, six existing
  opt-in live skips. This includes 303 actual rendered C# behavioral vectors.
- All 14 original exported PowerShell suites pass; the added snapshot helper suite
  passes 23/23. The full command was first run end-to-end, then all affected Node
  suites/the full Node set and the added suite were rerun after export repairs.
- Typecheck and build pass on the follow-up candidate.
- Source publication is separate from pending release tag/sign-off.

The first public full suite found five export-only failures: private fixture paths,
a missing lower-level budget example, and an email scrub that accidentally changed
an invalid URI-userinfo fixture into a valid host. Synthetic fixtures now replace
private configurations; the negative URI remains negative. The five affected suites
pass 116/116 without deleting or loosening assertions. Every exported PowerShell
suite passed in that full run; the complete Node set and new snapshot checks are rerun
before the source commit.

The private release suite is running with the owner's bounded longer command timeout.
The owner clarified that release go-ahead is not blanket acceptance of historical
unknowns; their unresolved states and release gates remain preserved. This record
does not claim a full release-gate pass or individual risk acceptance.

## Live evidence is separate

Earlier seed-trigger resynchronization was reported live-passed. Current v3 client/
gateway/resolver E2E, a second designated-subscription route, workbook portal rendering,
real enforcement lag and load capacity are not proven by this export's offline tests.
The live-proof agent's completed results, if supplied, are recorded separately.

No new deployment, remote load, customer change or license choice is made by export.
