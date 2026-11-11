# T32A private image ingestion verification — 2026-11-10

[Versioned protocol](../contracts/studio/v1/image-ingestion.md) and
[Studio policy](README.md#private-image-ingestion-t32a).

## Acceptance evidence

The dedicated backend suite runs the production routing/authentication,
independent bundled PNG/WebP WASM decoders, D1 transactions/triggers and R2 under
local Workerd. Firebase RS256 JWTs are signed with ephemeral test keys; only
Google JWKS responses are substituted. Tests check two isolated Collectors and
Owner, malformed/stale revisions, missing/revoked identities, foreign-Pack reads
and attachment, supported normalized formats/transparency, valid-hash corrupt
encoded pixels, valid-CRC invalid PNG deflate/metadata/dimensions, MIME/hash/size
mismatches, interrupted request/R2 writes, same-content retry/dedup, Pack/UID/count
quotas and concurrent reservations. Cleanup races, scan progress and immutable
canonical retention have dedicated assertions. No production test bypass is
imported by the Worker.

The real Chromium harness serves the packaged Flutter fixture and a separate
loopback API origin. A fixture gateway translates synthetic browser identity
tokens to signed test Firebase JWTs; production Worker authentication still
verifies the full signed identity and server role allowlist. Native browser
preflights cross the actual origin boundary under the packaged CSP. The UI uses
T32 selection/normalization, saves a local Card, explicitly uploads privately,
verifies receipt persistence through reload, and keeps the Card ID unchanged.
Direct browser requests exercise lost/truncated response recovery, duplicate
retry, bad hashes/corruption, foreign Pack/Collector denial and unapproved-origin
preflight denial. Approved-origin anonymous requests still return 401. Staging
bytes cannot be fetched anonymously and the canonical object does not exist
before explicit T24 Commit. A separate revision/idempotency-checked batch attaches
the returned reference, promotes canonical bytes and retains the Card ID. No
upload, local save or local queue operation publishes content.

Flutter tests independently cover exact binary request headers/body, strict
receipt validation and mismatch rejection, authorization errors, temporary busy
versus quota recovery, cancellation, local receipt serialization, failed storage
saves, offline prohibition, interrupted retry, replacing an image, and delayed
responses after account changes. Local prepared images survive failure. Receipts
are operational state outside the canonical game product fields.

## Reproduce locally

From `backend/content-api`:

```bash
npm ci
npm run typecheck
npm test
```

These scripts build with Wrangler `--dry-run` and use ephemeral local storage.
They do not deploy, apply remote migrations or access a production bucket.
Miniflare explicitly loads the Wrangler-emitted bundled WASM modules; codecs
are not fetched at runtime. Dependency versions are pinned in the lockfile.

Using the isolated Playwright installation from
[T28 verification](T28-VERIFICATION.md#reproduce-browser-checks), from `studio`:

```bash
bash scripts/check.sh all
python3 -m unittest discover -s test -p 'test_*.py' -v
flutter test --platform chrome test/dataset_store_test.dart
flutter build web --release --no-web-resources-cdn --pwa-strategy=none --target test/browser_dataset_app.dart --output build/dataset-web
node scripts/image_preparation_browser.cjs
node scripts/dataset_browser.cjs
node scripts/image_ingestion_browser.cjs
```

The ingestion harness additionally needs the backend dependencies and built
`dist/index.js`/WASM. The Studio workflow now runs this integration before static
deployment; a separate Content API workflow runs local backend tests without
deployment credentials. Root Mobile/tooling gates remain those in AGENTS.md.

## Limits and operational boundary

General browser mutation queue transport, Refresh conflict reconciliation and
bulk authoring remain T36/T33. The new UI explicitly uploads only the selected
image. Its receipt supplies a valid image reference for an explicit T24-style
batch; uploading does not flush pending Card changes.

Cleanup is a trusted bounded operator primitive, not an HTTP deletion endpoint
and not a newly configured production cron. Immutable canonical copies remain
retained and charged after attempted promotion, including failed Card Commits.
Cancellation cannot undo a completed server write or an IndexedDB transaction
already committing. Retry deduplicates known content; staging cleanup recovers
orphaned attempts. A local receipt can outlive an expired unpromoted binding and
then requires reupload. Site eviction/quota and offline revocation limits from
T28 still apply.

The per-isolate two-transfer guard bounds transient ingestion work; distributed
edge rate limiting and production monitoring remain deployment concerns. Quotas
are transactionally enforced across requests. Live browser verification uses
Chromium; simulated API-capability tests do not certify other browser engines.
No real contributor images, production identities, production bucket operations,
Content Backend deployment, API activation or publication occur in these checks.
