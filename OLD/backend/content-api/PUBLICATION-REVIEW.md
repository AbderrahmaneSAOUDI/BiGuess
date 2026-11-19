# T35 publication review and operator boundary

This implementation is local-tested infrastructure. It does not deploy a Worker,
apply a remote migration, provision keys, or publish any real dataset. Public v1
contracts and the offline game are unchanged. Apply additive migration `0008`
after `0007` in local tests; production rollout remains T47's separate gate.

## Studio workflow

Only synced Topics/Packs without pending local changes can enter publication
review. Browser review does not upload local content. The authenticated,
owner-scoped routes are additive:

- `GET /studio/v1/{topics|packs}/{id}/publication`: current preview, revision,
  fingerprint, eligible Cards, validation errors, rights/initial approval,
  current public revision and pending operator request.
- `POST .../publication/validate`: revalidate without writing.
- `POST .../publication/approve-rights`: Owner only; requires a private rights
  record reference in `evidence`. Approves this Pack and its current Card/image
  pairs. Evidence and approvals are append-only; product fields stay unchanged.
- `POST .../publication/approve`: Owner approval of the exact current review.
- `POST .../publication/publish`: Owner publishes an approved Topic, or queues an
  eligible signed Pack release for an operator. A queued request is **not public**.
- `POST .../publication/unpublish`: Owner for Topics; Owner or owning Collector
  for Packs. Hides discovery/downloads, retains immutable history, creates no
  tombstone and makes outstanding release reviews stale.

All POST bodies contain `revision` and `fingerprint` obtained from a fresh GET.
Rights approval adds `evidence`. Unknown fields, stale fingerprints/revisions,
foreign Pack IDs, deleted parents and unapproved rights fail closed. Cards have
no independent publication endpoint. Both `/studio/v1` and the authenticated
`/content/v1/studio` alias use the same boundary.

A Pack needs at least two active valid Cards, verified Pack-bound PNG/WebP images,
and Owner rights approval for the Pack and every eligible Card/image. Verification
checks hashes, media types, format structure and actual decoding, one image at a
time (5 MiB/image, 100 MiB total, 1000 eligible Cards). New/replaced Card images
require fresh rights approval; changing names/difficulties or hiding approved
Cards does not invalidate those existing image approvals. Review evidence is
private and never added to public catalog summaries or gameplay Cards.

Initial or explicitly hidden Pack publication requires Owner approval of the
exact review. An owning Collector may request validation/release of routine edits
only while that Pack was public, including T24's temporary Card-hide suppression.
No extra Collector create/edit/delete powers are granted. Routine releases do
not need another initial approval, but pass all content/rights checks again.
T24 commits remain authoring changes; they cannot silently distribute revisions.
An explicit release request must be consumed by the authenticated operator.

Topic visibility is an independent Owner decision. Releasing a Pack beneath a
hidden/draft Topic preserves that Topic's visibility. Publishing a Topic changes
only its summary and visibility; Packs become discoverable only after their
signed immutable release has independently activated.

## Operator review and provisioning gate

`src/publication-operator.ts` is a **separate entrypoint**, absent from the public
API bundle and all site CI/deployment workflows. `operator.wrangler.json` has
placeholder storage IDs, no public routes, workers.dev or preview URLs. It is
not usable production configuration. A dry-run build is safe:

```bash
npx wrangler deploy --config operator.wrangler.json --dry-run --outdir /tmp/biguess-operator-build
```

Before separately authorizing any deployment, an operator/security reviewer must
review this source and the T22 publisher, approve the target D1/private R2 and
migration plan, pin `PUBLICATION_KEYS`, and provision an independent random
`PUBLICATION_OPERATOR_TOKEN` (at least 32 characters) as a secret. Keep Firebase
project and server `STUDIO_USERS` aligned with the API. The request actor's UID
and role must still appear exactly once in the operator's server allowlist at
activation; removal or demotion blocks queued requests. Provision explicit
allowlist entries for all release actors, including any separately configured
bootstrap owner. Expose the service only through a private service binding or
an independently reviewed operator access path; never add an anonymous route or
attach it to Studio/frontend publishing CI. Neither Worker nor Studio holds a
private signing key. Do not put the operator token in browser configuration.

The authorized operator reads the pending request and exact authoring snapshot
through trusted database tooling, exports the approved content using T22's
existing offline archive tooling, and runs `scripts/prepare.mjs` with an
operator-owned Ed25519 key outside the repository. The existing v1 preparer and
public manifest accept **cleared-test provenance only**. General production
rights provenance still requires the separately versioned contract decision;
Owner approval cannot bypass this limitation. Unverified Anime/Flags stay drafts;
no source assets are imported or published by this ticket.

Submit the resulting bundle JSON as the POST body to `/releases/{requestId}` on
the private service with `Authorization: Bearer <operator-secret>`. The service
accepts at most 16 MiB of bundle JSON until larger streaming budgets are reviewed.
It rechecks actor authorization, ownership, pending status, exact review,
revision, rights and decoded images, then requires an exact signed manifest match.
It delegates signature/artifact verification and create-only storage to T22.

A generation guard joins T22's activation transaction. Any concurrent authoring,
rights, approval, unpublish or competing release invalidates the checked snapshot.
The immutable receipt/history, public projection, authoring state and request's
`released` status commit together. Failed writes leave only undiscoverable R2
objects. Signed artifacts cannot overwrite a newer draft or silently publish a
Topic. A response lost after activation is reconciled against the saved request
status/head; repeated submissions of a released request return a conflict.

Retain all prior artifacts, receipts and public verification keys. Forward
rollback exports the earlier approved content at a **new higher authoring
revision**, repeats validation/review as applicable, and uses T22 normally.
Unpublishing cannot recall already cached/downloaded bytes and does not prescribe
an offline deletion policy. No new garbage collector or destructive API is added.

## Verification

`npm run typecheck` and `npm test` exercise the real Workerd/D1/R2 service with
ephemeral RSA Firebase tokens and Ed25519 publisher keys, cleared Shapes fixtures,
and no cloud deployment. `test/publication-review-worker.ts` is a test-only
router that hosts both boundaries for tests; production never imports it.
Studio transport/controller/widget tests verify role-sensitive controls, pending
local changes, account-change cancellation and queued-versus-public messages.

Review currently accepts the normalized PNG/WebP image pipeline from T32/T33.
Historical T22 JPEG artifacts remain readable through the unchanged public
publisher/download path, but cannot enter this new Studio release workflow until
the operator replaces those images with verified normalized PNG/WebP and obtains
rights approval for the new Card/image pairs. This is a fail-closed review input
restriction; no existing signed history is rewritten.
