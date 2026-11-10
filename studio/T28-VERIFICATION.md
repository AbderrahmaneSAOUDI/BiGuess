# T28 browser dataset verification — 2026-11-10

Scope: account-isolated Studio Web first sync and persistent local drafts.
[Implementation and offline policy](README.md#account-isolated-dataset-and-first-sync-t28).
The Content Backend, D1 and R2 remain undeployed. The production API configuration
is not enabled by this ticket. Mobile source is untouched apart from mandatory
version fields; Studio updates continue through the existing T26A Pages workflow.

| Check | Result | Local evidence |
| --- | --- | --- |
| `bash studio/scripts/check.sh all` | PASS: format, analyzer, 107 tests, release build, boundary | `/tmp/t28-studio-all-final.log` |
| Studio Python packaging tests | PASS: 8 tests, including executable worker policy/cleanup | `/tmp/t28-packaging-final.log` |
| Real Chromium IndexedDB tests | PASS: 10 tests | `/tmp/t28-store-chromium-final.log` |
| Packaged inert preview desktop/mobile smoke | PASS | `/tmp/t28-preview-browser.log` |
| Packaged workspace Chromium flow | PASS: 21 private GETs, zero uploads, zero runtime errors | `/tmp/t28-dataset-browser.log` |
| Static-shell Chromium offline/rollback flow | PASS | `/tmp/t28-static-browser-final.log` |
| Root `flutter test` | PASS: 249 tests | `/tmp/t28-mobile-test.log` |
| Root `flutter analyze` | PASS: no issues | `/tmp/t28-mobile-analyze.log` |
| Agent setup validator | PASS: 962 checks | `/tmp/t28-setup-final.log` |
| Agent Python suite | PASS: 162 tests | `/tmp/t28-agents-final.log` |

The real IndexedDB suite covers reopening a fresh connection, durable queued
changes, project/UID/role isolation, stale-tab compare-and-swap, revoke/late-write
rejection, quota failure after a put with complete transaction rollback/recovery,
v1→v2 migration, future-version refusal, corrupted/cleared storage, closed
handles and blocked schema upgrades. Quota is a controlled browser transaction
fault injection, not an attempt to fill the user's actual storage.

The packaged workspace browser test exercises actual page reload, paginated first
sync, a saved draft/unsent queue surviving reload, second-page failure retaining
the old complete dataset, offline name edits followed by a real offline reload,
revoked authorization on reconnect, refusal to reopen the denied cache offline,
a new identity's offline refusal, Collector B's separate dataset and sign-out
cleanup. It inspects actual IndexedDB for bearer strings and CacheStorage for
private/API entries. Review screenshots are `/tmp/t28-dataset-online.png`,
`/tmp/t28-dataset-offline.png` and `/tmp/t28-dataset-browser-final.png`.
The separate shell test covers cached assets/deep links, private/bearer/query
exclusion and automatic cleanup when rolling back to an API-disabled package.

Controller/API/widget tests cover all-page promotion, last-good retention on
interrupted scans, bounded cursor restart, malformed/duplicate pages, late
responses after logout, account switch editor cleanup, offline-first refusal,
offline draft/queue reopening, denied reconnect, role downgrade, conflicting
remote revisions, storage errors, local CAS conflicts and editor text retention.
Specific regressions exercise failed receipt revocation followed by offline
reopening, recovery from a store-construction error, a changed identity token
between lookup and sync, role changes before promotion, and another tab revoking
its receipt during a scan. Sync uses the exact memory-only token verified for
its scope and rechecks that scope before committing.

Production persists content/queues only in IndexedDB. A nonsecret same-tab
readiness marker contains only a project/UID key and a constant value; it grants
no online authority and never stores a token or role. Known denials synchronously
fence memory and remove readiness without allocating quota, then delete the DB
receipt while retaining drafts. Offline reopening requires readable/writable
readiness plus a complete current-role receipt and restored identity. Missing
markers, new identities, cleared storage and blocked writes fail closed.

The initial system-Google-Chrome Flutter runner stalled before loading tests
(exit 124); this is not counted as a pass. Repeating the current store suite with
Playwright's pinned Chromium completed successfully. Ordinary Studio/Mobile tests
and packaged browser checks also completed. Browser scripts use the same pinned
Playwright version as the deployment workflow.

## Reproduce browser checks

Install isolated test tooling; it does not enter app dependencies:

```bash
npm install --prefix /tmp/t28-browser --no-save --package-lock=false playwright@1.65.0
node /tmp/t28-browser/node_modules/playwright/cli.js install chromium
export NODE_PATH=/tmp/t28-browser/node_modules
export CHROME_EXECUTABLE="$(node -e 'process.stdout.write(require("playwright").chromium.executablePath())')"
cd studio
flutter test --platform chrome test/dataset_store_test.dart
node scripts/static_shell_browser.cjs --fixture
flutter build web --release --no-web-resources-cdn --pwa-strategy=none --target test/browser_dataset_app.dart --output build/dataset-web
node scripts/dataset_browser.cjs
```

The standalone fixture entrypoint is never imported by production `lib/`. It
substitutes synthetic identity and a local per-account HTTP API, exercising the
real session controller, scoped transport, IndexedDB, routing, widgets and
packaged static worker. No production credentials, bypass binding, Worker
release or real private dataset is involved. The production Firebase/Worker
end-to-end flow remains gated on separate Content Backend activation.

Offline behavior is conditional on the shell, restored Firebase identity and site
storage surviving. Private-mode restrictions, quota, eviction or cleared data
can remove it. Unsent browser drafts are not a backup. The offline UI states that
revocation is undetectable until reconnect. Initial publishing, full authoring
forms, image delivery and mutation uploads remain their own later tickets.
Publication revisions are explicitly unknown unless supplied by an authoritative
source; active administrative state is never mislabeled as published.
