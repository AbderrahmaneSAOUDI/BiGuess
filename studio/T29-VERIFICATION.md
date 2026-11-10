# T29 Topic administration and classification verification — 2026-11-10

[Implementation and policy](README.md#topic-administration-and-classification-t29).
All content changes in this ticket are local drafts and explicitly queued
operations. No mutation upload, Content Backend deployment, API activation,
remote D1/R2 operation, publishing or Mobile gameplay change was performed.
Static frontend releases continue through the existing T26A workflow.

| Check | Result | Evidence |
| --- | --- | --- |
| `bash studio/scripts/check.sh all` | PASS: format, analyzer, 132 tests, release build and boundary | `/tmp/t29-studio.log` |
| Worker `npm run typecheck` and `npm test` | PASS: 189 Workerd/D1 tests, no failures/skips | `/tmp/t29-backend.log` |
| Root `flutter test` | PASS: 249 tests | `/tmp/t29-mobile-test.log` |
| Root `flutter analyze` | PASS: no issues | `/tmp/t29-mobile-analyze.log` |
| Agent setup validator | PASS: 962 checks | `/tmp/t29-setup.log` |
| Agent Python suite | PASS: 162 tests | `/tmp/t29-agents.log` |
| Studio packaging tests | PASS: 8 tests | `/tmp/t29-packaging.log` |
| Real Chromium IndexedDB suite | PASS: 10 tests | `/tmp/t29-store-browser.log` |
| Packaged T28/T29 Chromium flow | PASS: 45 private GETs, zero uploads/runtime errors | `/tmp/t29-dataset-browser.log` |

The 32 focused controller/model tests include the existing account/session
regressions plus Owner create/rename/hide/delete/restore operations, direct
Collector mutation/queue/discard denial, minimal taxonomy projections, invalid
names, immutable synced data, one final pending operation per Topic, stale and
conflicting changes, backward loading of T28 drafts without operation metadata,
new creations surviving refresh, parent disappearance conflicts and independent
Pack draft classification. Forged incoming name-editor records cannot change
stored parents or revisions. Both write orders are checked: a pending Topic
deletion prevents a child draft, and a dependent child draft prevents deletion.

Ten widget tests cover Collector-only readonly taxonomy, local search without
controller writes, Owner controls and destructive confirmations, explicit local
queueing/discard, quota failure retaining text, immediate modal/search cleanup
on account/role loss, picker invalidation, independent Pack classification,
360-pixel layouts and 200% text with long Unicode labels.

The unchanged backend suite verifies actual server role enforcement, including
Collector rejection of Topic management/lifecycle operations and Owner success,
verified-UID ownership, atomic batches, optimistic revisions/idempotency, scoped
reads/sync and anonymous public isolation. Browser controls are not the server
security boundary.

The packaged browser flow uses the production session/controller/IndexedDB/UI
with the standalone synthetic-identity/local-HTTP fixture entrypoint. It proves
Owner search, create, rename, hide, delete cancellation/confirmation, restore,
explicit queueing and reload persistence. It rejects new, pending-deleted and
pending-restored Topics as Pack parents. A Collector gets minimal taxonomy and
no administrative controls, then independently prepares a Pack from My Packs at
360-pixel width using an existing hidden Topic. Its actual persisted create
operation has the selected Topic ID and no creator/owner fields. The queued
state survives reload. Existing T28 offline/reconnect/account-isolation flows
continue passing, and the test checks every Collector response, stored bearer
strings and static-only CacheStorage. Screenshots: `/tmp/t29-topics-owner.png`
and `/tmp/t29-pack-picker-mobile.png`.

Reproduce from `studio/` after installing the pinned Playwright tooling described
in [T28 verification](T28-VERIFICATION.md#reproduce-browser-checks):

```bash
flutter build web --release --no-web-resources-cdn --pwa-strategy=none --target test/browser_dataset_app.dart --output build/dataset-web
node scripts/dataset_browser.cjs
```

The test-only identity entrypoint is never imported by the production app. No
production Firebase account, Worker credentials or real private dataset is used.

## Deliberate scope and limits

- Soft deletion is pending and confirmed. It retains the Topic identity; the
  existing server cascade will delete contained Packs/Cards when a later commit
  is uploaded. Restoration is selected-only into hidden state, never publication
  or automatic child restoration. Permanent purge is not added by this ticket.
- Collector widgets receive only Topic ID/name/state/revision. No creator, audit,
  counts or private child metadata is displayed. Hidden taxonomy is permitted by
  the approved T27B contract; deleted/purged taxonomy is excluded.
- Pack classification uses existing active/hidden Topics. New unsynced Topics,
  pending deletion/restoration and conflicting Topics are unavailable as parents.
  Only unsynced Pack creation drafts can be reclassified here; moving a synced
  Pack remains forbidden. Full Pack administration is T30.
- Drafts carry an operation and original revision. Incompatible edits do not
  silently replace another pending operation. Queueing persists an unsent local
  operation and sends no HTTP mutation; transport/publishing remain later work.
- Old T28 drafts default to `update`. Older app builds may refuse the new optional
  metadata instead of reinterpreting destructive operations; stored drafts are
  retained. Existing account isolation, quota recovery and offline limits apply.
