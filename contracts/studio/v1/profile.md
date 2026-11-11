# Studio contributor profile and audit statistics v1 (T37)

`GET /studio/v1/profile` and its authenticated compatibility alias
`GET /content/v1/studio/profile` require the existing verified Firebase identity
and server-managed Studio allowlist. Responses and errors use `Cache-Control:
no-store`; exact-origin Studio CORS applies. There is no anonymous profile route.

## Scope and request

- A Collector receives only that UID's counts and audit activity. The SQL query
  is actor-scoped before rows reach the Worker. `contributors` is empty, and no
  global count, other actor identity, current content value, or raw sequence is
  returned. Any `contributorUid` parameter, including their own UID, returns 403.
- An Owner receives all contributor counts and administrative audit records.
  Optional `contributorUid` selects one actor's counts/activity; it does not grant
  access to a Collector. Historical actors remain selectable after revocation.
- `limit` is an integer 1–100 (default 50). `cursor` continues the same snapshot.
  Duplicate or unknown parameters return 400. Invalid/expired/mismatched cursors
  return 409 `cursor_expired`, instructing an explicit profile refresh.
- Query selection never accepts a role, actor identity, client count, offset,
  content-ownership override or arbitrary SQL field.

## Success envelope

```json
{
  "protocolVersion": 1,
  "scopeVersion": 1,
  "principal": {"uid":"a","email":"a@example.test","role":"collector"},
  "contributorUid": null,
  "counts": {
    "totalOperations": 2,
    "topicsCreated": 0,
    "topicsRemoved": 0,
    "packsCreated": 1,
    "packsRemoved": 0,
    "cardsAdded": 1,
    "cardsRemoved": 0,
    "edits": 0,
    "hides": 0,
    "restores": 0,
    "permanentDeletes": 0,
    "activations": 0
  },
  "contributors": [],
  "activity": [{
    "batchId":"opaque-batch-id",
    "actorId":"a",
    "actorRole":"collector",
    "resourceType":"card",
    "resourceId":"opaque-card-id",
    "action":"create",
    "revision":1,
    "committedAt":"2026-11-11T00:00:00.000Z"
  }],
  "nextCursor": null,
  "asOf":"2026-11-11T00:00:01.000Z"
}
```

`contributorUid` is null for default self-Collector and default all-Owner views;
Owner-selected views echo the selected UID. `principal` always identifies the
requester with the currently verified role, not the selected contributor.

Owner `contributors` entries are `{uid,email,role,counts}`. Every currently
allowlisted UID appears, including zero-operation contributors and the verified
requester. The pinned `STUDIO_SUPER_ADMIN_UID` appears as Owner for project
`biguess-firebase`, using the same built-in email and project guard as
authentication, even when absent from the allowlist. Actors recorded only in historical audit rows have null email/role:
the backend does not invent current identity or authorization from an old action.
`activity.actorRole` is the immutable role **at commit time**, never a current
permission grant. No public contributor-account or ranking API is created.

## Counting authority

All counts derive from `studio_audit`, without joining current entity values or
states. Validated content actions for Topic/Pack/Card are `create`, `update`,
`hide`, `activate`, `softDelete`, `restore`, and `permanentDelete`. Unknown/future
actions and synthetic Pack `batch` revision-rollup rows are excluded. A future
new countable action requires an explicit contract/code change.

Creates map to `topicsCreated`, `packsCreated`, `cardsAdded`. Soft deletions map
to `topicsRemoved`, `packsRemoved`, `cardsRemoved`; they do not subtract creation
credit. Updates/hides/restores/permanent deletes/activations map to the
corresponding counters. `totalOperations` equals the sum of the other counters.
A cascade counts each actual audited resource operation under its validated
actor. A later Owner deletion credits the Owner's removal operation, not the
original creator. Purging an entity never erases prior additions or removals.

Failed transactions have no audit rows and earn no credit. An idempotent replay
returns the prior result without creating audit rows, so it earns no additional
credit. Local drafts, queued edits, selected/uploaded images, keystrokes and
unvalidated publication requests earn no content-mutation credit. Existing
publication-review records remain separate from this content-operation metric.

## Consistency, pagination and errors

Initial counts, contributor aggregates, activity page and audit high watermark
share one D1 batch snapshot. A continuation fixes the high watermark and `asOf`;
newer operations appear only on a fresh explicit request. Pages descend in audit
insertion order and never expose the internal row identifier. AES-GCM encrypted,
padded cursors bind project, requester UID/email/role, authoritative allowlist and Owner pin configuration,
selected actor and page size and expire after 15 minutes. Collector bindings
exclude unrelated users' configuration. Every page reauthenticates before any
private query. A role/allowlist change invalidates the cursor; revoked identities
are denied before records are read. Canonical and compatibility routes share the
same binding.

Errors use the frozen Studio error envelope: 400 `invalid_request`, 401
`unauthenticated`, 403 `forbidden`, 409 `cursor_expired`, 503 `internal_error`.
No counts/activity accompany errors. No token or private content is logged or
persisted by this projection.

Migration `0009_studio_profile.sql` adds only an actor index to existing immutable
audit data. No counter tables, historical-data rewrite, or additional application-level
per-action writes are required. Applying migrations remotely or deploying the Worker remains a
separately authorized operation.
