# T48 authentication, origin and local privacy audit

Audit using metadata reads and ordinary public GET/OPTIONS on 2026-11-12
(Africa/Algiers), source
`6c8115ea4c1841d83aeee237eb921e30bc8c6198`. No real user was impersonated,
revoked, disabled or granted a role. No administrative mutation, cloud
configuration write, content mutation or deployment was requested. The public
catalog GET may create or reuse D1 pagination bookkeeping as explained below;
actual rows affected were not measured. Only this report is task-owned. Existing T46 local
tests are reused because the relevant application source has not changed.

## Live readback and denied requests

| Check | Result and evidence |
| --- | --- |
| Firebase project | PASS: authenticated read-only Identity Toolkit admin metadata resolves `biguess-firebase` to project `230843736734`. |
| Google identity provider | PASS: `defaultSupportedIdpConfigs/google.com` returns enabled. No OAuth client secret or account details were logged. |
| Authorized domains | Exact live list: `biguess-firebase.firebaseapp.com`, `biguess-firebase.web.app`, `studio.saoudi.online`, `localhost`, `127.0.0.1`. No wildcard domain appeared. |
| Production frontend identity/API configuration | Served release is still `66051ccfaeded38b8ffab4b744ed551f19aff3bb`, older than audited main. Its public bundle contains the selected project, `biguess-firebase.firebaseapp.com` helper and `https://biguess-content-production.biguess-api.workers.dev`. It lacks the newer **Commit queued changes** string. Source-main verification does not establish deployment of that newer UI. |
| Served CSP and origin separation | PASS for readback: `connect-src` names self, Google's identity/token/loader endpoints, the exact selected Firebase helper origin and exact production Worker origin. `frame-src` names only that Firebase helper. `object-src 'none'`, `base-uri 'self'`, `frame-ancestors 'none'`, HSTS and DENY framing are present. This does not certify every Google popup/redirect path. |
| Anonymous private requests | PASS: GET session in both `/studio/v1` and `/content/v1/studio`, Pack list, guessed nonexistent Pack ID, Cards, initial sync, profile and contributors all return 401 `unauthenticated`, `Cache-Control: no-store`. No private records were returned. |
| Forged token | PASS: a deliberately invalid bearer at the approved origin returns 401, no private data. No real token was supplied to these probes. |
| Hostile origin | PASS: `https://evil.invalid`, `https://studio.saoudi.online.evil.invalid` and literal `null` Origin return 403 without `Access-Control-Allow-Origin`. |
| Actual preflight | Approved Studio Origin plus GET/authorization returns 204, exact allow-origin and no credential-sharing header; hostile-origin preflight returns 403. |
| Anonymous public catalog | `/content/v1/catalog/topics` returns 200 with zero published summaries, wildcard public CORS and public revalidation. `/content/v1/catalog/packs` without required `topicId` correctly returns 400. The nonexistent `/content/v1/catalog` returns 404. No public identity or Studio ownership fields appeared. These production responses do not prove a published fixture's full download path. |

Read-only endpoints used for project metadata were
`GET https://identitytoolkit.googleapis.com/admin/v2/projects/biguess-firebase/config`
and `GET .../defaultSupportedIdpConfigs/google.com`, using the existing Firebase
CLI session in memory. Only domain/project/provider-enabled fields were retained.
Bearer/refresh tokens and OAuth client secrets were never printed or written to
audit artifacts. Public HTTPS GET/OPTIONS probes targeted the configured Worker;
they made no authenticated content mutations.

The anonymous first-page topics GET is not guaranteed to be database-read-only:
`backend/content-api/src/catalog.ts` executes `INSERT OR IGNORE` into
`catalog_snapshots`, including for an empty catalog. This request may therefore
have created or reused a pagination snapshot row. The number of affected rows was
not measured; no additional database query or cleanup was performed. This is
ordinary catalog bookkeeping, not an administrative content/publication operation.

## Server-side authority verified in source and T46 fixtures

`backend/content-api/src/studio-auth.ts` uses a fixed Google JWKS URL, RS256,
the configured project's exact issuer/audience, required timestamps, verified
email and Google sign-in provider. Roles come from a server-managed exact
UID/email allowlist or the separately server-pinned Owner identity. Client
role/custom claims, headers, attribution and reused email alone cannot elevate
an identity. All private routing passes through authentication, including the
legacy content-prefixed alias. An absent Origin may reach authentication for
nonbrowser clients; CORS is not an authentication substitute.

`studio-cors.ts` uses exact, parsed origin equality with no wildcard/suffix match;
HTTPS is required outside loopback development. Production Wrangler configuration
names only `https://studio.saoudi.online`. Live denials above agree with that
policy, but do not expose or read the deployed role-secret contents.

`studio-reads.ts` filters Collector records by stored parent-Pack ownership,
excludes quarantined legacy records and removes administrative attribution from
Collector projections. `studio-scope.ts` rechecks Pack/Card ownership, parent and
state for writes and requires a trusted per-Pack image binding. Owner-only
publishing, deletion/restore/purge and contributor administration remain server
decisions. `studio-profile.ts` derives counts from immutable audit operations;
Collector queries bind the actor UID, reject contributor selection and omit the
Owner roster. Public catalog SQL serves only published, nondeleted parent/content
summaries.

