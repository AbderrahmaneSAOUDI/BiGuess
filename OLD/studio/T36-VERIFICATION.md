# T36 — explicit Commit and incremental Refresh

The browser queue now has an explicit **Commit queued changes** action. Save and
Queue remain local. Commit reauthorizes, validates each unsent operation, persists
its exact batch/key/aggregate revision, sends a T24 batch, and stages an authorized
refresh before atomically acknowledging that operation. Existing aggregates use
`If-Match`; creation uses `If-None-Match: *`. Each operation is a separate batch;
previously acknowledged operations remain committed if a later operation fails.

An uncertain network response or failed local promotion retains the same intent
across reloads. Retry Commit replays the original key, body and precondition.
Editing the queue is blocked until that intent is resolved. A 412/409 preserves
local text/images as a conflict; review, discard and recreate explicitly. No
revision is automatically rebased after a conflict. A prepared image must first
be uploaded using the existing explicit private image action.

Refresh reauthorizes and consumes only the account-bound scoped change feed,
staging all pages and validating relationships before an IndexedDB transaction.
An unchanged refresh transfers an empty change envelope and opaque cursor, not
the dataset. Expired cursors rebuild through bounded initial scans. Owner
removals also rebuild because the frozen feed's minimal tombstones omit fields
needed for restore/purge review. Failed pages, malformed content, quota errors
and stale storage versions retain the last complete saved dataset and drafts.
Authorization denial closes the workspace and invalidates offline access.

Initial authorization bootstraps an empty workspace once. Cached workspaces do
not automatically fetch content on reauthorization. There is no timer polling,
realtime listener, background Commit, or per-keystroke write. Identity/network
lifecycle events may recheck authorization; Commit/Refresh recheck explicitly.
Last complete sync and last acknowledged commit have separate timestamps.

One network action at a time runs per controller, covering uploads, bulk import,
publication review, Commit and Refresh (stronger than per-aggregate serialization).
Separate tabs remain independent editors: IndexedDB version comparisons reject
stale local writes, Commit rejects a queue changed by another tab during
reauthorization, and server revision/idempotency checks reject stale remote
writes. Topic and dashboard editors preserve their opened revision across
Refresh. No tab broadcasts, polling or silent merging are introduced.

## Reproduction

From `studio/`:

```sh
flutter test
flutter analyze
python3 scripts/check_boundary.py
flutter build web
```

The API tests cover incremental paging, empty feeds, upsert/remove, invalid data,
late cancellation, cursor expiry/loops, Owner lifecycle fallback, batch headers
and 401/403/409/412. Controller tests cover Owner/Collector offline edit and
explicit Commit, durable retry, stale tabs/dialogs, action serialization,
revocation, failed snapshot promotion and account/role isolation. Widget tests
verify that rendering sends neither Commit nor Refresh and buttons dispatch
only on user action. Session tests verify no periodic network checks.

Root Flutter and agent gates and the local backend typecheck/full tests also run.
Backend fixtures use local Workerd/D1/R2 and synthetic signed identities. Browser
fixtures use synthetic loopback identity and real IndexedDB; none establish live
Firebase or production-backend validation. No remote migration, backend deploy,
real content publication, or product refactor is part of T36.

## Results in this checkout (2026-11-11)

- Studio: 264 tests passed; analyzer clean; 77 Dart files formatted.
- Mobile regression: 249 tests passed; analyzer clean; local offline gate passed.
- Agent setup: 962 checks passed; 163 automation tests passed.
- Content API: typecheck passed; 217 local Worker tests passed (zero failures).
- Studio boundary and release web build passed; browser fixture release build
  passed with locally bundled web resources. Flutter emits existing optional
  Cupertino-font and Wasm dry-run warnings; release compilation succeeds.

- Chromium acceptance passed: two isolated Collectors plus Owner, offline
  edit/save/queue with no writes, explicit Commit, manual empty-feed Refresh,
  foreign-Pack absence, stale-tab IndexedDB rejection, remote 412 retaining
  conflict text, and revocation preventing further dataset requests. The run
  made 46 synthetic fixture requests with no browser errors.

Browser reproduction requires Playwright available to Node and Chromium:

```sh
flutter build web --release --no-web-resources-cdn --pwa-strategy=none \
  --target test/browser_dataset_app.dart --output build/dataset-web
CHROME_EXECUTABLE=/usr/bin/google-chrome node scripts/sync_browser.cjs
```

The script uses only loopback HTTP and disposable browser contexts. It packages
its own public fixture config and removes its temporary artifact directory.
