# T48 Content Backend security and rollout audit

**Decision: NOT READY for an additional production backend/data rollout.** The
production Studio API already exists; it must not be described as an undeployed
scaffold. The missing staging rehearsal, pending production migrations, live
multi-account verification and recovery/alert evidence require separate Owner
review. This audit performed read-only metadata queries and anonymous HTTP probes;
it did not deploy, migrate, export private data, publish, change secrets or restore.

Audited repository: `6c8115ea4c1841d83aeee237eb921e30bc8c6198`, 2026-11-12 UTC.
Backend product sources match the T46 run at `20bb0ed`: its **235/235 local backend
tests and clean typecheck** remain applicable. See [T46 backend evidence](T46-BACKEND-EVIDENCE.md)
for fixture scope and exact source assertions. No suite was rerun merely for this
documentation audit. Local tests do not certify the older deployed bundle.

## Live metadata and boundaries

Commands used the installed Wrangler `4.157.0` from `backend/content-api` through
`node node_modules/wrangler/bin/wrangler.js`. Production commands explicitly selected
`--config wrangler.production.json`; staging commands selected `--env staging` with
the separate default configuration. Logs are under `/tmp/t48/backend`.

| Check / read-only command suffix | Result | Interpretation |
| --- | --- | --- |
| `deployments list --config wrangler.production.json` | PASS: latest 100% version `4f9c63ae-6834-4835-af5f-1092eada9746`, deployed `2026-11-11T08:45:30.257Z` | Production is already live. Earlier versions `3d9f83eb-760e-443f-a182-5e37d0b3da6a` and `150e468c-8af3-428a-b40e-c79815ca7c69` are listed; compatibility/rollback was not exercised. |
| `versions view 4f9c63ae-6834-4835-af5f-1092eada9746 --json --config wrangler.production.json` | PASS: handler `fetch`, compatibility `2026-11-01`, standard usage model; dedicated production D1/R2, project `biguess-firebase`, exact `https://studio.saoudi.online` origin | Metadata agrees with [production configuration](../../backend/content-api/wrangler.production.json). There is no scheduled handler in this deployed version. Deployed source Git SHA is not supplied by its version tags. |
| `secret list --config wrangler.production.json` | PASS: names only, `STUDIO_SUPER_ADMIN_UID` and `STUDIO_USERS` | No secret values or allowlist membership were retrieved. Secret presence does not prove the current allowlist contents, Collector access or revocation behavior. |
| `d1 migrations list DB --remote --config wrangler.production.json` | **GAP:** pending `0009_studio_profile.sql` and `0010_legacy_quarantine.sql` | These are approval-only rollout candidates, not permission to apply them. Current source/schema readiness differs from production. |
| `d1 execute DB --remote --config wrangler.production.json --command 'SELECT name,applied_at FROM d1_migrations ORDER BY id'` | PASS: `0001`–`0008` applied on Nov 11, `08:34:56`–`08:34:58` UTC; `rows_written=0`, `changed_db=false` | Confirms the remote ledger rather than inferring it from local SQL files. |
| Read-only aggregate-count SELECT on `studio_entities`, `publication_heads`, published `catalog_topics`/`catalog_packs`, and `studio_image_uploads` | All five counts **0**; `rows_written=0`, `changed_db=false` | No authoring/publication/image content in these collections at this snapshot. No entity, identity or audit rows were exported. |
| `d1 info DB --config wrangler.production.json` | PASS: dedicated DB created Nov 11; WEUR, 28 tables, 307 kB | Aggregate usage information is available. A point-in-time usage snapshot is not an alert policy or capacity/load test. |
| `r2 bucket dev-url get biguess-content-production --config wrangler.production.json` | PASS: public `r2.dev` access disabled | One public surface checked. |
| `r2 bucket domain list biguess-content-production --config wrangler.production.json` | PASS: no custom domains | Second public surface checked independently. |
| `r2 bucket info biguess-content-production --config wrangler.production.json` | PASS: object count **0**, size **0 B**, Standard storage, WEUR | Empty dedicated private bucket; no legacy/public content was seeded. |
| `r2 bucket cors list biguess-content-production --config wrangler.production.json` | EXPECTED ABSENCE, nonzero CLI result: Cloudflare code `10059`, CORS configuration does not exist | No direct-bucket browser CORS grant. This is not the authenticated Worker CORS policy and does not replace access/IAM review. |
| `r2 bucket lifecycle list biguess-content-production --config wrangler.production.json` | PASS: only default abort-incomplete-multipart rule after seven days | No object-expiry rule was returned that would delete retained immutable revisions. This rule does not run the application's private staging orphan cleanup. |
| `d1 time-travel info DB --config wrangler.production.json` | PASS: current recovery bookmark returned | Read-only capability check, **not** backup capture, retention-window evidence, restore verification or a recovery-time/data-loss guarantee. |
| `deployments list --env staging` | **GAP**, nonzero: Worker does not exist, code `10007` | The configured named staging Worker is absent in the selected account. |
| `r2 bucket info biguess-content-staging --env staging` | **GAP**, nonzero: bucket does not exist, code `10006` | Remote staging is not ready. `wrangler.json` additionally uses placeholder D1 UUIDs and `remote:false`; it is a local harness, not evidence of a rehearsed cloud stage. |

