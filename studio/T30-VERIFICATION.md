# T30 Pack administration verification — 2026-11-10

[Implementation and policy](README.md#contributor-pack-administration-t30).

My Packs works on the existing scoped browser dataset and IndexedDB pending
operations. Save and Queue commit are separate explicit actions. No mutation
transport, Content Backend deployment, API activation or Mobile gameplay change
is introduced. The production identity/Worker connection remains separately gated.

## Check results

| Check | Result | Log |
| --- | --- | --- |
| Studio format/analyze/test/release build/boundary | PASS: 147 tests | `/tmp/t30-studio.log` |
| Worker typecheck and Workerd/D1 suite | PASS: 191 tests, no failures/skips | `/tmp/t30-backend-typecheck.log`, `/tmp/t30-backend.log` |
| Root `flutter test` | PASS: 249 tests, including offline gate | `/tmp/t30-mobile-test.log` |
| Root `flutter analyze` | PASS: no issues | `/tmp/t30-mobile-analyze.log` |
| Agent setup validator | PASS: 962 checks | `/tmp/t30-setup.log` |
| Agent Python suite | PASS: 162 tests | `/tmp/t30-agents.log` |
| Static packaging tests | PASS: 8 tests | `/tmp/t30-packaging.log` |
| Static shell Chromium flow | PASS | `/tmp/t30-shell-browser.log` |
| Chromium IndexedDB store suite | PASS: 10 tests | `/tmp/t30-store-browser.log` |
| Packaged T28/T29/T30 Chromium flow | PASS: 61 private GETs, zero uploads/runtime errors | `/tmp/t30-dataset-browser-final.log` |

## Acceptance evidence

Controller tests exercise scoped Pack creation/edit/hide, immutable synchronized
Topic relationships, valid hidden taxonomy, missing/deleted/pending parents,
Owner soft deletion/restoration/permanent deletion, stale revisions, conflicting
operations and dependent Card drafts. Collector destructive operations are
rejected by controller entry points and when queueing injected drafts. Old T28
full-record name drafts remain usable; readonly fields must match synchronized
data and are stripped from queued payloads. Forged IDs, creators and unknown
metadata are rejected. No creator UID is accepted as an editable product field.

Widget tests cover Owner attribution/global and unassigned legacy views,
Collector controls, local search/status filtering, keyboard Enter submission,
explicit saves/queueing, cancellation and confirmation for each Owner lifecycle
action, quota text retention, account-loss cleanup, 360-pixel layouts and
200-percent text. The packaged Chromium flow exercises the production
session/controller/IndexedDB/UI with synthetic identity and a local HTTP fixture,
including two isolated Collectors, Owner global/legacy view, stale-edit conflict,
valid independent classification, destructive cancellation/confirmation, queued
hide surviving reload, offline edit/reload and denied reconnect. It asserts zero
mutation HTTP requests and no cross-Collector responses or private static cache.

The Workerd/D1 regressions use the actual server authorization and mutations,
including server-derived UID attribution, two Collectors' read/write fences,
Owner legacy management without claiming ownership, hidden/missing/deleted Topic
associations, stale revisions and immutable parent relationships. Only Owner can
delete/restore/purge, with contained Cards purged before permanent Pack deletion.

## Reproduce browser checks

Use the isolated pinned Playwright tooling in
[T28 verification](T28-VERIFICATION.md#reproduce-browser-checks), then from Studio:

```bash
flutter test --platform chrome test/dataset_store_test.dart
flutter build web --release --no-web-resources-cdn --pwa-strategy=none --target test/browser_dataset_app.dart --output build/dataset-web
node scripts/dataset_browser.cjs
```

The synthetic identity entrypoint is never imported by the production app.
Screenshots: `/tmp/t30-owner-packs.png`.

## Limits

Permanent deletion is a durable pending operation until later upload; it cannot
bypass the Worker's child-first purge rule. Card lifecycle UI remains T31.
Restoration returns only the selected Pack to hidden state; neither Topic nor
Cards are implicitly restored. Empty Packs remain drafts. Eligible-Card counts
are local readiness information and do not claim publication or downloadable
content. Existing offline authorization, storage eviction/quota and account
isolation limits remain as described in T28. No production account or private
remote dataset is used by this verification.
