# T48 — existing Studio hosting and independently approved backend rollout

**Status: AUDITED / NO-GO for a new production rollout. Owner approval pending.**

Audit date: 2026-11-12. Repository baseline: `6c8115e`, application version
`1.534.143`. This document is a reviewable plan, not authorization or a record of
deployment. T46 remains NOT PASSED; T47 remains closed. Unrelated `TODO.md` work
is preserved. No deployment, migration, secret provisioning, administrative
content mutation, publication, Mobile release or production rollback was performed
for T48. An ordinary public catalog GET can create/reuse D1 pagination snapshot
bookkeeping, even for an empty catalog; that availability probe was exercised,
and its actual row delta was not measured. No bookkeeping was removed afterward.

## Current installation and evidence

Studio already exists at **https://studio.saoudi.online** on the existing
`biguess-studio` Pages project. Keep its domain, DNS and push-to-deploy workflow.
Do not create a replacement site or make static releases depend on a backend
release. Automatic static releases remain eligible only for verified current
`main` changes in `studio/**` or the Studio workflow; failed checks skip deploy.

The Content Backend was separately authorized and connected on 2026-11-11.
It is not merely an undeployed scaffold. Production targets the dedicated
`biguess-content-production` Worker, D1 and private R2 bucket through
`backend/content-api/wrangler.production.json`. Historical scaffold/backend-off
sections in older READMEs do not describe this installation.

| Surface | Current result | Evidence |
| --- | --- | --- |
| Pages domain, HTTPS, anonymous login, exact API/auth CSP and caching | PASS within audited scope; custom domain active, public login served, private responses not statically cached | [Hosting audit](T48-HOSTING-AUDIT.md) |
| Approved-main static deploy separation | PASS for workflow/environment scope; actual token least privilege and expiry not verifiable from encrypted-secret metadata | Hosting audit; `.github/workflows/studio-web-deploy.yml` |
| Current Studio release | `66051ccfa`, retained after newer checks failed; current-main features are not all live | Hosting audit; [T46 deployment evidence](T46-DEPLOYMENT-EVIDENCE.md) |
| Preview access | Public static aliases/deployment URLs are reachable; private API rejects their browser origins. Cloudflare Access policy readback unavailable, so no private-preview claim | Hosting audit |
| Firebase domain/provider configuration | Project `biguess-firebase`; Google enabled; canonical Studio domain present. Loopback and project helper domains also present; rationale/retention requires Owner review | [Auth/privacy audit](T48-AUTH-PRIVACY-AUDIT.md) |
| Anonymous/forged private calls and hostile origins | PASS live denials; legitimate Owner/two-Collector sessions and revocation propagation not exercised live | Auth/privacy and backend audits |
| Production Worker/schema | Worker version `4f9c63ae-6834-4835-af5f-1092eada9746`; migrations 0001–0008 applied; **0009 and 0010 pending** | [Backend audit](T48-BACKEND-AUDIT.md) |
| R2 access | `r2.dev` disabled, no public custom domains; private Worker access retained | Backend audit; metadata readback is not a restore drill |
| Publication provisioning | Only Studio identity secret names observed; no publication keys/operator token listed on the API Worker. Separate operator remains unconfigured in source | Backend audit; `operator.wrangler.json` |
| Remote staging | Source still has placeholder database IDs/local bindings; named staging Worker and R2 bucket are absent in the audited account. A dry-run build is not remote staging | Backend audit |
| Backups, restore, usage alerts | D1 Time Travel bookmark readable; captured backup, paired R2 recovery, restore drill, retention and alert delivery evidence missing | Backend audit |
| Source/public artifacts and secrets | Audited marker scans pass; public Firebase client configuration is intentional. No secret material introduced by T48 | Hosting/auth audits; scan scope is documented |
| Mobile boundary | Source keeps app signing/distribution separate from Pack signing; gameplay uses local snapshots. Physical Android/native release proof remains open | T45/T46 reports; source review below |

## Owners and approval record

The documented Project Owner is the repository owner `AbderrahmaneSAOUDI`.
That identifies the approver; it does not establish that every operational duty
has been accepted. The allocation below is **proposed, not a confirmed assignment**.
One person may hold several roles after explicitly accepting them.

