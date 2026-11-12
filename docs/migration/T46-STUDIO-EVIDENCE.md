# T46 Studio verification evidence

Date: 2026-11-12, Africa/Algiers. Tested application source at
`20bb0edf088de6ee9df3a1a65708f06836ab2c6e`. Verification only: no product
changes, publishing, backend deployment, production identity changes or releases.
Synthetic fixtures use isolated loopback servers and disposable browser contexts.
Their identity adapter is not production Firebase authentication.

## Reproduction

From repository root:

```sh
python3 -m unittest discover -s studio/test -p 'test_*.py' -v
```

From `studio/`, with Playwright 1.65.0 installed outside the repository:

```sh
export NODE_PATH=/tmp/biguess-t36-browser/node_modules
export CHROME_EXECUTABLE=/usr/bin/google-chrome
bash scripts/check.sh all
flutter test --platform chrome test/dataset_store_test.dart
flutter build web --release --no-web-resources-cdn --pwa-strategy=none \
  --target test/browser_dataset_app.dart --output build/dataset-web
node scripts/browser_smoke.cjs
node scripts/static_shell_browser.cjs --fixture
node scripts/image_preparation_browser.cjs
node scripts/legacy_preparation_test.cjs
node scripts/dataset_browser.cjs
node scripts/sync_browser.cjs
node scripts/profile_browser.cjs
node scripts/image_ingestion_browser.cjs
```

The ingestion check additionally consumes the locally bundled Content API
`dist/index.js` and WASM from `npm test`; it does not deploy that bundle.

## Results

| Check | Result | Evidence under `/tmp/t46/studio/` |
| --- | --- | --- |
| Studio full quality/build/boundary | PASS: 288 tests, clean analysis, format unchanged, release build | `all.log` |
| Static deployment packaging | PASS: 9 tests, including generated-worker cache policy | `packaging-tests.log` |
| Packaged inert-preview desktop/narrow touch browser | PASS: navigation, history, refresh, offline and public boundaries | `preview-desktop-mobile.log` |
| Actual Chromium IndexedDB transactions | PASS: 10 tests | `indexeddb-chrome.log` |
| Current browser fixture release build | PASS | `dataset-build.log` |
| Broad dataset browser flow | FAIL: conflict assertion at `dataset_browser.cjs:332` | `dataset_browser.log` |
| Collector/Owner Commit/Refresh/stale-tab flow | PASS: 46 fixture requests | `sync_browser.log` |
| Scoped profile/statistics browser flow | PASS: 10 profile requests, including 390px viewport | `profile_browser.log` |
| Private image upload against local Workerd | PASS: 12 CORS preflights, 9 upload attempts | `image_ingestion_browser.log` |
| Actual tab closure, offline denial and reconnect recovery | PASS for the narrower auth-gated policy; new offline tab cannot resume editing | `tab-close.log` |
| Actual service-worker offline reload/rollback | PASS | `static-shell.log` |
| Worker/Canvas image normalization | PASS: 120 images, 647 main-thread responsiveness ticks | `image-preparation.log` |
| Legacy preparation fixture | PASS: deterministic normalized objects, source preservation, cancellation | `legacy-preparation.log` |

The service-worker harness restores the public shell after an actual offline
reload and deep-link navigation. Private API, bearer-authorized and query-string
responses never enter its cache. Disabling the API in the served replacement
release unregisters the owned worker and clears its static cache.

The IndexedDB suite passes with
`CHROME_EXECUTABLE=/home/saoudi26/.cache/ms-playwright/chromium-1254/chrome-linux64/chrome`.
The initial Google Chrome 155 Flutter test attempt remained at loading and was
cancelled after about two minutes; it produced no assertion results
(`indexeddb-google-chrome-loading.log`). The bounded Chromium retry completed all
10 tests. Google Chrome still passed the independent release-preview smoke at
1440 × 900 desktop and 360 × 740 touch viewports. The real IndexedDB suite checks
reopening durable drafts, namespace isolation, revocation, concurrent-tab CAS,
transaction-abort quota recovery, future/corrupt schemas, actual database deletion
and detach/blocked-upgrade handling.

Image tests generate local JPEG/PNG/WebP fixtures and reject corruption, oversized
inputs and unsupported capabilities; they perform no public publication. The
legacy-preparation check uses a tiny cleared fixture, not the quarantined legacy
asset inventory.

The unmodified broad dataset harness passed its initial T28 lifecycle and T29
Topic/classification stages, then failed waiting 30 seconds for **Conflict —
review before queueing** after refreshing an Owner's stale Pack edit. The fixture
handles `/studio/v1/sync/initial` but does not implement the current incremental
`/studio/v1/sync/changes` endpoint; its log records three HTTP 404 console errors.
The displayed workspace retained a last-complete-sync timestamp and reported that
the saved dataset/drafts had not been replaced. This is a failing gate harness,
not evidence that the expected conflict UI passed. Subsequent assertions in that
script (remaining T30/T31/T32 paths) were not executed. No product or fixture
rewrite was made to suppress this failure.

The separate current sync harness implements incremental feeds and passes all
three roles' offline edit → explicit Commit → manual unchanged Refresh. It checks
zero offline writes, empty unchanged feeds, local IndexedDB CAS between stale
tabs, remote revision 412 without overwrite, preserved conflict text and revoked
Refresh without additional private reads. That focused pass does not erase the
broad-harness failure.

