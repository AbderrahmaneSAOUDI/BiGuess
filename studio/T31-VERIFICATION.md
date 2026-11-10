# T31 Card editor and image review verification — 2026-11-10

[Implementation and policy](README.md#card-editing-and-local-image-review-t31).

This ticket adds local Card authoring/review and browser file selection. No
mutation upload, publishing route, Content Backend deployment, API activation,
production identity bypass or Mobile gameplay change is introduced.

## Check results

| Check | Result | Log |
| --- | --- | --- |
| Studio format/analyze/tests/release build/boundary | PASS: 166 tests | `/tmp/t31-studio.log` |
| Worker typecheck and Workerd/D1 | PASS: 194 tests, zero failures/skips | `/tmp/t31-backend-typecheck.log`, `/tmp/t31-backend.log` |
| Agent setup validator | PASS: 962 checks | `/tmp/t31-setup.log` |
| Agent Python suite | PASS: 162 tests | `/tmp/t31-agents.log` |
| Static packaging tests | PASS: 8 tests | `/tmp/t31-packaging.log` |
| Static shell Chromium | PASS | `/tmp/t31-shell-browser.log` |
| Root Mobile tests | PASS: 249 tests including offline gate | `/tmp/t31-mobile-test.log` |
| Root Mobile analysis | PASS: no issues | `/tmp/t31-mobile-analyze.log` |
| Chromium IndexedDB store suite | PASS: 10 tests | `/tmp/t31-store-browser.log` |
| Packaged T28/T29/T30/T31 Chromium | PASS: 82 private GETs, zero uploads/runtime errors | `/tmp/t31-dataset-browser-pass.log` |

## Acceptance evidence

Controller/model tests cover canonical names/difficulty/image/Pack values,
immutable Card IDs and Pack associations, image replacement, local attachment
serialization and offline reopening, eligible parent guards, stale revisions,
foreign Cards/Packs, direct Collector lifecycle denials and forged queue data.
Old full-record Card name drafts normalize without accepting creator/parent
changes. Pending Card edits cannot coexist with destructive parent operations,
and working Pack counts exclude local-only/replaced/hidden/deleted/conflicting
Cards. Filename suggestions, MIME/signature checks and selection size bounds are
basic guards; full image validation/normalization remains T32.

Ten Card widget tests cover selected-Pack review, explicit canonical-field saves,
filename suggestions preserving entered names, difficulty 1–3, image replacement
retaining identity, failed selection, keyboard Enter, Owner destructive
cancel/confirm flows, conflict controls, quota retention, account-loss cleanup,
360-pixel touch layout and 200-percent text. Private dialogs eagerly capture
the opening scope so later account/role changes clear inputs and close them;
the shared Pack confirmation scope capture follows the same boundary.

Workerd tests exercise the actual server and D1: two isolated Collectors,
foreign reads/writes returning not-found, Pack-inherited ownership, immutable
Card Pack relationships for Owner and Collector, canonical-field rejection,
invalid difficulties, stale edits and Owner-only delete/restore/permanent-delete.
A trusted fixture image binding permits image replacement while retaining Card
ID and attribution; another Pack's or unbound image reference is rejected.
No production image ingestion endpoint is enabled by this ticket.

The packaged browser uses the production controller, UI, storage and transport
with a standalone synthetic-identity entrypoint and local HTTP fixture. It
checks file chooser/preview/name suggestion, difficulty selection, new Card ID
retention through offline image replacement and queue/reload, scoped review,
Owner lifecycle confirmations and denied-reconnect cleanup, while retaining all
T28/T29/T30 browser flows. The fixture is never imported by production `lib/`.

## Reproduce

Install the isolated pinned Playwright tools in
[T28 verification](T28-VERIFICATION.md#reproduce-browser-checks), then from Studio:

```bash
bash scripts/check.sh all
flutter test --platform chrome test/dataset_store_test.dart
flutter build web --release --no-web-resources-cdn --pwa-strategy=none --target test/browser_dataset_app.dart --output build/dataset-web
node scripts/dataset_browser.cjs
```

Run Worker checks from `backend/content-api`: `npm run typecheck` and `npm test`.
Root Mobile/tooling gates remain those in AGENTS.md.

Screenshots: `/tmp/t31-card-preview-desktop.png`,
`/tmp/t31-card-preview-mobile.png`, `/tmp/t31-owner-cards.png`.

The final browser process completed with exit 0. Earlier harness failures from
an unfocused Flutter editing proxy and transient Pack reselection are retained
in `/tmp/t31-dataset-browser.log` and `/tmp/t31-dataset-browser-final.log`; those
attempts are not counted as passes.

## Limits

Raw candidate bytes are browser-local draft attachments, not trusted server
image references. There is no normalization, transcoding, hash/dedup pipeline,
remote preview fetch or authenticated upload in T31. Image preparation/ingestion
remain T32/T32A. Preview failure is displayed without making content playable or
publishable. Queueing does not execute mutations; future transport must ingest
and revalidate images and the current aggregate scope/revisions before upload.
Existing offline identity, storage eviction/quota and account isolation limits
continue to apply. A completed durable save is awaited before reload tests.
