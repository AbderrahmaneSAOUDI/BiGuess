# T46 backend authorization and synchronization evidence

Audited source: `20bb0edf088de6ee9df3a1a65708f06836ab2c6e` (2026-11-12).
This report covers local Workerd/Miniflare, D1 and R2 fixtures. It does not assert
that production Firebase or a deployed private Content API was exercised.

## Commands and results

Run from `backend/content-api` with Node `v22.23.3`, npm `12.2.0` and pinned
Wrangler `4.157.0`:

```sh
npm run typecheck
npm test
```

The test command first runs `wrangler deploy --env staging --dry-run --outdir dist`,
then `node --test --test-concurrency=1 test/*.test.mjs`. The build log explicitly
ends its packaging phase with `--dry-run: exiting now.` Local migration/seed tests
use `--env local --local --persist-to <temporary directory>`; they do not apply
cloud migrations. Public publication tests activate only local generated fixture
artifacts. No backend deployment or production publication was performed.

Both commands exited **0**. `npm run typecheck` passed; the complete test run
passed **235/235 tests**, with **0 failed, cancelled, skipped or TODO**, in
`432534.239755 ms` (TAP duration). Completed by `2026-11-12T00:31:10Z`.

The local matrix below is **PASS**. This is a local backend result, not a pass of
the overall T46 production/device gate.

Raw logs are session-local. Their final SHA-256 digests identify this exact run;
the commands, baseline, counts and decisive assertions remain in this report:

| Log | SHA-256 |
| --- | --- |
| `/tmp/t46/backend/typecheck.log` | `51d37747e41fe1f8d25c802a026c2252447004a6caf05cf07166939df57e6391` |
| `/tmp/t46/backend/test.log` | `8b0be97866b27c4ca71f3cad8ae2cb21a6e0a7b2b99fc4664b65923bb7e054c1` |

## Authorization, privacy and mutation matrix

Every source link below names assertions executed by the complete backend suite.
The fixture authentication path verifies real RS256 signatures and Firebase-shaped
claims in the Worker. Only Google's JWKS response is replaced with a local test key;
there is no production authentication-bypass binding.

`studio-contract.test.mjs` executes all **118 server-stage T27A vectors** from
`contracts/studio/v1/fixtures.json`. Its three explicitly client-stage vectors are
excluded by that runner and require Studio evidence rather than being counted as
backend passes.

