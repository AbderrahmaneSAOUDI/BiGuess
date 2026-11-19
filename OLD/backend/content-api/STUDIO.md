# Administrative mutations, scoped reads and image ingestion (T24, T27B, T32A)

T27B implements the approved [administrative scope contract](../../contracts/studio/v1/README.md).
Apply additive `0006_studio_scope.sql` with `npm run db:migrate` locally after
0001–0005. It leaves the six-column entity table, public artifacts, audit and
tombstones intact. Existing identities, including purged fences, get immutable
unassigned legacy attribution and remain Owner-only. Reapplying 0006 preserves
creator evidence, feed history, view versions and the randomly generated cursor
key. No remote migration or Content Backend deployment is part of this gate.

New Packs belong permanently to the verified creator UID; Cards inherit their
stored Pack's access. Owner can administer all records. Collectors can read,
search, create, edit and hide only their own Packs/Cards, and see the minimal
nondeleted Topic taxonomy. Request creator/owner fields cannot establish scope.
Missing attribution fails closed. Every batch operation and both idempotency
replay paths check current scope before returning revisions or saved results.
Entity, creator, audit, feed, view-version and idempotency writes commit atomically
under the existing generation guard. Trusted publication preserves existing
creators and captures administrative changes in the same transaction.

Canonical authenticated GET routes are `/studio/v1/topics`, `/topics/{id}`,
`/packs`, `/packs/{id}`, `/packs/{id}/cards`, `/cards/{id}`, `/sync/initial`,
`/sync/changes` and Owner-only `/audit?packId=...`. Paths after the first use the
same `/studio/v1` prefix. New reads have no `/content/v1/studio` aliases; existing
session/mutation aliases retain identical authorization. Public anonymous
catalog, downloads and Pack distribution contracts remain separate.

Read envelopes have `protocolVersion:1,scopeVersion:1`. Collections accept
`limit=1..100` (default 50) and opaque `cursor`; Packs also accept `topicId,q,state`
and Pack Cards accept `q,state`. Topic lists accept `state`. Unknown/duplicate
parameters are rejected. Unicode case-insensitive substring search runs over
SQL-authorized rows before paging. This currently scans the account's remaining
matching-kind records in Worker memory; large authoring datasets may require a
persisted folded-name search projection. No other account's rows are loaded.

Initial sync pages taxonomy and authorized content in type/UTF-8-ID order. Stage
pages until the last page supplies `resumeCursor`; promote the dataset atomically
only then. Changes use that cursor with the same limit, return scoped upserts or
minimal removals, and supply a new resume cursor only at the end of a frozen
watermark. Deleted ancestors suppress historical upsert data. History is retained
indefinitely. AES-GCM cursors hide global counters and bind project, UID, live
role/allowlist entry, endpoint, filters and limit. Continuations expire after
15 minutes; completed resume cursors persist while history remains available.
Changes to an initial scan's own view expire it; foreign-only writes do not.
On `409 cursor_expired`, restart initial staging while retaining the last good
local dataset. Reauthenticate on every request, including continuation/replay.
All private responses are `no-store` with exact-origin CORS; they never use 304.

Card reads expose Pack-specific opaque image identifiers, not raw R2 keys or
download capabilities. Card attachment requires a trusted `studio_pack_images`
binding before any R2 read. Operator ingestion or the authenticated T32A pipeline
below establishes those bindings; request JSON cannot. Private image GET routes
remain disabled (404). Browser storage/session isolation remains in T28, and
publishing remains a separate privileged workflow.

See [T32A image ingestion](IMAGE-INGESTION.md) for the binary upload contract,
full server decode, quota reservations, explicit attachment and trusted orphan
cleanup policy. Original T24 did not include uploads; T32A is additive.

