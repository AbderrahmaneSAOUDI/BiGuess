# T38 — private local legacy import and quarantine

This operator is local-only. It imports existing repository sources into a
persistent, private Miniflare D1/R2 store, not a cloud service. No production API
route invokes it, and both import and rollback reject staging/production envs.
There is no remote URL, Firebase credential, deployment or publishing option.

From the repository root, with backend development dependencies and Playwright
available to Node:

```sh
NODE_PATH=/path/to/playwright/node_modules CHROME_EXECUTABLE=/usr/bin/google-chrome \
  node scripts/import_legacy_content.mjs --output /absolute/private/t38-store
```

The output must be a dedicated directory outside the repository. First use
requires it to be empty; later runs require the exact regular ownership marker.
Linked output descendants are rejected, report replacement is atomic, and the
output directory is restricted to its local owner. The
output includes private normalized objects, manifest, preparation receipts,
import/repeat reports, worker build and persistent `state/`. It contains no
private signing keys or real account tokens. Synthetic Owner/Collector credentials
exist only during local verification. Do not place these artifacts under Studio
assets, build output, a public web server or a public R2 bucket.

The runner verifies all T05 source paths/byte counts/SHA-256 values and reconciles
922 Anime + 252 Flags sources before preparing anything. The four cleared Shapes
fixtures are excluded. Unknown/missing/changed sources and symlinks fail closed.
Original files are read only. The unchanged T32 browser Web Worker runs one image
at a time, with its existing format/decode/dimension/timeout bounds; Python and
native image transformations are not used. Normalized duplicate objects are
shared by content hash, while each source retains its own Card and stable ID.

T06 runtime IDs (`legacy:topic`, `legacy:pack`, `legacy:card`) remain unchanged.
The manifest also retains T05 proposed UUIDs, original paths, provenance, source
and normalized checksums, byte lengths, inventory hash and worker hash. Names
come from the existing bundled adapter; worker filename suggestions do not rename
Cards. Difficulty defaults to Easy, as in T06. Browser encoder output is repeatable
for the recorded toolchain; another browser version may encode different bytes.
Changed manifests cannot overwrite existing imported identities.

Metadata promotion is one generation-guarded D1 transaction. Private R2 objects
are independently decoded and hashed before promotion; an interrupted metadata
commit may leave private unreferenced bytes, but cannot create public metadata.
The immutable import/source ledgers preserve exact evidence. Identical retries
verify persisted image hashes, sizes and media types before returning the
recorded result (missing/corrupt objects fail closed without repair); restart
verification refuses to silently reconstruct
missing database state from an old successful report. Miniflare 5 persistence
uses `resourcePersistencePath`, not the older per-service option names.

Imported entities are hidden with creator `source='legacy'`, null UID/date. That
means Owner-admin control, not attribution to an arbitrary Collector or an Owner's
contribution count. No `studio_audit` contribution credit is synthesized. Private
rights/provenance live outside canonical game Card values.

Quarantine is durable and cannot be cleared by this ticket. Collector taxonomy,
initial/change feeds, detail reads and guessed-parent mutations exclude imported
records. Owner review reports quarantine. Existing approval/publication routes
and final SQL catalog/rights/publication guards reject quarantined content,
including a signed publication bundle claiming rights. Only independently
rights-cleared fixtures retain the existing test-publication path. This import
never adds catalog, publication, approval or release-request records.

## Repeat and rollback

Run the same command again for full source/browser preparation and exact manifest
comparison, then durable idempotent replay. Original import evidence is retained;
the latest repeat report is separate. The operation never silently restores a
rolled-back import or accepts an edited/colliding stable identity.

For a reviewed local rollback:

```sh
node scripts/import_legacy_content.mjs --output /absolute/private/t38-store --rollback
```

Rollback first verifies the immutable manifest, unchanged revision-1 hidden
entities, legacy creator scope, no external dependents and no review/publication
side effects. It then atomically marks only the imported records deleted at
revision 2, records tombstones and an immutable rollback receipt, and emits scoped
changes. It preserves originals, ID fences, import/source evidence and private
image objects. Repeating rollback is idempotent. Edited records or unrelated
children stop automatic rollback instead of being overwritten.

`rollback-report.json` verifies source checksums, provenance, retained private
object keys/checksums/media types, imported revision/state and tombstone counts before returning
success. For acceptance, run rollback on a filesystem copy made **after** the
local runtime has closed, preserving the primary quarantined dataset. Never
copy a live SQLite store.

Applying migration `0010` remotely, deploying backend code, using live accounts,
changing ownership or clearing rights require separately requested work. Removing
quarantine fences/immutable evidence is not a rollback procedure.
