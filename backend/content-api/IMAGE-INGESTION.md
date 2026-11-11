# Contributor-scoped image ingestion (T32A)

The versioned [image ingestion contract](../../contracts/studio/v1/image-ingestion.openapi.json)
adds one canonical route: `POST /studio/v1/packs/{id}/images`. There is no legacy
alias, raw-image GET/download URL, client DELETE endpoint, publishing route or
direct browser R2 credential. Apply additive `0007_studio_image_ingestion.sql`
only through the existing local migration workflow for this ticket. No remote
resources, production bucket operations, deployment or production cleanup
schedule are configured.

Send the Firebase Google bearer, exact `If-Match: "rev-N"` of the stored Pack,
`Content-Type: image/png` or `image/webp`, `X-Content-SHA256` as lowercase SHA-256
of the binary body, and the normalized T32 bytes. JPEG source images are first
normalized by T32; this endpoint never accepts original JPEG, SVG, animation,
external URLs, multipart fields, creator/role assertions or caller object keys.
Names are local Card labels and are not upload authority.

Successful initial uploads and identical retries return HTTP 200 and only:

```json
{
  "protocolVersion": 1,
  "imageIngestionVersion": 1,
  "packId": "owned-pack",
  "imageReference": "objects/<pack-specific-opaque-digest>.webp",
  "sha256": "<actual-body-sha256>",
  "byteLength": 12345,
  "contentType": "image/webp",
  "width": 512,
  "height": 768
}
```

The reference is a Pack-specific identifier, not a capability or physical object
key. Every request (including retries) repeats verified Firebase allowlist/role
authentication and stored Pack/Topic/creator checks. Collectors access only their
own authenticated Packs; Owner can ingest into any eligible Pack, including
legacy attribution. Missing, foreign, deleted or purged Packs return the same
404 before body/hash/revision details. A live parent Topic is required. Uploads
do not create Cards, alter aggregate revisions, publish, or mutate saved public
artifacts. A later explicit T24 batch with its own revision/idempotency checks
attaches the returned reference to a Card.

## Validation and private storage