The Worker implements the frozen [v1 Studio contract](../../contracts/content/v1/README.md#studio-mutations-concurrency-and-authorization).
Apply `0004_studio.sql` through the existing **local** migration workflow; this
change does not deploy or apply a remote migration.

Send `POST /studio/v1/batches` (alias `/content/v1/studio/batches`) after an explicit
Studio Save/import action, with a Firebase Google ID token, `Idempotency-Key`, and
exactly one revision precondition:

- New Topic/Pack: `If-None-Match: *`, including its create operation.
- Existing Topic/Pack, including Card-only changes: `If-Match: "rev-N"`.

```json
{
  "protocolVersion": 1,
  "aggregate": { "resourceType": "pack", "id": "shapes" },
  "operations": [
    { "resourceType": "pack", "id": "shapes", "action": "create",
      "value": { "name": "Shapes", "topicId": "learning" } }
  ]
}
```

The Topic must already exist. A batch contains 1–100 final operations, unique by
resource type and ID. The body is limited to 256 KiB. A Topic batch touches that
Topic; a Pack batch touches that Pack and its Cards. Pack create and Cards may
appear in either order. Parent deletion/restore/purge must be a separate commit
from explicit child operations. Empty draft Packs are allowed.

`create`/`update` supply all mutable fields: Topic `{name}`, Pack `{name, topicId}`,
Card `{name, packId, imageReference, difficulty}`. Names are trimmed/nonempty,
difficulty is integer 1–3, and extra fields (including actor, role, deletion,
revision or publication state) are rejected. Pack Topic reassignment and
cross-Pack Card moves are rejected; a multi-aggregate move protocol is deferred.
Images reference trusted R2 `objects/<sha256>.<webp|png|jpg>` objects;
the Worker checks existence, byte hash, media type and image format header.
No arbitrary URLs or client-supplied image authority are accepted. T32A stages
prepared images separately and promotes them only for an explicit Commit.

Collectors can create/update/hide Packs and Cards and `activate` hidden Cards.
Topic management and all `softDelete`, `restore`, and `permanentDelete` operations
require Owner Admin. Every operation is authorized before any write, including
operations later in a mixed batch. `publish` is Owner-only but remains 501 until
the separate validated publishing workflow; this API cannot publish draft bytes.

Existing collection POST, item PATCH, item DELETE and item POST action routes
(`hide`, `soft-delete`, `restore`, `permanent-delete`) also accept a **StudioBatch
body containing exactly one matching operation**. They use the same preconditions,
idempotency, validation and transaction path. Card routes still specify their Pack
aggregate. Prefer batches for imports and multi-row saves. Studio content read,
image upload and user-management operations remain outside T24.

Success is a `StudioResult` with authenticated UID `actorId`, server timestamp,
aggregate revision and `ETag: "rev-N"`; all responses are `no-store`. Each commit
advances the Topic or Pack once, including Card-only batches. Missing preconditions
return 428; malformed requests/preconditions return 400; invalid fields,
relationships or state transitions return 422. Stale revisions return 412
`revision_conflict` with `currentRevision`. Reconcile before another explicit save.

Idempotency is scoped to authenticated UID. Canonical body plus preconditions and
the original result are saved atomically. Identical retries return the original
result before checking the now-stale revision; changed requests using the same key
return 409 `idempotency_conflict`. Records are retained indefinitely (at least the
contract's 30-day minimum). Authorization is checked again on retries.

`studio_entities` holds administrative records separately from public immutable
artifacts. The migration fences pre-existing catalog Topic/Pack identities and
revisions; importing their Card authoring data from frozen R2 manifests is not an
SQL migration. Newly created Cards are maintained here. No draft edit rewrites
old manifests, receipts or archives. Pack revision checks and delta distribution are implemented in [T25](SYNC.md);
initial approval and the Studio publishing workflow remain T35.

Soft deletion retains the record and cascades Topic → Packs → Cards. Descendant
Packs receive their own next revision. Every affected entity gets a concise audit
entry (batch, UID, role, resource, action, revision, timestamp) and an append-only
tombstone. Hiding creates no tombstones. Visibility/deletion changes immediately
suppress existing public discovery/new downloads; Card hiding/deletion suppresses
the old Pack projection until a validated replacement can be published. A Card-only
suppression marker lets a valid routine publication resume prior visibility; an
explicit Pack hide/deletion clears that intent. Installed offline gameplay is
independent. [T25 sync endpoints](SYNC.md) transport Pack tombstones and deltas.

Restore requires a nondeleted parent and restores only the selected entity into
hidden state; descendants require explicit restoration. It never republishes
content or removes deletion evidence. Permanent deletion requires prior soft
deletion and purged children. It erases mutable product fields while retaining
identity/revision fences, idempotency results, audit attribution and tombstones.
Historical immutable R2 publications are retained; physical shared-object garbage
collection is a separate retention operation, never a Collector mutation.

Validation reads the aggregate, descendants and parent Topics with a shared D1
mutation generation in one transaction. The write transaction first checks that
generation, then commits records, audit, tombstones, public suppression and
idempotency together. A concurrent administrative change, even to a different
aggregate, may conservatively cause a 412. No partially validated commit or silent
merge is possible. Operator-only publication/import must be coordinated with
administrative writes. T25 trusted publications participate in the same generation
guard; the Studio approval UI/workflow remains a later ticket.

`npm run typecheck` and `npm test` verify the bundled Worker with real signed
Firebase fixtures, D1 transactions and R2 bytes. No production token or cloud
service is required.