The aggregate query was exactly:

```sql
SELECT 'studio_entities' AS collection,count(*) AS count FROM studio_entities
UNION ALL SELECT 'publication_heads',count(*) FROM publication_heads
UNION ALL SELECT 'published_topics',count(*) FROM catalog_topics WHERE published=1
UNION ALL SELECT 'published_packs',count(*) FROM catalog_packs WHERE published=1
UNION ALL SELECT 'image_uploads',count(*) FROM studio_image_uploads;
```

## Anonymous HTTPS probes

`curl --max-time 20` requests to the existing
`https://biguess-content-production.biguess-api.workers.dev` origin returned:

| Request | Result |
| --- | --- |
| `GET /health` | 200, JSON `status=ok`, `environment=production`, `no-store`. Liveness only; not schema readiness. |
| `GET /__fixture` | 404, fixture unavailable outside local development. |
| `GET /studio/v1/session`, approved Studio Origin, no bearer | 401 `unauthenticated`, Bearer challenge, exact approved CORS origin, `no-store`. |
| Same request with `Origin: https://evil.example` | 403 `forbidden`, no CORS allow-origin. |
| `OPTIONS /studio/v1/packs/t48-audit-nonexistent/images`, approved Origin/method/headers | 204; precise approved origin and bounded methods/headers. No identity/role is granted by preflight. |
| `GET /content/v1/packs/t48-audit-nonexistent/download` | 404 `not_found`, anonymous public CORS `*`, `no-store`; no object bytes. |

Initial Python urllib probes returned generic text/plain 403s even for health.
They were not counted as application authorization evidence; independent curl
requests reached the expected Worker JSON responses. No signed-in bearer was used.
Public catalog pagination was not invoked: its snapshot implementation may write
bookkeeping rows on GET, while this audit deliberately stayed read-only.

## Security review and unresolved rollout inputs

