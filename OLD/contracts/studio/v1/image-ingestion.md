# Private image ingestion extension v1 (T32A)

This additive [OpenAPI 3.1 contract](image-ingestion.openapi.json) leaves the
frozen content-v1 StudioBatch/StudioResult and public distribution contracts
unchanged. Image selection, normalization and hashing run locally through T32.
Ingestion and Card attachment are separate explicit operations.

## Request and receipt

`POST /studio/v1/packs/{packId}/images` accepts raw normalized `image/png` or
`image/webp` bytes. Send the verified Firebase Google ID token as `Authorization:
Bearer …`, lowercase hex `X-Content-SHA256`, and the stored Pack aggregate
precondition `If-Match: "rev-N"`. No arbitrary object key, URL, actor, owner,
filename, signing credential or client-declared dimensions are accepted. JPEG
source images must first pass through T32, which outputs WebP or PNG.

Every request derives UID/role from the existing server allowlist and checks the
stored Pack and eligible Topic before reading file bytes or reporting revision
errors. Collectors can ingest only into their own Packs; Owner can ingest into
any eligible Pack. Missing/foreign/deleted Packs return indistinguishable 404s
to Collectors. CORS is separate: a present Origin must exactly match the
server-configured approved origins; OPTIONS validates the requested method and
headers without granting upload authority. Authorized nonbrowser requests may
omit Origin, as with existing Studio endpoints. All private responses use
`Cache-Control: no-store` and `Vary: Origin`; no upload response enters a public
HTTP/service-worker cache.

The server bounds transfer size at 5 MiB and independently validates the claimed
SHA-256, container structure, still-image format, metadata policy, dimensions
(1–1024 per edge), and fully decoded RGBA pixels using bundled codecs. It does
not trust T32 metadata. The request body has a 30-second transfer deadline.
The approximate 50 KiB/image and 10 MiB/Pack quality targets remain advisory.
At most two image transfers run concurrently per Worker isolate; excess
authorized requests receive 429 `rate_limited` before body buffers are read.

Success and a successful same-content retry return status 200 and:

```json
{
  "protocolVersion": 1,
  "imageIngestionVersion": 1,
  "packId": "owned-pack",
  "imageReference": "objects/<pack-specific-64-hex-reference>.webp",
  "sha256": "<actual-64-hex-content-hash>",
  "byteLength": 12345,
  "contentType": "image/webp",
  "width": 640,
  "height": 480
}
```

The example placeholders illustrate the fields; schema instances require actual
lowercase hexadecimal values. `imageReference` is Pack-specific and opaque. It
is not the R2 key, a download URL, a presigned capability or a publication grant.
The client verifies the receipt matches its current Pack/prepared bytes and
stores it separately from canonical Card product fields. The draft's canonical
image reference can then be queued for explicit Commit; its ID and Pack remain
unchanged. Local draft save, image upload and local queueing do not execute a
Card mutation or publish anything.

## Retry, quotas and cleanup

Same Pack/content bytes deduplicate to one ingestion binding and receipt. A
lost response can be retried with the same normalized bytes/hash and current
Pack revision. Requests in progress return retryable 409 `upload_in_progress`;
stale Pack revisions return 412 `revision_conflict`. Malformed/corrupt data is
rejected before a storage reservation. Missing preconditions are 428; too-large
images 413; quota failures 429; storage failures 503. Other errors retain the
content error envelope; ingestion-specific codes are defined only in this
extension, without changing the frozen public Error enum.

D1 atomically reserves both bytes and image count before R2 writes: at most
100 MiB and 1000 ingestion references per Pack, and 500 MiB charged to the
original uploading UID across Packs. Duplicate uploads do not consume another
reservation. Ownership/state/revision are checked again during reservation and
finalization. Reservations have a five-minute lease; ready bindings that have
not started canonical promotion have a 24-hour orphan lifetime, renewed by a
successful retry. A retained local
receipt can outlive its binding: retry upload before attachment if it expired.

Trusted bounded cleanup is an operator primitive, with no Collector/HTTP delete
route and no production cron added by this ticket. It reclaims expired private
staging and orphaned attempts, retains referenced canonical history, and can be
resumed safely. Collector discard/cancellation never deletes remote content.
Cancellation or a network failure may leave a server-side staging reservation;
retry or operator cleanup resolves it.
Cancellation after receipt persistence has begun cannot roll back an already
committing browser storage transaction; it still cannot attach or publish a Card.

## Explicit attachment and immutable objects

Upload writes only unique private staging keys and establishes the Pack binding.
It does not change aggregate revisions, Card records or public content. R2 has
no public read route for staged images, and no persistent R2 write credentials or
publisher signing keys are exposed in JavaScript.

A later explicit T24-style `POST /studio/v1/batches` references the returned
opaque image identifier in a canonical Card create/update. It still requires
the Pack aggregate revision and actor-scoped Idempotency-Key. The server resolves
Pack scope and binding, validates staged bytes again, conditionally promotes to
the immutable content-hash object, and attaches within the guarded D1 mutation.
Cleanup cannot invalidate a binding between validation and a successful Card
commit. Existing published objects are never overwritten or removed. A failed
Commit may leave an immutable canonical copy; its reservation stays charged
against quota before any canonical write and survives staging cleanup, so failed
Commits cannot create uncharged immutable storage. Conservative retention preserves
historical/public content. General browser Commit/Refresh/conflict transport is
T36; ingestion does not silently flush the local queue.

No production bucket operation, remote migration, Content Backend deployment,
API activation, publishing route or bulk Card import is authorized by this
implementation. Local Workerd/D1/R2 and synthetic browser fixtures provide the
acceptance evidence.