[T46 backend evidence](T46-BACKEND-EVIDENCE.md) records **235 passing local
Workerd/D1/R2 tests**, including two Collectors plus Owner, guessed-ID/IDOR,
token/claim validation, allowlist removal, cross-account cursors, upload/publication
authorization and private/public separation. These are synthetic signed identities,
not live production users. [T46 Studio evidence](T46-STUDIO-EVIDENCE.md) records
**288 passing Studio tests**, **10 real Chromium IndexedDB tests**, focused sync,
profile and cross-origin ingestion browser passes, plus the unresolved broad
dataset browser failure. No long suites were rerun for this source audit.

## Local storage and account-switch boundary

`FirebaseIdentity.restore()` selects Firebase `Persistence.SESSION`, rather than
persistent cross-session identity. `StudioSession` validates restoration and
identity changes with the Worker; the rendered shell is gated by the authorized
principal or a previously completed same-account offline workspace. Account switch
signs out first; another explicit gesture starts Google sign-in. Outstanding
requests/results use generation and identity checks rather than adopting a changed
account's token.

`DatasetScope` namespaces project, UID and authoritative role. IndexedDB requires
the matching account receipt and snapshot namespace; role changes attach another
scope. Transaction CAS protects independently stale tabs. Detach closes handles,
aborts pending transactions and clears rendered state. Reconnect denial deletes
the local access receipt and blocks later offline reopening. Dataset snapshots,
prepared images and pending drafts contain no persisted bearer token. The public
service worker admits only exact static release files and excludes private API,
authorization-bearing, query-string, private/no-store and unrelated responses.

Offline trust has explicit limits. The same-tab readiness marker lives in
sessionStorage in addition to the IndexedDB receipt and restored identity. Closing
the tab loses that marker; a new offline tab cannot resume editing. T46's actual
tab-close harness verifies denial, then fresh online authorization and recovery of
the original draft/queue without a POST. Same-tab offline reload can recover while
its identity/readiness and site storage survive. Eviction or cleared/corrupt data
fails closed and can permanently lose the only copy of an unsent draft. Revocation
cannot be learned while disconnected.

Local datasets/drafts are ordinary plaintext IndexedDB data, not encrypted per
account. `IndexedDbDatasetStore.revoke()` deletes the account receipt while
intentionally retaining snapshots and queued drafts. Application namespace/render
isolation is verified; secure erasure, protection from DevTools or malicious code
already running in the same origin/browser profile is not provided. Do not describe
sign-out as deleting all private local bytes or as separate OS-user protection.

## Unresolved decisions and Owner signoff

1. **Firebase token revocation semantics:** Worker authentication does not query
   Firebase revoked/disabled-user status or compare a per-user revocation epoch.
   Signature/expiry validation and removal of the Worker allowlist entry are
   enforced. An otherwise-valid issued ID token can remain acceptable until its
   expiry after Firebase-only refresh-token revocation/account disable if its
   Worker entry remains. T46's allowlist-removal test does not prove immediate
   Firebase revocation. The Owner must explicitly accept/document that bound or
   approve a separate implementation and live test of immediate revocation.
2. **Local retention/shared-device policy:** Owner acceptance is needed for
   plaintext draft retention across sign-out and the requirement to reconnect
   after actual tab closure. A separate approved removal/export/backup policy is
   needed if stronger local privacy or draft durability is required. No new policy
   or destructive cleanup was introduced by this audit.
3. **Production domain scope:** `localhost` and `127.0.0.1` remain authorized in
   the selected Firebase project. Confirm whether the production project should
   retain those development origins; this audit did not remove them. Firebase
   authorized domains do not grant Studio access without the Worker allowlist.
4. **Live role/privacy matrix:** No real Owner/Collector sign-in, account disable,
   allowlist removal, Google redirect completion, role change or privileged browser
   workflow was performed. Those need named test accounts, an approved procedure
   and restoration plan; they cannot be inferred from anonymous denials.
5. **Current production frontend:** Repair/verify the failing broad dataset/hosted
   CI gates before claiming current-main production behavior. T46 also records a
   strict Google-popup smoke failure from COOP console messages. Authenticated
   production/browser-engine coverage is not cleared by the matching CSP alone.

These are explicit limits, not approval to enable more private access or publish
content. This audit does not clear T46, T47 legacy retirement or production release.

## Sanitized evidence

Run-local evidence is under `/tmp/t48/auth/`; it contains selected metadata/status
summaries, not real identity credentials or private content. Fingerprints below
identify this run. Live cloud values can change after the audit.

```text
9ee38edc4b03652d126f532c5515712b5d13d491110cf5d4830dc7fbc9fd8694  firebase-readback.json
1fda91bc728fd7a8cef9389ec8b30c2e436a6445b5851efd5f973b5cb5d76681  frontend-release.json
901a48093635538c9fa104744feb3250dad21bcbdb32156145fccbe78423cc13  frontend-headers.txt
7d1ae9018901b19459959c0ac3faccd67398898a81b435fc49f8024051b02fa0  frontend-sanitized.json
0df2e134c43c98203cf92e01d6f2bd3c6e5d6d35d88bcb2261e863db9f2fcd85  public-probes.json
485157192d9b87bcc690f6ab2afb587f813b201c697d9e45b873c24952b3ffb3  catalog-probes.json
```