| Accountability | Proposed accountable owner | Required named operator / proof | Status |
| --- | --- | --- | --- |
| Studio domain, Pages and GitHub deploy credential | Project Owner | Frontend operator; attest Pages-only token policy, expiry/rotation and emergency rollback access | Pending |
| Firebase domains, allowlist/role changes and revocation | Project Owner | Identity administrator; two test Collectors plus Owner and documented revocation response | Pending |
| Worker/D1/R2 staging and production changes | Project Owner | Backend operator; exact resource IDs, schema/code compatibility and approved change record | Pending |
| Backup custody, restore and incident response | Project Owner | Backup/incident operator and alternate; encrypted external backup reference and successful restore drill | Pending |
| Usage, budgets and alerts | Project Owner | Billing/operations operator; approved limits, alert destination and delivered test notification | Pending |
| Content clearance, takedowns and publication approval | Project Owner | Rights reviewer; evidence per Pack/Card, contact/channel, response and retention policy | Pending |
| Ed25519 signing and publication service credential | Project Owner | Key custodian and publication operator; custody/recovery/rotation evidence | Pending |
| Android signing, Play/APK/Shorebird distribution | Project Owner | Mobile release custodian; separate approved release and physical-device evidence | Pending |

Approval must identify the exact stage, Git SHA, build/artifact hashes, resource
IDs, migration filenames/checksums, backup/bookmark references, rollback target,
operators, validity window and excluded actions. Record the Owner's explicit
response with a durable review/change reference. A checklist, this commit, a
passing test, a previous November 11 approval or silence grants no new authority.
Approval of this runbook's approach is separate from approval to execute a
particular cloud change.

| Change | Approval and readiness now | Explicit exclusions |
| --- | --- | --- |
| Existing static frontend releases | Existing main push policy continues after successful checks | No backend/D1/R2 changes, operator service, signing keys or Mobile artifacts |
| Isolated remote staging rehearsal | **Not approved; resources/operator/backup inputs unresolved** | No production bindings, production identity copy, legacy import or public release |
| Production API and schema promotion | **Not approved; NO-GO** | No secret/role broadening, publication enablement or source import implied |
| Publication service and trusted key provisioning | **Not approved; separate security/custody review** | No private signing key in API/Studio/GitHub Pages or application bundle |
| Individual Pack release | **Not approved; per-Pack rights/artifact/revision review required** | No uncleared Anime/Flags or arbitrary Collector attribution |
| Android binary or OTA release | **Not approved; outside this rollout** | Backend/Pack approval cannot ship an app binary or change mandatory-upgrade policy |

## Stage 0 — close readiness gaps without changing production

1. Resolve the T46 broad Studio harness's missing incremental-feed fixture route,
   hosted backend Pillow dependency and strict popup/COOP failure. Run the later
   browser assertions previously skipped. Preserve fail-closed CI deployment;
   do not weaken checks to get a release through.
2. Complete live two-Collector/Owner isolation, guessed-ID and role/scope-change
   checks with authorized test identities. Test Worker allowlist revocation and
   Firebase administrative revocation separately. Complete required T46 physical
   Android, existing-Card/image Mobile delta and rollback evidence before
   certifying the integrated production content path. Staging rehearsal can
   supply missing evidence; it does not require pretending T46 already passed.
3. Confirm the owner/operator table, account plan, resource ownership, backup
   retention, acceptable recovery point/time and incident contacts. None of these
   operational targets is assumed approved or measured by this audit.
4. Review the current public preview policy, main/environment review policy and
   actual CI token permissions. Public login shells are distinct from private
   administrative content. Keep preview origins out of production private CORS;
   decide whether public inert previews are intended. Do not infer Cloudflare
   Access protection from an unreadable policy endpoint.
5. Freeze a candidate SHA and compare current schema, code, contract and frontend
   versions. The pending candidate migrations are `0009_studio_profile.sql`
   (audit index) and `0010_legacy_quarantine.sql` (private import fences/triggers).
   Re-read the live ledger immediately before any approved change; never assume
   these remain the complete pending set. Do not replay raw migration SQL or
   edit already-applied files. Inspect older-Worker compatibility with new
   triggers before choosing a rollback version.

## Stage 1 — independently approved isolated staging rehearsal