The profile harness checks explicit backend refresh, Collector activity isolation,
Owner roster/filter/pagination, downgrade/revocation cleanup and narrow layout.
The ingestion harness exercises actual cross-origin preflights and production
Worker verification using ephemeral signed fixture identities: normalized image
upload, durable receipt/reload, duplicate/lost-response recovery, hash/corruption,
foreign-Pack/Collector IDOR, unauthorized origin/authentication denial, unpublished
privacy and explicit revision-checked Card attachment retaining its ID.

## Privacy, persistence and operational limits

The full Dart suite covers two Collector namespaces and Owner, account/role changes,
late responses after account detach, explicit Commit/Refresh, stale revisions and
idempotency conflicts, bulk authoring authorization, upload receipt validation,
publication review, and backend-derived profile statistics. Relevant portable
sources include `studio/test/dataset_controller_test.dart`,
`dataset_store_test.dart`, `image_ingestion_controller_test.dart`,
`bulk_card_import_controller_test.dart`, `publication_review_test.dart` and
`profile_controller_test.dart`. Passing widget/controller tests do not establish
live Firebase role revocation or deployed backend authorization.

No browser can recover drafts after the user or browser evicts their only local
copy. Cleared/corrupt site data must fail closed, require online authorization and
a new complete dataset, and must not expose a previous account's records. Offline
revocation cannot be learned until reconnect; reconnect must authorize before
fetching/rendering new private data.

The supplemental tracked harness
[`evidence/T46/studio-tab-close.cjs`](evidence/T46/studio-tab-close.cjs) closes the
actual tab after saving/queueing an offline draft. A newly opened offline tab,
even with synthetic restored identity, displays the unavailable-workspace gate
and cannot resume editing. `OfflineAccessPolicy` deliberately requires a
same-tab readiness marker in sessionStorage; closure loses that marker. After
reconnect and fresh authorization, the original IndexedDB draft and unsent queue
reappear with no POST. This verifies auth-gated draft retention/recovery, **not
general offline recovery after tab closure**. Same-tab offline reload is covered
by the earlier broad lifecycle assertions and static-shell harness. Live Firebase
identity restoration remains unverified. Reproduce from repository root after
building the fixture:

```sh
NODE_PATH=/tmp/biguess-t36-browser/node_modules \
CHROME_EXECUTABLE=/usr/bin/google-chrome \
node docs/migration/evidence/T46/studio-tab-close.cjs
```

Earlier supplemental attempts had incorrect assumptions: an identity-bearing
offline query URL is intentionally excluded from static caching, and restoring
identity alone does not preserve a new tab's readiness marker. Their diagnostics
are retained as `tab-close-query-denied.log` and
`tab-close-offline-readiness-denied.log`; the final tracked harness asserts the
documented restrictions and the subsequent reconnect recovery.

Chrome 155.0.8059.84 and Playwright Chromium are available. Firefox and WebKit
executables are absent; Safari/iOS/Firefox/Edge engine-specific behavior is
UNVERIFIED. `studio/README.md` explicitly says other engines need live validation.
Missing-API simulations do not certify them. A narrow Chromium viewport verifies
responsive layout/touch semantics, not a physical mobile browser.

Live production DNS/HTTPS, Firebase popup and deployment results are recorded
separately in [deployment evidence](T46-DEPLOYMENT-EVIDENCE.md). Physical Android
BiGuess Mobile is outside these Web checks. T46 remains NOT PASSED until its
required unavailable/failed checks are resolved.

## Evidence fingerprints

Logs are local artifacts; commands and tracked source above are portable.

```text
552321930bed47111d36ee2cd602c3ccec904a804549269e9fbfa2073d3fff1e  all.log
152a6005a8d02167a5d5f1c5aa68eaa99114c88d53b2803a2b1daec91b978b6c  packaging-tests.log
45ca71ea9a6a43517c68118b642ba00e9ccae98bbdb418f530d7be8432a2be9e  preview-desktop-mobile.log
3c2086e0ca816b39f9fa46ee1e3184951769cd22d29e784676cdb7130a72a978  indexeddb-chrome.log
8b4a12dc911539e23b69e93a13feaf5b5305352594a1bec954b75bb7405a5b22  dataset-build.log
af17af98313c46da4d65b0b0dcb70c8f83df1f3777c2eeb5dbbc7f5ba05146d4  static-shell.log
ff6bd75ee6e002981d3999f4716be7169f8b853bb8f9795dd8e2acd2e6a0acf9  image-preparation.log
7c9d79c73443fe0cbee12d8d90c258b19cb61b662a8f33ddda3e171b4bc13fd8  legacy-preparation.log
6d298dea29338ed44061fda1507ae07d139e89e808ae1b2c8c7156c8095f7e6e  dataset_browser.log
69080ebda5cab844e35e1f9e9ab590ca000bc815f6e93967d660ef5faf44e1de  sync_browser.log
abbdc6ad470aa3b2f1cd66a5264f763627568298d87aba45dfcf5016d2203828  profile_browser.log
246f1e86fe39c1efba10d8d441995fff5fadf887ef82c414687a67af423e473f  image_ingestion_browser.log
9c7f22a2f87da0ecdc6bc92251dc3d4f2be8361c40ee1e1982d94938cc6d9fbd  tab-close.log
```