| Scenario | Local evidence | Scope of result |
| --- | --- | --- |
| Two isolated Collectors plus Owner; guessed IDs | [studio-scope.test.mjs:132](../../backend/content-api/test/studio-scope.test.mjs#L132): each Collector lists only own Pack/Card records; Owner sees both and legacy drafts. Guessed foreign, legacy and missing IDs all return sanitized 404s. Searches and minimal shared taxonomy exclude private ownership metadata. | Real Worker reads against local D1. |
| Foreign edits, malicious batches and ownership spoofing | [studio-scope.test.mjs:157](../../backend/content-api/test/studio-scope.test.mjs#L157): all foreign mutations leave every table unchanged; forged `createdByUid` fails. Collectors cannot delete, restore or purge. [studio-mutations.test.mjs:146](../../backend/content-api/test/studio-mutations.test.mjs#L146) rejects forbidden operations smuggled inside an otherwise permitted batch. | Server authorization and transaction rollback. |
| Authentication/allowlist revocation | [studio-auth.test.mjs:75](../../backend/content-api/test/studio-auth.test.mjs#L75) rejects expired, malformed, forged, wrong-project/provider and unsigned tokens. [studio-auth.test.mjs:267](../../backend/content-api/test/studio-auth.test.mjs#L267) denies the same valid signed token after server allowlist removal. [studio-scope.test.mjs:267](../../backend/content-api/test/studio-scope.test.mjs#L267) denies revoked users before initial/feed access. | Fixture key and server allowlist changes; **live Firebase account disable/token revocation not exercised**. |
| Scoped initial/changed feeds, account switches and scope changes | [studio-scope.test.mjs:223](../../backend/content-api/test/studio-scope.test.mjs#L223): cursors cannot cross actors, selectors or revisions. [studio-scope.test.mjs:243](../../backend/content-api/test/studio-scope.test.mjs#L243): foreign upserts/removals never enter a Collector feed; old upserts cannot resurrect deleted private fields. [studio-scope.test.mjs:204](../../backend/content-api/test/studio-scope.test.mjs#L204) fences formerly privileged retries after downgrade. | Backend boundary; browser local-cache isolation is a separate Studio check. |
| Stale Commit and retry identity | [studio-mutations.test.mjs:118](../../backend/content-api/test/studio-mutations.test.mjs#L118) and [studio-scope.test.mjs:343](../../backend/content-api/test/studio-scope.test.mjs#L343): competing writers return one 200 and one 412; winner is retained. [studio-mutations.test.mjs:131](../../backend/content-api/test/studio-mutations.test.mjs#L131): replay returns original result, changed payload/precondition returns 409 without duplicate audit writes. | Aggregate revisions/idempotency; client draft preservation tested separately. |
| Contributor statistics and activity privacy | [studio-profile.test.mjs:67](../../backend/content-api/test/studio-profile.test.mjs#L67): both Collectors see only own audit-derived counts/activity, Owner sees all. [studio-profile.test.mjs:92](../../backend/content-api/test/studio-profile.test.mjs#L92): invalid/replayed operations do not inflate counts; deletion/purge preserves credit; audit UPDATE/DELETE is rejected. [studio-profile.test.mjs:113](../../backend/content-api/test/studio-profile.test.mjs#L113): snapshot cursors cannot cross users/roles/filters and fail after revocation. | Immutable local D1 audit reconciliation. |
| Authorized bulk operations | [studio-mutations.test.mjs:269](../../backend/content-api/test/studio-mutations.test.mjs#L269): 100 operations commit with one Pack revision. [studio-mutations.test.mjs:165](../../backend/content-api/test/studio-mutations.test.mjs#L165) rejects duplicates, strict-field/precondition/image errors without partial writes. | Transactional batch endpoint. |
| Image upload authorization and malicious bytes | [image-ingestion.test.mjs:89](../../backend/content-api/test/image-ingestion.test.mjs#L89): independent WASM decode, private staging, dedup and explicit attachment. [image-ingestion.test.mjs:122](../../backend/content-api/test/image-ingestion.test.mjs#L122): guessed foreign IDs, cross-Pack references and revoked users fail. [image-ingestion.test.mjs:145](../../backend/content-api/test/image-ingestion.test.mjs#L145): false hash/type, SVG, corrupt PNG/WebP, metadata, excessive size/dimensions, truncated/broken stream and stale preconditions fail before persistence. Quota/concurrent-transfer and cleanup cases run in the same file. | Worker decode/storage; browser preparation is separate. |
| Origin/auth restrictions | [studio-auth.test.mjs:202](../../backend/content-api/test/studio-auth.test.mjs#L202), [studio-auth.test.mjs:230](../../backend/content-api/test/studio-auth.test.mjs#L230), [studio-auth.test.mjs:255](../../backend/content-api/test/studio-auth.test.mjs#L255): exact configured HTTPS origin, bounded preflight and fail-closed unsafe/missing configuration. [studio-scope.test.mjs:312](../../backend/content-api/test/studio-scope.test.mjs#L312) rejects origin suffix attacks and ambiguous/foreign query selectors. | Server enforcement, independent of UI visibility. |
| Pack rights/publication gate | [publication-review.test.mjs:104](../../backend/content-api/test/publication-review.test.mjs#L104): unauthorized Collector/foreign review, initial publication and rights approval fail. [publication-review.test.mjs:117](../../backend/content-api/test/publication-review.test.mjs#L117): uncleared/invalid content cannot approve/release. [publication-review.test.mjs:127](../../backend/content-api/test/publication-review.test.mjs#L127): approval queues privately; operator, signature and Topic approval are separate gates. Revoked/stale/hidden actors and concurrent writes cannot activate queued content. | Local operator fixtures only; no production publish. |
| Legacy quarantine and attribution | [legacy-import.test.mjs:113](../../backend/content-api/test/legacy-import.test.mjs#L113): imported records are hidden, Owner-only, stable/repeatable, preserve provenance, give neither Collector credit nor feed entries, and guessed IDs fail. [legacy-import.test.mjs:147](../../backend/content-api/test/legacy-import.test.mjs#L147): even Owner generic approval and signed operator release cannot publish quarantine; final SQL race guards reject publication. | Synthetic quarantine from cleared Shapes; actual legacy assets never released. |

## Public content and Migration §25 server scenarios

| Scenario | Decisive assertions |
| --- | --- |
| Anonymous new Pack discovery/download | [catalog.test.mjs:45](../../backend/content-api/test/catalog.test.mjs#L45) validates compact public summary contracts; [publication.test.mjs:87](../../backend/content-api/test/publication.test.mjs#L87) fetches resolve/receipt/manifest/archive and every object anonymously, checks hashes/sizes/signature and denies raw shared object paths. |
| Unchanged/repeated refresh | [catalog.test.mjs:86](../../backend/content-api/test/catalog.test.mjs#L86) and [sync-delta.test.mjs:201](../../backend/content-api/test/sync-delta.test.mjs#L201): exact-byte ETags return 304, but visibility/storage authority is checked before cache success. [sync-delta.test.mjs:215](../../backend/content-api/test/sync-delta.test.mjs#L215): bounded revision checks distinguish unchanged/update/unknown without a full Pack transfer. |
| New Card / 100 → 105 | [sync-delta.test.mjs:164](../../backend/content-api/test/sync-delta.test.mjs#L164): compact patch has exactly five upsert Cards and five objects, reconstructs the exact 105-Card target and verifies changed bytes. |
| Modified Card / changed image | [sync-delta.test.mjs:259](../../backend/content-api/test/sync-delta.test.mjs#L259): edited metadata reuses unchanged addressed images. [sync-delta.test.mjs:273](../../backend/content-api/test/sync-delta.test.mjs#L273): replacement lists only newly required bytes and multi-revision reconstruction equals the target. |
| Valid remote deletion | [sync-delta.test.mjs:362](../../backend/content-api/test/sync-delta.test.mjs#L362): Owner tombstones survive catalog removal and permanent purge with exact Pack ID, advancing revision, timestamp and administrative reason. [sync-delta.test.mjs:351](../../backend/content-api/test/sync-delta.test.mjs#L351): hiding creates no deletion authority. Home safe-point application is a Mobile check. |
| Interrupted publish/storage failure | [publication.test.mjs:120](../../backend/content-api/test/publication.test.mjs#L120): interrupted writes expose no partial revision; CAS admits one writer; immutable history survives rollback. [publication.test.mjs:173](../../backend/content-api/test/publication.test.mjs#L173): D1 projection failures roll back activation/history; retry reuses immutable artifacts. |
| Malformed/malicious manifests | [publication.test.mjs:70](../../backend/content-api/test/publication.test.mjs#L70): unknown key/tampered receipt, manifest, archive or objects fail. [publication.test.mjs:188](../../backend/content-api/test/publication.test.mjs#L188): even signed invalid difficulty, parent, name, schema fields, duplicate IDs/objects, insufficient Cards, denied/incomplete rights or nonimage bytes never activate. [sync-delta.test.mjs:228](../../backend/content-api/test/sync-delta.test.mjs#L228) rejects malformed/boundedness violations. |
| Service unavailable | [catalog.test.mjs:131](../../backend/content-api/test/catalog.test.mjs#L131): missing schema returns retryable service error, never a false empty catalog. [publication.test.mjs:143](../../backend/content-api/test/publication.test.mjs#L143): damaged storage, unavailable parents and stale caches fail safely. Offline usability/restart requires Mobile evidence. |

Only generated rights-cleared fixtures are activated in the test catalog. The
legacy-import suite copies the rights-cleared Shapes fixture and assigns synthetic
unverified provenance solely to test quarantine denial. No Anime/Flags source is
published or released by these commands.

## Unavailable live evidence

This run does not test a live `biguess-firebase` sign-in, Firebase administrative
disable/revocation propagation, deployed allowlist changes, real cloud R2/D1 policy,
or production unauthorized requests. These remain explicit live-environment gate
items; local passes cannot certify those installations. Browser persistence,
cross-tab drafts and Mobile physical-device behavior also lie outside this report.