Prepare a change record with real staging Worker/D1/R2 IDs and a separately
reviewed config. Keep current local bindings untouched. Source placeholder
`staging` IDs must never be used as a runnable remote deployment target. Use
Firebase project `biguess-firebase` and a distinct server-managed staging test
allowlist after identity-owner approval; do not copy production privileged UIDs
or bootstrap defaults. Define the staging browser origin explicitly, or keep
browser access closed. No wildcard or suffix origin rule is acceptable.

After the Owner approves that exact staging record:

1. Capture pre-change code version, D1 ledger/bookmark and a secure consistent
   database export; inventory and preserve referenced R2 generations/objects.
   Store private backups encrypted outside Git/Pages, with checksums, custody
   and a recorded retention window. A Time Travel bookmark alone is not an
   independent export or an R2 backup.
2. Restore into disposable isolated resources and validate schema, counts,
   relationships, immutable audit/rights records, object hashes and signed Pack
   receipts. Record duration and recovery point against Owner-approved targets.
   Test a deliberate staging-only failure and verify the old playable revision
   remains usable. Never restore over production for a rehearsal.
3. Inspect an explicit-config dry-run bundle. Apply only the approved numbered
   staging migrations and deploy that reviewed Worker artifact manually. Record
   the actual version ID, migration ledger and exact D1/R2 bindings. `/health`
   is only process liveness; test authenticated scope, reads/mutations and
   storage readiness as well. `/__fixture` must remain unavailable remotely.
4. Re-run the authorization, browser, signed full/delta, tombstone and offline
   matrices with generated rights-cleared fixtures only. Use independent test
   signing keys only in the approved staging trust configuration. Keep the
   publication service separate and unprovisioned unless specifically included
   in the staging approval. No raw bucket/public object proxy is permitted.
5. Measure actual Worker/D1/R2 request/CPU/memory/storage behavior for the
   intended Pack size. Current publication reads revalidate/buffer complete
   artifacts and are not proven scalable by small fixture tests. Set budget and
   error/latency/quota thresholds from those measurements; deliver a test alert
   to the named incident operator without including tokens or contributor data.
6. Rehearse compatible code rollback and separate data/R2 recovery. Keep the
   resulting evidence, resource/artifact hashes and outstanding failures in the
   change record. Any failure stops promotion.

## Stage 2 — new explicit production API/schema approval

Do not execute this stage until staging evidence, T46 production-content
readiness, backup recovery, identity policy and owner/operator signoffs pass.
The Owner must approve the exact production change record, not just the plan.
Existing production remains as observed until that approval; audit findings do
not authorize disabling or silently upgrading it.

The approved record must distinguish code deployment from D1 migration and from
secret changes. Before migration, stop/drain writers under an approved
maintenance procedure, capture a new backup/bookmark and preserve all required
R2 bytes. Ensure any concurrent Studio client cannot write through the migration
window. Apply the reviewed compatible schema changes, deploy the inspected
artifact with the explicit production config, then perform scoped read/write
smokes and verify audit reconciliation before reopening writers. Do not seed
production, import the 1174 quarantined sources, enable the operator, add trust
keys or publish a fixture as a side effect.

The commands below identify the intended operator tools; placeholders make them
**non-executable approval templates**, not instructions to run during this audit:

```text
wrangler d1 export DB --config <approved-config> --remote --output <secure-backup>
wrangler d1 time-travel info DB --config <approved-config>
wrangler deploy --config <approved-config> --dry-run --outdir <review-directory>
wrangler d1 migrations apply DB --config <approved-config> --remote
wrangler deploy --config <approved-config>
wrangler rollback <approved-compatible-version> --config <approved-config>
```

Verify the pinned CLI help/version and approved resource IDs first. Remote
exports contain private data even though they do not change database records;
their capture/storage also belongs to the approved backup operation. Never
paste secret values into shell arguments, logs, this runbook or a review.

## Rollback, incident, rights and retention

Frontend rollback selects a prior successful production Pages deployment on the
existing project, checks `/release.json`, HTTPS and protected routes, and fixes
or pauses subsequent Studio pushes before normal service resumes. This neither
changes DNS nor rolls back a Worker, D1 schema or R2 objects. Historical frontend
rollback evidence exists; a new rehearsal was not run for T48.

Backend code rollback requires a recorded compatible version and schema. It
does **not** reverse migrations or restore deleted objects. For data failure,
freeze writers, preserve the failed state, restore a reviewed backup to new
isolated resources, verify audit/rights/relationships/hashes, then separately
approve rebinding a compatible Worker. Do not wipe the live database or bucket,
reuse lower content revisions, erase newer audit/tombstone authority or remove
retained signing keys merely to undo a deployment. Prefer a tested forward
repair where a historical restore would lose valid writes.