| Area | Evidence / gap | Required Owner/operator input before rollout |
| --- | --- | --- |
| Identity and authorization | [studio-auth.ts](../../backend/content-api/src/studio-auth.ts) verifies project-bound RS256 Firebase Google tokens, verified email/UID and server-derived roles. [studio-cors.ts](../../backend/content-api/src/studio-cors.ts) separates exact private origins from anonymous public CORS. T46 proves two-Collector/Owner IDOR and allowlist removal locally. Live role membership was neither read nor changed. | Approve the intended UID-bound roster through a secure channel and conduct the outstanding live multi-account/revocation test. Removing only a normal allowlist row does not revoke the separately pinned default Owner; remove its pin as well when applicable. Firebase account disable/revocation is not queried on every request; server allowlist removal is authoritative for existing unexpired tokens. |
| Operator and signing separation | [publication-operator.ts](../../backend/content-api/src/publication-operator.ts) is separate from `src/index.ts`; it uses an independent operator token, never a Firebase bearer. Private Ed25519 signing remains offline. The production version has neither `PUBLICATION_KEYS` nor an operator token binding. | Keep publication fail-closed. Separately approve operator hosting, least-privilege credentials, key custody, signer identity and rotation/retention. Do not invent/provision keys during audit. Operator absence on this Worker does not prove that no unrelated operator exists elsewhere in the account. |
| Client trust pins and delivery | [pack_download_controller.dart](../../lib/providers/pack_download_controller.dart) accepts build-pinned `BIGUESS_CONTENT_PUBLIC_KEYS`, default `{}`. Server verification similarly uses operator-pinned `PUBLICATION_KEYS`, never bundle-supplied trust. | Approve matching public-key IDs/SPKI fingerprints through trusted configuration/release; retain keys for readable old revisions. No current Mobile binary pins were inspected. Android signing/distribution remains independent. |
| Rights and takedown | Rights review/Owner approval and operator activation are separate source gates; signed-but-uncleared/malformed fixtures fail T46. Legacy quarantine requires unapplied production migration `0010`. Public distribution currently has zero heads/objects. The frozen manifest preparer accepts cleared test fixture provenance; general production provenance is still a format decision. | Approve only cleared fixtures for staging; record rights evidence, approver and takedown/incident owner. No arbitrary legacy clearance, import, production publish or Collector assignment. Resolve production provenance before any real catalog rollout. |
| Limits and cleanup | Source enforces 5 MiB/30-second PNG/WebP uploads, dimensions ≤1024, two active transfers per isolate; D1 quota triggers enforce 100 MiB/1000 references per Pack and 500 MiB per uploading UID. The isolate ceiling is not distributed abuse protection. Cleanup is an operator primitive with no production schedule; retained canonical artifacts are never pruned automatically. Downloads reverify/buffer whole Packs, potentially O(Pack bytes) per request. | Set named owner-approved request/egress/storage/CPU budgets, run realistic staging load/cost tests and review distributed abuse controls. Approve bounded private staging cleanup separately; preserve publication history, audit, tombstones and canonically reserved bytes. |
| Observability and alerts | Sanitized API errors carry request IDs; D1 exposes aggregate usage. No source alert/budget/monitoring automation or rollout load evidence was found. Current version metadata does not certify cloud logging, IAM or notifications. | Provide dashboard/API evidence of enabled monitoring, redaction/retention, alert recipients and tested triggers for errors, auth denials, quota exhaustion, CPU/requests, D1/R2 storage and egress. Confirm account plan/budgets; do not infer account alerts from repository absence. |
| Backup and recovery | [README rollback policy](../../backend/content-api/README.md#L186) describes immutable migrations, prior Worker compatibility, pre-change secure export, restore to a disposable DB and retained R2. Time Travel bookmark exists, but there is **no recorded cloud backup/restore drill**, verified backup reference, retention window or RPO/RTO signoff in this run. | Database owner must approve backup custody/retention and record a disposable-stage restore drill with schema/count/relationship/receipt/hash checks, measured RPO/RTO and prior Worker compatibility. Confirm plan-dependent recovery window separately; a bookmark alone is insufficient. Never restore over production or erase current writes as an audit step. |
| Independent release policy | [content-api-checks.yml](../../.github/workflows/content-api-checks.yml) runs typecheck plus dry-run/local tests with read-only repository permission and no backend deployment step. Production config is separate from local/staging. | Keep backend code, D1 migrations, operator changes and publication explicit independently approved actions. Static Studio frontend deployment grants none of these permissions. |

The README's opening production section correctly describes the Nov 11 deployment,
but older paragraphs still claim no production target/secrets/public route. Those
historical scaffold statements are stale; this audit records the actual live
metadata and does not silently rewrite product/operational files.

## Approval-only staging and rollback safeguards

The Owner must name the rollout decision maker, database/R2 operator, auth-roster
custodian, offline signer, rights/takedown owner and alert/on-call recipient. A role
assignment in this document is not acceptance by that person.

1. Record the exact candidate Git SHA, artifact digest, current production Worker
   version, approved origin/project and expected schema ledger. Provision a distinct
   real staging Worker/D1/private R2 only after approval; never substitute production
   IDs into the local harness or share production credentials/content.
2. Rehearse all ten migrations and current Worker on empty and representative
   rights-cleared staging data, then complete live Owner/two-Collector privacy,
   revocation, images, conflict and anonymous publication checks from T46. Capture
   rollback/restore evidence and budget/alert triggers before proposing production.
3. Present `0009`/`0010` as an explicit reviewed schema delta. Approve the backup or
   Time Travel checkpoint strategy, writer pause/recovery policy and compatibility
   of both candidate and rollback Worker. No down migration is assumed.
4. A separately approved production operation records pre/post deployment IDs,
   ledger and smoke results. Stop on mismatch; do not let a successful static Studio
   push trigger code/schema/data rollout. Nothing in this audit executes this step.
5. For rollback, select a validated prior Worker compatible with the current schema.
   Worker rollback cannot undo D1/R2. Prefer a reviewed forward data repair or restore
   into an isolated replacement before rebinding; preserve post-checkpoint writes,
   immutable R2 generations, trusted public keys and durable deletion evidence.
   Re-publishing old validated content requires a new higher revision and separate
   rights/operator approval. Never decrement revision pointers or purge the bucket.

## Capture hashes

Logs were sanitized to redact deployment-author email metadata before hashing;
they contain no retrieved secret values or allowlist rows. `/tmp` logs are session
artifacts; the results above and hashes below are the durable audit summary.

| `/tmp/t48/backend/` artifact | SHA-256 |
| --- | --- |
| `deployments.log` | `58a0badcf46ceb37b55df8a2202b1144ba8f5fa9eb9da9c6c27e11a90c362c25` |
| `migrations.log` | `03c0b0af4ae71ca2a14703fccf9c38b947d8a9b5d5e451e397cf08ce64b661c4` |
| `d1-ledger.log` | `7b2cbaea400864d0f52c5843fd29145db2f239135065806d115355d1203a0881` |
| `content-counts.log` | `37408a17f7d7702d2ce5fd951e997d5abc8b2229bbac154059f66444ed17a90b` |
| `version-metadata.json` | `31b0a7edcba0abfe38ded5743777d0daf5d15759170da3cd99ec7cab462667d6` |
| `secret-names.log` | `3023d811c17fd139c84c4ef5342f53bdc48629727f746adb728fd11610f1c7df` |
| `r2-dev-url.log` | `718d75327eaba1a2ccbc4c0d0e33df11105a3480d57f24315841d70b533fe4ed` |
| `r2-domains.log` | `85e5389cc4d3099b7979519f0d68b880a489a254cf8bffa1a5239b7e457d5186` |
| `r2-lifecycle.log` | `c0a44f9422c438633ded7447586ef6a42b1d545f4ec4501713906942fe8980a9` |
| `r2-info.log` | `25bb03c3f5847f0edd57d648ae7573b347124c4c6009fcfe1ff3f14bc2888302` |
| `time-travel.log` | `f2290dfdb1ae2e02436855463b5501aa0698054b3a1cae43a8d6f1f5d3dcd2a0` |
| `live-readonly.json` | `d414e1428bec20d0bfdb85f3b8c5c9615db74a92f9b4901fa43a54280ca83626` |
| `staging-deployments.log` | `b79f036d70a8082eb7a5b35ffbf78407979a90fb5699c85d2e03330bdebd39ed` |
| `staging-r2-info.log` | `c9097aff0043479ba729f5f74b68da4906bb24f89d1cd68a2baff833543c7f54` |
| `r2-cors.log` | `1c02d36af02adeae2cd2bf9db50455d9b6d8e3f46a48a6ce10ae048f8724eb8c` |
