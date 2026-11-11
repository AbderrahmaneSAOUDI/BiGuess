# T38 gate — private Owner-controlled legacy drafts

All **1,174** original sources reconcile without deviations: **922 Anime** images
in six Packs and **252 Flags** images in one Pack. The existing T05 inventory's
four separately cleared Shapes fixtures are excluded. No source file, filename,
case, Unicode label, bundled manifest or Flutter asset registration was changed.

The T32 browser worker prepared every source sequentially in Chromium. Its source
hash is recorded with the import, and the backend independently decodes/hashes
prepared bytes. There is no Python/native transformation or newly duplicated
legacy image in Studio assets/build output. Normalization produced **1,170**
content-addressed private objects; identical images share bytes but retain their
individual Card identities. Worker filename suggestions do not rename Cards.

The import preserves the **T06 runtime IDs** verified against the live Dart
`LegacyManifestContentRepository` for every Topic/Pack/Card. Each Card also retains
its T05 proposed UUID, source path/hash/size, exact provenance and rights flags,
and normalized image hash/size. Original Easy difficulty is preserved. The
[full manifest](evidence/t38-legacy-import/manifest.json) includes all mappings.

Import identity (SHA-256 of the canonical manifest core):

`778a352a5deddd8ded16932d341f18152a3dc2ec767ac19ee9b584b6a91d22c1`

## Quarantine and scope

The persistent local D1 store contains **1,183 hidden entities**: two Topics,
seven Packs, and 1,174 Cards. Their immutable creator scope is `source='legacy'`
with null UID/date, which T27B treats as Owner-admin-only. This is administrative
Owner control, not assignment to any Collector or invented contribution credit.
No `studio_audit` contribution rows are synthesized.

Owner's complete paginated initial read returned all imported entities. Both
isolated Collectors returned zero records, zero change-feed items, zero activity
and zero contribution counts. Guessed imported Topic/Pack IDs were denied, and
focused backend tests also verify guessed Cards and attempted Pack creation under
an imported Topic. Imported Topic changes do not leak into Collector taxonomy or
invalidate their cursors. Owner-created descendants of quarantined Topics/Packs
remain excluded after a role downgrade, including historical feed rows; unrelated
Topics that share a Pack ID remain visible.

All source rights remain unverified/quarantined with publication flags false.
Quarantine markers are immutable. Owner review reports the quarantine; generic
rights approval and signed publication cannot bypass it. Final SQL guards fence
catalog publication, rights approvals and publication insertion. No T38 clearance
or ownership-transfer path is implemented. Independently cleared fixtures still
pass the existing test-publication path.

The actual full import left zero rows in catalog Topics/Packs, publication
heads/revisions, rights/publication approvals, release requests and contribution
audit. Anonymous catalog discovery returned no imported records, and each Pack's
exact download/manifest endpoints returned 404. Focused tests also exercise exact
signed manifest/archive/object URLs. No production publishing, deployment or
remote migration occurred.

## Reproduction and rollback

Use the [local operator runbook](../../backend/content-api/LEGACY-IMPORT.md).
The runner has no cloud URL or publish mode; its internal Miniflare harness is
not a production route and rejects non-local environments. All derived images,
worker artifacts and persistent state stay in a dedicated directory outside the
repository. Reports/manifests here contain metadata only, with no image bytes,
tokens or private keys.

Repeated full preparation generated the identical manifest and import identity.
Fresh-process replay verifies durable D1/R2 state and returns the recorded import;
ID collisions or changed manifests cannot silently overwrite data. Replay also
verifies every stored image hash, size and media type; missing/corrupt/mislabeled
R2 objects fail closed without repair. Initial
[import evidence](evidence/t38-legacy-import/import-report.json),
[repeat evidence](evidence/t38-legacy-import/repeat-report.json) and
[reproducibility checks](evidence/t38-legacy-import/reproducibility.json) are retained.

A filesystem copy was made after the primary runtime closed. On that copy, safe
rollback atomically changed only the 1,183 imported entities to deleted revision 2
and added 1,183 tombstones. Repeated rollback returned the same receipt. All 1,174
original files, 1,170 private objects, 1,183 provenance records, immutable import
evidence and ID fences remained. The primary dataset remains quarantined/hidden.
See the [rollback report](evidence/t38-legacy-import/rollback-report.json) and
[subsequent full object-checksum verification](evidence/t38-legacy-import/rollback-verification.json).

Rollback refuses edited records, external children and review/publication side
effects. It never silently resurrects a rolled-back import or deletes source
files/private evidence. Clearance and any future ownership migration remain
separate reviewed work.

## Verification commands

```sh
node --test scripts/legacy_import_plan.test.mjs
NODE_PATH=/path/to/playwright/node_modules CHROME_EXECUTABLE=/usr/bin/google-chrome \
  node studio/scripts/legacy_preparation_test.cjs
flutter test
flutter analyze
(cd studio && flutter test && flutter analyze)
python3 .agents/scripts/validate_setup.py
python3 -m unittest discover -s .agents/tests -v
(cd backend/content-api && npm run typecheck && npm test)
```

Local-only Workerd/D1/R2 tests use synthetic signed Firebase identities. Browser
preparation uses the actual unchanged T32 worker. Neither proof requires a live
Firebase account, cloud bucket or deployed backend.

## Results in this checkout (2026-11-11)

- Source gate: all 1,174 source hashes matched T05 before and after preparation,
  import, restarted replay and cloned rollback; no deviations.
- Real T32 Chromium preparation: all 1,174 sources; 1,170 normalized objects.
  Smoke checks passed for repeatability, duplicate preservation, cancellation,
  source checksum rejection and private-output boundaries.
- Plan/operator preflight: seven Node tests passed, including unsafe output
  links/markers and preservation of unrelated files.
- Mobile: 250 tests passed, including exhaustive live T06 mapping comparison and
  the offline gameplay gate; analyzer clean.
- Studio: 288 tests passed; analyzer clean.
- Backend: typecheck/build passed; all 232 Worker/D1/R2 tests passed, including
  eight focused legacy quarantine/rollback tests and cleared-fixture publication.
- Agent setup: 962 checks passed; 163 automation tests passed.
- Full import, fresh-process replay and cloned rollback passed; the primary
  persistent dataset remains hidden/quarantined. Local working state is in
  `/tmp/biguess-t38-persistent-import`, with the independent rollback proof in
  `/tmp/biguess-t38-persistent-rollback-proof`. These external paths are temporary
  local artifacts; the committed manifest/reports permit reconstruction.

During runner verification, a cloned rollback exposed that Miniflare 5 ignores
older `d1Persist`/`r2Persist` options. The final runner uses
`resourcePersistencePath`, asserts persistence creation, checks durable evidence
on subsequent processes, and was rerun from a clean store. The final reports here
come from that persisted run and independently copied rollback store.