For identity incidents, remove both any bootstrap Owner UID binding and matching
allowlist entry where applicable. Worker allowlist/role policy is authoritative
on each request. Current JWT verification does not query Firebase's per-user
revocation/disabled status: revoking refresh tokens or disabling a Firebase user
alone must not be advertised as immediate backend denial. Agree and test the
revocation response policy before expanding privileges.

Publication remains a separate manual operation: validate explicit per-content
clearance/provenance, immutable source/artifact checksums, exact Pack revision,
Owner rights approval and signed receipt against approved public pins. Keep
Ed25519 private keys offline under named custody; only public verification keys
belong in API/Mobile trust configuration. The API Worker and frontend must not
receive the private signer or independent publication operator credential.
Provisioning a public key is not permission to release any Pack. Preserve old
public verification keys/revisions according to the approved retention policy.

The rights operator must own a takedown channel, verify requests and record the
decision. Hiding/unpublishing and authoritative deletion have different effects;
never erase audit/provenance or infer deletion from a missing catalog entry.
Offline devices and cached public bytes cannot be recalled instantly. Valid
server tombstones are learned only at user-invoked Home sync and applied at safe
boundaries. Do not promise immediate remote erasure of downloaded content.

Browser drafts are scoped application data, not encrypted vaults. Existing
IndexedDB snapshots/queues may survive revocation; same-origin scripts/devtools
in the same browser profile can inspect plaintext. Fresh online authorization
is required for a newly opened offline tab before editing resumes. The privacy
owner must accept/document shared-device retention, sign-out/eviction and
incident handling; browser eviction cannot recover the only local draft copy.
Do not add background forced synchronization as a workaround.

## Mobile signing and content policy remain separate

Android release signing is externally supplied in `android/app/build.gradle.kts`;
release assembly refuses a missing signing configuration instead of silently
using a debug key. Keystores/properties are ignored. Custody, certificate match,
Play/APK/Shorebird distribution and physical-device validation remain a separate
Mobile release approval, not a result of this source audit.

Pack public keys are build-pinned via `BIGUESS_CONTENT_PUBLIC_KEYS` (empty by
default), never learned from an unverified manifest. Public catalog configuration
and Pack trust require their own reviewed application/configuration release.
No current production-compatible Mobile trust set was provisioned by T48.
`shorebird.yaml` has `auto_update: false`; app-update UI is manual/optional and
does not impose remote minimum-version hints. Binary updates, Pack revisions
and server authorization must not become a prerequisite for an installed game.
No network is added between Start and completion; immutable GameSession
snapshots and private images remain the gameplay authority.

## Verification and decision

Fresh T48 root checks: **401 Mobile tests passed**, analysis clean, **962 setup
checks**, **164 automation tests passed**. Hosting packaging: **9 passed**.
[T46](T46-VERIFICATION.md) provides unchanged-product-source evidence of **235
backend**, **288 Studio** and **10 real Chromium IndexedDB** tests plus the
isolated offline process restart, 10 + 3 rounds and zero HTTP clients. Those
local passes are not live Firebase, backup/alert, current deployment or physical
Android signoffs. Evidence fingerprints are in the companion audits and
[T48-HOST-RESULTS.json](T48-HOST-RESULTS.json).

**Decision: do not promote, migrate, provision publication or release content.**
The existing Studio remains live; automatic verified static releases remain
separate. Review this plan, confirm accountable owners and close the recorded
readiness gaps. Then request a new exact staging/production execution approval.

Provider references checked during this audit:
[D1 recovery](https://developers.cloudflare.com/d1/reference/time-travel/),
[R2 public access](https://developers.cloudflare.com/r2/buckets/public-buckets/),
[Firebase sessions/revocation](https://firebase.google.com/docs/auth/admin/manage-sessions),
[Firebase Google domains](https://firebase.google.com/docs/auth/web/google-signin),
[Worker metrics](https://developers.cloudflare.com/workers/observability/metrics-and-analytics/).
D1 recovery retention is account-plan dependent; a documented feature is not
proof of this account's recovery window or a successful restore. Verify actual
plan, retention and operational limits before accepting them.