The Worker streams into a fixed 5 MiB buffer, rejects oversized/incomplete
transfers, limits the transfer to 30 seconds, verifies body SHA-256, and checks
container structure and dimensions before native codec allocation. Only still,
metadata-free PNG/WebP with edges 1–1024 are accepted. PNG CRCs and endings,
WebP RIFF/chunk/frame bounds and flags, and allowed chunks are checked. Text,
EXIF/XMP, unknown chunks and animation are rejected; safe color/alpha chunks are
allowed. A second independent full pixel decode uses pinned, bundled
`@jsquash/png` 3.1.1 and `@jsquash/webp` 1.5.0 WebAssembly codecs. Decoded
dimensions and RGBA length must match. No decoder code or image URL is fetched
at runtime. See the upstream [jSquash Worker integration](https://github.com/jamsinclair/jSquash/tree/main/examples/cloudflare-worker-esm-format)
and [Cloudflare Wasm runtime](https://developers.cloudflare.com/workers/runtime-apis/webassembly/).

Validated bytes are put only at unique server-generated
`studio-staging/v1/<uuid>` keys with private/no-store metadata. D1 reservations
and finalize triggers recheck live parent/creator/revision state. A ready binding
is established only after the R2 put succeeds. A response interrupted after
finalization can be retried to obtain the identical receipt. Concurrent duplicate
reservations return 409 rather than incrementing quota or overwriting bytes.
Dedup is per Pack and encoded byte hash; equal images in other Packs establish
their own grants without disclosing previous uploads.

On explicit Card Commit, the Worker resolves the Pack binding, independently
revalidates staged bytes, and copies them to the canonical hash key with an R2
create-only precondition. Existing canonical bytes are validated, never replaced.
An attachment guard in the same generation-checked D1 transaction rejects a
binding expired after earlier validation. Any failure leaves Card state unchanged.

## Quotas, retry and trusted orphan cleanup

Resource ceilings are 100 MiB and 1000 ingestion references per Pack, 500 MiB per
original uploading UID, and two concurrent transfers per Worker isolate. D1
insert triggers reserve byte/count quota atomically across requests/isolate
instances. The isolate transfer limit bounds simultaneous buffers and is not a
distributed user/IP rate limiter. These are resource limits, separate from T32's
advisory 50 KiB/image and 10 MiB/Pack quality targets.

An incomplete reservation has a five-minute lease; an unused ready upload has
a 24-hour renewable lifetime. Identical retries revalidate scope/current Pack
revision and renew a ready record without duplicating quota. An interrupted R2
put may leave a reservation: retry returns `upload_in_progress` until its lease
expires and trusted cleanup releases it. No alternate upload key bypass exists.

Before attempting any canonical copy, promotion permanently reserves its byte
charge in D1. Even a failed subsequent Commit retains that charge and binding;
otherwise repeated failed Commits could fill storage while releasing quota.
If the canonical put fails, staging bytes remain for retry. Canonical objects,
including safe copies from failed Commits, are never removed by orphan cleanup.
They remain conservatively charged until a separately reviewed retention policy
can prove they are not referenced by historical publications or retries.

The exported `cleanupImages(env,time?,limit?)` is a trusted operator primitive,
with no public or Collector deletion route. A separately approved rollout must
wire it into the operator/scheduler environment; no production cron is added.
Each call handles at most 100 selected rows and one at-most-100-object listing
page. It transactionally claims expired unused records and removes their Pack
bindings before deleting only private staging objects. Attached or canonically
reserved records retain bindings/charges; their staging copy is removed only
after the canonical object exists. Crashes between D1/R2 steps are retryable.
An enduring listing cursor ensures successive bounded calls reach older unbound
staging keys beyond retained entries, including a late put whose request died
before D1 completion. Cleanup never lists/deletes the canonical object prefix.
No content entity, rights record, publication, audit or tombstone is deleted.

## CORS and errors

The existing exact-origin `STUDIO_ALLOWED_ORIGINS` policy covers upload POST and
OPTIONS, including `authorization,content-type,if-match,x-content-sha256`.
Unapproved origins, wildcard/suffix guesses, unsupported preflight headers and
OPTIONS without Origin are denied. Requests without Origin remain permitted
for authenticated nonbrowser clients; they receive no CORS grant. CORS supplies
no role/ownership authority. All upload/error responses are no-store and vary
by Origin. Private staging is not reachable through anonymous content downloads.

| Status | Code | Meaning |
| --- | --- | --- |
| 400 | `invalid_request`, `upload_interrupted` | Invalid route or incomplete body |
| 401/403 | existing auth errors | Invalid identity or revoked access |
| 404 | `not_found` | Missing or out-of-scope Pack |
| 408 | `upload_interrupted` | Body transfer timeout |
| 409 | `upload_in_progress` | Active/cleanup reservation or renewal race |
| 412 | `revision_conflict` | Refresh the stored Pack revision |
| 413 | `image_too_large` | Source exceeds the 5 MiB ingestion bound |
| 422 | `validation_failed` | Hash/format/pixels/dimensions/parent invalid |
| 428 | `precondition_required` | Send the exact current Pack precondition |
| 429 | `quota_exceeded`, `rate_limited` | Retained storage or isolate concurrency bound |
| 503 | `storage_unavailable` | Retry after transient storage failure |

Run `npm run typecheck` and `npm test` from this directory. The dedicated
`test/image-ingestion.test.mjs` uses real Workerd, D1, R2 and Wasm pixel decoding;
only Google signing-key discovery is mocked. Its separate test-only operator/
failure harness never enters production `src/`. Browser tests additionally
exercise real cross-origin preflights and T32 normalized bytes before attachment.
