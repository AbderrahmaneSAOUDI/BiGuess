# T27B local verification — 2026-11-10

Implementation: [administrative API and T28 handoff](STUDIO.md). Approved target:
[Studio scope v1](../../contracts/studio/v1/README.md). No Content Backend cloud
deployment, remote D1 migration or remote R2 upload was performed. All test databases,
objects, identities and signing keys are local fixtures.

The starting checkout already contained the T27B implementation in 11 changed
paths. Those changes were reviewed and completed in place; no unrelated paths
were staged. Migration files 0001–0005 and frozen public content contracts remain
unchanged. The only Mobile changes are the required synchronized version fields.

| Check | Result | Local log |
| --- | --- | --- |
| `npm run typecheck` (content API) | PASS, exit 0 | terminal output |
| `npm test` (content API, before adding contract runner) | PASS, 70 tests, 0 failures | `/tmp/t27b-backend-baseline.log` |
| `node --test --test-concurrency=1 test/studio-scope.test.mjs` (final file) | PASS, 16 tests, 0 failures | `/tmp/t27b-scope-final.log` |
| `node --test --test-concurrency=1 test/studio-contract.test.mjs` | PASS, 118 tests, 0 failures/skips | `/tmp/t27b-contract-final.log` |
| `flutter test` (repository root) | PASS, 249 tests | `/tmp/t27b-flutter-test.log` |
| `flutter analyze` (repository root) | PASS, no issues | `/tmp/t27b-flutter-analyze.log` |
| `python3 .agents/scripts/validate_setup.py` | PASS, 962 checks | `/tmp/t27b-setup.log` |
| `python3 -m unittest discover -s .agents/tests -v` | PASS, 162 tests | `/tmp/t27b-agents.log` |

`npm test` builds the Worker with Wrangler's staging **dry-run**, then executes
all `test/*.test.mjs` files in Workerd/Miniflare. Repeating that command now also
includes the added contract runner and final concurrent-parent-deletion test.
Tests use real signed RS256 JWTs and D1/R2 bindings; only Google JWKS discovery
is intercepted. No application authentication bypass or production test key exists.

The contract runner executes 118 of 121 approved recipe vectors. The remaining
three are explicitly client-stage T28 cache/session invariants. The own-image
future vector lists 501 while its setup and README require disabled routes to
return 404 during T27B; the test records that discrepancy and asserts 404 without
changing the approved fixture. The generation-race vector injects the D1 guard's
rejection deterministically; the separate concurrent-parent-deletion scope test
exercises actual overlapping HTTP writers. Cursor expiry, unavailable history,
missing attribution and role/filter/endpoint replay have executable coverage.

Review verdict: approved for this local gate. Independent review found no
remaining concrete cross-account disclosure or mutation/replay defect. The
account-level Unicode search resource limitation below remains documented.

The scope suite proves two-Collector list/detail/search/initial/feed isolation,
guessed IDs and cross-aggregate batches, Owner global access, authoritative
creator inheritance, lifecycle retention, stale tokens/revocation, downgraded
idempotency replay, unchanged failure snapshots across all application tables,
transaction rollback, encrypted cursor binding, foreign-write page stability,
Unicode search, Pack-bound image attachment and disabled image routes. The final
suite also races an actual Collector Card update against Owner Topic deletion.
Whichever validates first, the deletion leaves descendants deleted and a losing
edit creates no saved commit. The migration test compares every old table,
includes legacy and purged fences, checks immutable attribution and rejects
orphan/wrong-parent attribution, then reapplies 0006 after new writes without
changing creator evidence, history, counters or cursor keys.

Public catalog/publication/download/revision/delta regression tests pass. Public
HTTP projections and frozen schemas are unchanged; trusted publication's private
administrative projection now preserves creators and captures scoped changes
atomically with its existing generation guard.

Limitations: Unicode search currently loads only the account-authorized remaining
records into Worker memory before matching and paging. Large account datasets
may need a persisted folded-name index. Browser persistence/session-switch UI is
T28; no browser dataset is implemented here. Private image delivery/upload stays
disabled; references are opaque and attachments require trusted Pack grants.
