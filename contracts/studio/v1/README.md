# T27A: contributor scope and administrative reads

Date: 2026-11-09. Status: **approved by the user; T27A complete**.
This is an additive Studio contract decision, not an implemented API or a
deployment approval. T27B implementation remains a separate task.

Reviewed against `backend/content-api/src/{index,studio-auth,studio-mutations,
studio-cors,publication}.ts`, migrations 0004/0005, the frozen
[content contract](../../content/v1/README.md#studio-mutations-concurrency-and-authorization),
[approved role decisions](../../../docs/migration/DECISIONS.md#3-decision-2--studio-roles-permissions--deletion-hierarchy),
and TODO T27A/T27B. Current reads other than session return 501. Current
mutations authorize roles but do **not** enforce contributor ownership.

## Ownership and visibility decisions

- A new Pack belongs permanently to its verified Firebase creator UID, including
  Packs created by an Owner. Email, JWT custom role claims, request owner fields,
  and the latest editor never establish ownership. The Worker rechecks its
  server allowlist for every request. Owner can administer every Pack.
- A Collector can read/edit only Packs whose creator UID equals their current
  verified UID. Cards inherit access from the stored parent Pack, regardless of
  who created/edited the Card. No Card move, Pack transfer, collaborator list,
  shared editing, or Owner assignment to another UID exists in MVP.
- Owner editing a Collector's Pack preserves its ownership. Creator attribution
  on each Card identifies its actual creator but never overrides Pack scope.
  Attribution and append-only audit actors remain immutable through hide,
  deletion, restoration, purge and role changes. UID retirement grants nobody
  else access; changed email requires allowlist maintenance, not transfer.
- All pre-migration entities are unassigned, even if audit history appears to
  suggest an author. No historical inference/backfill grants Collector access.
  Legacy and missing/corrupt attribution fail closed to Owner-only access.
- Collectors receive a shared minimal taxonomy of all nondeleted Topics,
  including hidden Topics available for classification: `id`, `name`, `state`,
  `revision` only. No author, counts, contributor lists, child IDs or audit.
  Hidden taxonomy is an explicit administrative grant, not public discovery.
  Deleted/purged Topics are absent from taxonomy and new Pack parent choices.
- Collector normal lists omit deleted/purged Packs/Cards and Cards under a
  deleted/purged Pack. Hidden content remains editable within scope. Owned
  deletion is delivered only as minimal removal records during sync. Owner can
  explicitly inspect all lifecycle states and historical attribution/audit.
- Only Owner can delete, restore or purge anything, manage Topics/users or
  initially publish. Existing T24 lifecycle rules remain: cascade soft deletion,
  selected-only restore into hidden state, nondeleted parent required, children
  purged before parent purge, no ID reuse or automatic republication. Restored
  Packs retain their original creator; restored Cards inherit that same Pack.

## Additive D1 plan (T27B only)

Create a new numbered local migration after 0005; never edit 0001–0005 or apply
remote SQL as part of this gate. Keep `studio_entities`' six columns intact:
T24 uses positional INSERTs. Add these separate tables:

| Table | Columns / constraints | Purpose |
| --- | --- | --- |
| `studio_creators` | `(resource_type, resource_id)` primary key; `created_by_uid` nullable; `created_at` nullable UTC; `source` constrained to `legacy` or `authenticated` | Immutable per-entity attribution. Authenticated rows require nonempty UID and timestamp; legacy rows require both null. Pack rows are ownership authority. |
| `studio_read_changes` | `sequence INTEGER PRIMARY KEY AUTOINCREMENT`; `generation`; `resource_type`; `resource_id`; `pack_id` nullable only for Topics; `pack_creator_uid` nullable; `kind` = `upsert` or `remove`; `projection_json` valid JSON | Append-only administrative change projections, independent of public Pack deltas. Never expose internal sequence gaps or actor metadata to Collectors. |
| `studio_pack_images` | `(pack_id, object_reference)` primary key; `established_by_uid` nullable only for trusted legacy fixtures; `created_at` UTC | Trusted object-to-Pack grants checked before Card attachment or future image delivery. R2 object existence alone grants nothing. |
| `studio_scope_versions` | `scope_key TEXT PRIMARY KEY`; `version INTEGER NOT NULL`, monotonically increasing safe integer | Separate Owner-global, shared-taxonomy and per-creator view versions; Collector page validity cannot reveal foreign-only writes. |

Use resource type CHECKs matching existing entities and prohibit creator row
UPDATE/DELETE with triggers. New entity + creator insert must share the guarded
T24 transaction; abort missing/wrong parent/type attribution. Backfill every
existing fence (including purged) with `legacy` null attribution; do not modify
old audit or tombstones. A missing attribution row never means public access.
No foreign key to a user account that could cascade-delete creator evidence.

Indexes: creators `(resource_type, created_by_uid, resource_id)`; existing
`studio_parent` handles Cards; changes `(pack_creator_uid, sequence)` and
`(resource_type, sequence)`, plus `(generation, sequence)`. Owner reads use the
existing entity primary key. Join Cards through their stored Pack before LIMIT,
search, counts or serialization. Never paginate globally and filter in Dart.
Image binding uses its composite primary key; retain bindings through lifecycle
changes. Only trusted ingestion may insert bindings until a separately authorized
upload workflow exists; request JSON never grants a binding. Shared physical R2
bytes may have separate explicit bindings, never implicit cross-Pack authority.

Each administrative writer inserts its projected changes in the same transaction
as entity/revision/audit/tombstone/idempotency updates, under `studio_generation`.
It advances the Owner-global view version, affected Pack creators' view versions,
and taxonomy version only if the shared taxonomy changes. Legacy writes affect
Owner only. Collector pages bind taxonomy + own UID view versions; Owner pages
bind the Owner-global version. Scope keys are server-derived, never request input.
Publication/import writers must participate if they change any administrative
projection, using the existing generation guard. One transaction may emit many
events (Topic cascade emits each affected Pack/Card removal); they share one
generation and commit atomically. Backfill emits no fake change history: persist
a bootstrap generation/watermark; older cursors require initial sync.

Initial retention is indefinite, matching retained identity evidence; no pruning
job in T27B. Future retention must advance a stored minimum resume watermark and
return `409 cursor_expired` for older cursors, never silently skip changes.
Migration tracking makes retry safe after success; transactional failure rolls
back the entire migration. T27B must prove this using old database fixtures,
including missing/legacy/purged entities, and compare old tables before/after.

## Versioned administrative API

Canonical base: `/studio/v1`. New read envelopes have `protocolVersion: 1` and
`scopeVersion: 1`; this contract directory is separate from frozen content v1.
Keep existing `/content/v1/studio/*` aliases routed through identical guards for
existing session/mutations; new read endpoints are canonical-only (aliases return
404). Never fall through to public catalog routing. Public `/content/v1` catalog,
download, revision and delta schemas/semantics stay unchanged. Public catalog is
not an authoring dataset, even when a Collector's Pack is publicly published.

Every route below requires verified Google identity, live server allowlist and
exact-origin Studio CORS. Responses/errors, including images, use
`Cache-Control: no-store`, `Vary: Origin`, and no shared/CDN caching or 304.
No browser credentials or wildcard origins. Nonbrowser callers still need auth.

| Route | Result and scope |
| --- | --- |
| `GET /session` | Existing UID/email/role shape unchanged; no dataset. |
| `GET /topics` | Paged minimal taxonomy for Collector; full administrative Topic rows for Owner. |
| `GET /topics/{id}` | Same projection rules; Collector deleted/missing Topic returns 404. |
| `GET /packs` | Paged authorized Packs; optional `topicId`, `q`, `state`. |
| `GET /packs/{id}` | One scoped Pack. |
| `GET /packs/{id}/cards` | Paged Cards within the scoped stored Pack; optional `q`, `state`. |
| `GET /cards/{id}` | Resolve stored parent then authorize; payload `packId` cannot override it. |
| `GET /sync/initial` | Paged taxonomy + authorized Pack/Card projections, staging one dataset. |
| `GET /sync/changes?cursor=...` | Paged scoped upserts/removals after an initial or completed change watermark. |
| `GET /audit?packId=...` | Owner-only paged audit, including descendants; Collector always 403. |

`q` is a trimmed case-insensitive name substring, maximum 100 characters;
unknown/duplicate query keys, invalid IDs/states/limits return 400. Default
limit 50, integer 1–100. `state` is one of active/hidden/deleted/purged;
Collector requesting deleted/purged returns 403 before looking up any ID.
Default Owner lists include active/hidden; lifecycle states require an explicit
filter. Initial Owner sync includes all states. Collector search/totals/facets
never include other creators; MVP returns no totals/facets at all.

Detail envelope: `{protocolVersion:1, scopeVersion:1, item:Record}`. Page:
`{protocolVersion:1, scopeVersion:1, items:[Record], nextCursor:string|null}`.
Record is discriminated by `resourceType`. Topic taxonomy has the four fields
above plus `resourceType`. Pack has `id, topicId, name, state, revision`;
Card has `id, packId, name, imageReference, difficulty, state, revision`.
Each also has `resourceType`; Owner projections additionally contain
`createdByUid, createdAt` (nullable for legacy). Collector projections do not.
Owner deleted rows retain product fields until purge; purged rows carry only
`resourceType,id,state,revision` plus attribution, with parent linkage where
applicable. No result includes tokens, raw commits, internal R2 keys or other
accounts' audit. `imageReference` is an opaque administrative image identifier,
not a public URL or download capability. Future private-image lookup/preview,
upload/reservation/finalization must check the stored Pack owner and object-to-
Pack binding on every request; no raw hash guessing or cross-Pack attachment.
T27B must scope existing Card image references too; operator fixtures require
explicit trusted bindings. Image routes stay disabled until separately built.

### Paging and sync consistency

Collection and initial pages sort by `(resourceType order topic/pack/card,
UTF-8 ID bytes)` (single-kind collections by ID), not localized labels. Use a
transactional read of generation + scoped view versions + rows + high watermark.
Continuations bind the exact authorized view versions: an intervening write to
that view causes 409 `cursor_expired`; restart the staged scan. A foreign-only
write must not invalidate a Collector's cursor or reveal foreign activity.
The internal global generation still guards T24 writes. This deliberately trades
availability under concurrent edits for no torn snapshot. No long-lived remote
transaction or browser-side filtering is assumed.

Initial envelope extends Page with `resumeCursor: string|null`, null until the
last page. The last page returns the feed cursor at its snapshot high watermark.
Client atomically promotes staging only after all pages succeed; retries of the
same cursor at unchanged view versions return identical data. Never advance a
checkpoint on partial response/failure.

Changes envelope has `protocolVersion,scopeVersion,items,nextCursor,resumeCursor`.
Items are `{kind:"upsert", record:Record}` or
`{kind:"remove", resourceType, id, revision}`. Deletion/removal never carries
name, image, creator, audit or R2 information. Events are ordered by internal
sequence but sequence/generation values are not serialized. Each cursor scan
freezes a high watermark; upsert projections are stored at commit time so later
edits cannot change earlier pages. `nextCursor` continues to that watermark;
only the last page supplies `resumeCursor`. A removal or role change never
reintroduces content through old pages: reauthorize every page, filter event
ownership before paging, and current deleted ancestors suppress historical
upserts (emit minimal removal with the current deletion revision instead).
Repeated removals are harmless.
Topic removal goes to all authorized clients because taxonomy was shared;
Pack/Card removals go only to their immutable Pack creator and Owner.

Opaque authenticated cursors use server-authenticated encryption or random
server-stored handles; signed plaintext containing global sequence numbers is
insufficient because gaps reveal other contributors' activity. Maximum 15-minute
continuation lifetime. A completed resume cursor remains usable while its history
is retained. Bind project, UID, current role, scopeVersion, a hash of current
server allowlist entry, endpoint, filters, limit, position and snapshot/watermark.
Cursor payloads contain no private data and are not authorization credentials.
Cross-account/role/filter/endpoint replay, malformed/tampered/expired cursors,
unknown future watermarks and unavailable history return generic
409 `cursor_expired`, no rows. Reauthentication happens first, so revoked users
receive 403 and expired tokens 401 regardless of cursor. Client reinitializes
after a scope change; never reuse an Owner cache when downgraded to Collector.

### Error and retry boundary

Use the existing content error envelope (`code,message,requestId,retryable,
currentRevision`), extending no public enum. Invalid/missing/expired identity is
401 `unauthenticated`; valid but unallowlisted, disallowed origin or forbidden
operation is 403 `forbidden`. An object-scoped read/write outside Collector
ownership, absent ID, hidden-by-deletion or unknown private image binding yields
indistinguishable 404 `not_found`, `currentRevision:null`. No existence probe,
parent name, ETag, foreign revision, conflict body or collision detail may escape.
Role-forbidden operations (delete/restore/purge/publish/Topic write/audit/users)
return 403 before entity lookup. Owner retains existing 410 purged/deleted and
412 revision responses; in-scope Collector deleted detail returns 404.

Fresh create ID collision with a foreign/legacy identity returns generic 404;
an authorized existing ID keeps T24's precondition/validation behavior. Validate
structure first, then scope before revision/conflict/image checks. Invalid
protected creator/actor fields remain 422, never ignored. No failed write changes
entities, generations, commits, audit, change log, tombstones or public state.
503 `auth_unavailable`/storage errors expose no partial dataset and are retryable;
retry read cursors unchanged with bounded backoff, restart only on cursor_expired.
Keep T24 428/400/422/412/409 behavior after authorization. Offline first login
cannot authorize. Reconnect requires fresh session validation before sync.

## T24 enforcement review / T27B operation checklist

| Surface | Required scope check / preserved invariant |
| --- | --- |
| Pack create, optional Card creates in either order | Validate nondeleted taxonomy parent; assign Pack and each actual entity creator from principal in the same guarded transaction. Reject client creator/owner/actor fields. |
| Pack update/hide; Card create/update/hide/activate | Authorize stored Pack creator for Collector; resolve every existing Card's stored parent; validate object-to-Pack image binding. Check every operation before any write. |
| Topic create/update/hide; initial publish; users/audit | Owner-only. Owner publish remains 501 until publishing workflow; no authority to publish draft bytes is added. Card publish/Pack activate remain invalid per T24. |
| Any softDelete/restore/permanentDelete; Topic cascades | Owner-only; preserve creator rows and scoped descendant change/removal events, T24 audit/tombstones and revision ordering. |
| Batch aggregate; collection POST; item PATCH/DELETE/action POST | Same guard on canonical and existing alias routes. Body aggregate, route ID and operation IDs must agree; mixed/cross-aggregate batch fails atomically. |
| Idempotency replay, including create and purged result | Revalidate live role **and current immutable Pack scope before returning saved result or fingerprint conflict**. A successful create retry uses its now-persisted creator record; do not mistake it for a fresh collision. Owner may replay an old own commit after purge; downgraded former Owner cannot replay a foreign commit. |
| Revision errors and concurrent commit recovery | Check scope before exposing currentRevision or retry results. Preserve actor-key canonical fingerprint, identical retry original result before stale If-Match, changed request 409, aggregate revision +1 once, and generation guard. Reread/recheck scope on conflict/retry paths. |
| Trusted publication/import, future images | Preserve creator authority, participate in generation/change capture, no browser bypass or inferred legacy ownership. Every image action resolves stored Pack binding before R2 access. |

Do not change StudioBatch/StudioResult fields or precondition syntax. T24's retry
closure currently precedes entity reads and is called again after transaction
failure: **both calls need scope validation**, including parent resolution for
Card-only commits. New scope lookup + validation reads must share the generation
snapshot for writes. Missing attribution refuses Collector writes; never create
an attribution record opportunistically while editing legacy data.

## Account caches and approval gate

T28 storage keys must include Firebase project, UID, role/scope identity and
contract version. Keep authorized data/staging/queries/pending drafts separate
per account; logout/switch/denial clears rendered data, memory queries and open
handles immediately. Cancel in-flight work and reject late previous-session
responses. A downgraded role invalidates its old dataset. Persist neither bearer
tokens nor server authorization in content caches; no service-worker/shared HTTP
cache of private responses. Offline cached access requires a previously online-
authorized account and T28's explicit policy, never a new offline login. Remote
revocation cannot be detected while fully offline; reconnect must validate before
displaying/synchronizing that account. T27A implements no browser persistence.

[fixtures.json](fixtures.json) contains the normative two-Collector/Owner/legacy
acceptance vectors. They describe **target behavior**, not passing Worker tests.
Vectors with `setup` describe scenario recipes (for example, a previously saved
commit or a concurrent deletion); their runner must construct valid T24 bodies
and lifecycle states before making the described request. They are not HTTP
recordings. The fixture tests check completeness, referential consistency and
non-disclosure of expected projections. T27B must run these cases against real Workerd/D1,
signed JWTs and R2, including no-write assertions and interleaved transactions.

Technical review: checked role/deletion matrix, positional SQL compatibility,
both T24 retry calls, generation/publication guards and namespace isolation.
No existing completed-ticket text, public contract, backend source or applied
migration is changed here. On 2026-11-09 the user explicitly replied **“approve”**
to the document and 121 acceptance vectors proposed in commit `566cf3d`.
This records the required contract approval and completes T27A. The specified
local T27B implementation starts only when T27B is requested; production
backend/data rollout retains its separate gate.

Verification (2026-11-09): 249 root Flutter tests, root analysis, setup validation
(962 checks) and 162 tooling tests pass, including four target-vector integrity
tests over 121 scenarios. Logs: `/tmp/biguess-t27a-checks/` on the verification
host. No Studio application or Worker code changed, and these checks do not prove
the proposed ownership enforcement against D1. That proof belongs to T27B.
