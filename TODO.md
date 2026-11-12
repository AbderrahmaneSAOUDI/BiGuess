# BiGuess — Ordered Coding-Agent Implementation Roadmap

**Prepared:** 2026-11-05  
**Repository:** https://github.com/AbderrahmaneSAOUDI/BiGuess  
**Audited branch / HEAD:** `main` at `d4ab660faacd1c4f923278456b29f58755ae7040` (2026-09-26)  
**Requirements baseline:** the supplied `BIGUESS_PRODUCT_BLUEPRINT.md` (10,154 lines), especially **Game Model**, **Content System**, **Technical Architecture**, **BiGuess Content Studio**, **Distribution & Updates**, **MVP**, and **Migration Plan From Current BiGuess**. The same-named file is also present in the repository.

## How to use this file

**Current status:** Phases A and B have implementations in the live tree. The [Phase A/B review](docs/migration/PHASE_AB_REVIEW.md) records follow-up fixes and verification. Completed tickets and the historical starting audit are archived in [TODO - Done Tasks.md](TODO%20-%20Done%20Tasks.md). Read the current [source map](.agents/sidecars/file-map.md) for navigation.

Give your coding agent **one numbered ticket at a time**, in ascending order. Each ticket should normally yield one small, reviewable PR. Confirm the acceptance criteria and merge before giving the next ticket. Tickets marked **GATE** require explicit acceptance before continuing.

**Architectural Workstreams Alignment:**
The updated `BIGUESS_PRODUCT_BLUEPRINT.md` establishes that BiGuess consists of **three parallel workstreams with explicit dependencies**:
* **Workstream A (Mobile App):** Local Game Engine, game configuration, local content storage, offline gameplay, discovery/download manager, and safe non-interrupting synchronization.
* **Workstream B (Content Studio):** Google/Firebase authentication, role permissions, Topic/Pack/Card management, bulk image import & normalization, automated validation rules, and publishing.
* **Workstream C (Content Backend):** Shared models, D1 database & migrations, Workers API contracts, R2 image bucket, catalog distribution, incremental sync, and deletion tombstone propagation.

While this roadmap organizes execution serially for a single-agent workflow, this ticket order is an execution strategy rather than a hard technical lock-step dependency. In team environments, Workstream A (Mobile), Workstream B (Studio), and Workstream C (Backend) can proceed in parallel once shared contracts (T06/T19) are established. All ticket contracts and milestones strictly preserve this inter-workstream dependency structure: shared contracts (T06/T19) are agreed upon early; backend foundations (T20–T25) support both Studio and Mobile; Studio (T26–T38) produces and validates real content in parallel; and Mobile (T39–T45) integrates remote distribution without blocking local gameplay development.

**Universal agent contract (prepend to every ticket):**

> Read `BIGUESS_PRODUCT_BLUEPRINT.md` and inspect the current code relevant to this ticket. Implement **only the requested ticket**; do not rewrite unrelated systems, expand MVP scope, or silently reinterpret requirements. Preserve a playable app and migration rollback path. Use the current default branch as your base, not the old audited SHA if the branch has advanced. Add or update automated tests. Run the relevant checks (`flutter analyze`, `flutter test`, asset audit / backend tests as appropriate), report what actually ran and any failures, and provide the changed-file list, behavioral changes, migration impact, and PR/commit reference. Avoid speculative abstractions. Do not publish third-party content or run destructive cloud operations without explicit approval. If a ticket depends on a product/legal decision, document the blocker rather than inventing a decision.

**Quality gates:** `flutter analyze` and `flutter test` must pass when Flutter changes are made, or failures must be identified as baseline failures and resolved in an agreed follow-up. Backend and Studio work needs its own automated tests and local build checks. All new migrations/imports must be idempotent or safely retryable, and new content must be validated before activation. Never hardcode production secrets.

# PHASE D — BiGuess Studio (separate Flutter Web app; trusted contributors only)

## Forward-only implementation decisions (effective for T26 onward, 2026-11-07)

**Preservation rule:** T01–T25 and their historical implementation/evidence text are completed records; do not reopen or rewrite those tickets. The requirements below apply to unfinished work. Where they require changes to existing backend code, implement the changes in a new pending ticket and migration, not by retroactively changing a completed ticket's description.

- **Platform, repository, and early custom domain:** Studio is a **separate Flutter Web application** under `studio/` inside the existing BiGuess monorepo; the existing Android BiGuess Mobile app remains at the repository root. Studio is an authenticated, responsive website for desktop, tablet, and mobile browsers, with **`https://studio.saoudi.online` as the early public website address**. T26 builds the scaffold locally, then **T26A immediately creates the static hosting and push-to-deploy pipeline**, before authentication or content features. Once the owner completes the one-time Cloudflare/DNS/GitHub-secret setup, successful Studio-related pushes to the protected `main` branch automatically update this website. Pull requests/feature branches must not overwrite production. The website can initially show only an inert public scaffold; it does not expose private content or imply the backend is deployed. Studio has independent web routing, browser-compatible local persistence, tests, build scripts, and scoped CI. No Android Studio app, package ID, APK, or Play Store listing is required. Share only stable content contracts/models that truly benefit both apps; do not share UI, session state, secrets, or provider-specific implementation indiscriminately. Keep coding-agent context limited to the current ticket's files.
- **Frontend hosting versus backend deployment:** Host **only the static Flutter Web Studio frontend** early at `https://studio.saoudi.online` using Cloudflare Pages and a dedicated scoped GitHub Actions deploy workflow. This is separate from the Content Backend: retain one logical Cloudflare Workers API + D1 metadata store + private R2 object store **per environment**. Firebase Authentication identifies Studio users; it is neither the content database nor player authentication. T20–T25 are local backend foundations, **not** a deployed production API. Use local Worker/D1/R2 emulation and fixtures until later staged end-to-end work; production backend/API, D1 migrations, R2 and publishing remain blocked on explicit later release approval. Never put API tokens, publication signing keys, service-account secrets or R2 write credentials in the repository or browser bundle. T26A does **not** deploy backend code or data.
- **Roles, visibility, and ownership:** The Owner Admin can view and administer all content. A Data Collector may view and modify only **their own Studio contributions**, modeled for MVP as Packs created by that collector and Cards contained in those Packs. Collectors may read the minimal shared Topic taxonomy necessary to place their own Packs; they cannot browse other collectors' private Packs/Cards or their administrative/audit data. The Worker must derive collector UID and ownership from verified Firebase identity/server records, assign ownership on creation, and enforce scope on **all reads, mutations, bulk operations, search, uploads and synchronization**. Never trust owner IDs, roles, or filters submitted by Studio. The initial MVP does not implement shared Pack editing or ownership transfer; any future assignment/delegation requires a separate approved contract. An Owner can administer legacy/imported or otherwise unassigned content without leaking it to Collectors. Preserve creator attribution separately from the canonical Card product fields.
- **Auth, early public scaffold, and origins:** The early website is public, but it must **initially expose only a nonfunctional scaffold or maintenance page**: no actual private content, credentials, working administrative controls or unauthenticated data calls. A publicly reachable Studio URL does **not** grant administrative access. In T27, a user may authenticate through Google/Firebase yet still be denied by the Worker; only allowlisted Owner/Collector accounts may read/edit Studio data. Register `studio.saoudi.online` as a Firebase authorized domain when Firebase Auth is configured in T27 and configure the Worker's precise Studio CORS allowlist **before** enabling real administrative API traffic. HTTPS/TLS and DNS belong to T26A, not T48. Do not mistake UI route guards or a public web bundle for server-side authorization. Players remain accountless.
- **Studio browser-local workflow:** After online authorization, each account's permitted working dataset and pending draft edits use **account-isolated, browser-compatible persistent storage** (e.g., IndexedDB), with versioning and recovery. Editing previously synchronized data may work offline; browser storage is **best effort**, not guaranteed against private-browsing limits, browser eviction, site-data clearing, or device changes. Edits are explicitly **Committed** and **Refresh** is manual with revision/conflict handling; no per-keystroke writes, background polling, or realtime collaboration. Prevent data leaks on account switch/sign-out; do not expose private records through public HTTP caches, service-worker caches, logs, or browser history. An offline browser cannot discover immediate server revocation until it reconnects; block server operations until reauthorization.
- **Player updates:** Mobile downloads a verified Pack and plays entirely from its locally installed snapshot. No Pack update checks or automatic replacement during gameplay. On returning to Home, the player may explicitly check for and install available Pack updates; unchanged content is retained. Treat **authoritative cloud-deletion tombstones** separately: apply them only after a valid synchronization and at a safe Home/exit boundary, never mid-round. Remote deletion cannot retroactively reclaim previously distributed/offline copies. App/APK updates are a separate policy from Pack-content updates.
- **Compatibility gate:** T19 froze the public `/content/v1` wire contract; T23/T24 added authorization and batch mutations but not the complete collector-scoped administrative reads or image-upload workflow. New requirements must use additive/migrated persistence and explicitly versioned or contract-compatible Studio endpoints, retaining public v1 and existing local-game behavior. Do not silently broaden T24 permissions or reinterpret an Owner-only operation as Collector-accessible. Keep all source assets with uncertain rights unpublished and quarantined.

**Recommended execution order for one coding agent:** T26 → **T26A (early static site + custom domain + GitHub push-to-deploy gate)** → T27 → T27A → T27B → T28 → T29 → T30 → T31 → T32 → T32A → T33 → T34 → T35 → T36 → T37 → T38 → T39–T49. Each named ticket is a separate reviewable PR unless the acceptance gate explicitly approves a smaller follow-up. Work on current `main`; do not change completed-ticket text. Treat added lettered tickets as *new work*, not rework of T19–T25.

### [x] T35 — GATE: Implement deliberate publishing, rights approval, and validated release integration
**Agent task:** Add preview/review/validate/publish/unpublish for Topics and Packs. Initial publication requires Owner approval; Collectors may maintain already published **owned** Packs only within T24 permissions and through automated validation before a newly public revision is distributed. Packs require >=2 eligible Cards, complete verified images and rights approval. Integrate with T22's existing **trusted internal publisher** through a separately reviewed, authenticated privileged workflow/operator service; never embed signing keys in Studio or expose an unrestricted public publish endpoint. Keep unverified Anime/Flags as nonpublic drafts. No independent Card publishing.
**Acceptance:** Tests prove unauthorized/out-of-scope/invalid/rights-unapproved content cannot publish; trusted signed immutable revisions appear atomically in anonymous catalog, previous revisions remain recoverable, and routine eligible edits are validated rather than silently released.
**Implementation evidence:** [T35 local verification](backend/content-api/T35-VERIFICATION.md) and [operator workflow/runbook](backend/content-api/PUBLICATION-REVIEW.md). Deployment, remote migrations, operator provisioning and real content publication remain separately gated; public v1 still permits cleared-test provenance only.

### [x] T36 — Implement explicit Studio Commit, manual Refresh, and conflict-safe incremental sync
**Agent task:** Connect persisted local pending changes to T24-compatible authenticated batches and T27B scoped change feeds. Provide user-triggered Commit and Refresh only; detect lightweight revisions, fetch changed authorized records without cross-account leakage and retain the last complete good local dataset on failure. Handle 412/409 and role/ownership changes without destructive silent overwrite; serialize uploads/metadata transactions per aggregate. Show clear sync timestamps and errors. Handle concurrent browser tabs as independently stale editors using the existing revision/idempotency rules; prevent silent overwrites. No background polling, realtime listeners or per-keystroke writes.
**Acceptance:** Offline edit → reconnect → explicit Commit → manual Refresh works for each Collector and Owner; unchanged refresh is small; two stale writers do not silently overwrite; revoked/scope-changed users cannot read new data.

**Implementation evidence:** [T36 verification](studio/T36-VERIFICATION.md), including Chromium offline Commit/Refresh for two isolated Collectors and Owner, stale-tab/server-conflict retention and revoked-access checks. Backend deployment and live-account validation remain separate.

### [x] T37 — Add contributor profile, role display, and scoped statistics
**Agent task:** Show signed-in identity, authoritative role and backend-derived contribution counts. Collector views only their own activity and aggregate counts; Owner can view all contributors and administrative records. Stats count validated operations even when content later changes state, without trusting local counters; no public contributor accounts, XP, leaderboards or badges.
**Acceptance:** Two-Collector/Owner authorization tests verify no cross-user activity/statistics leakage; stats reconcile with immutable audit records.

**Implementation evidence:** [T37 verification](studio/T37-VERIFICATION.md) and [profile API contract](contracts/studio/v1/profile.md). Local Workerd/D1 tests reconcile immutable audit counts and enforce actor scope; Chromium verifies two Collectors, Owner filtering, pagination and access changes. No backend deployment or remote migration.

### [x] T38 — GATE: Import legacy content as private Owner-controlled drafts
**Agent task:** Reuse the T05 inventory, stable T06 IDs and T32 pipeline to import the existing 922 Anime and 252 Flags assets **only into quarantined, nonpublic Owner-controlled drafts**, unless individual content is confirmed cleared. Do not assign legacy material to arbitrary Collectors or let it appear in their own-contribution lists without an explicit later approved ownership process. Preserve original files, mappings, provenance, import checksums and rollback report. Only rights-cleared fixtures may be released in a test catalog.
**Acceptance:** All 1174 sources are accounted for or deviations explained; imports are repeatable and owner-scoped; zero uncleared assets can be publicly discovered/downloaded; no production publishing.

**Implementation evidence:** [T38 verification](docs/migration/T38-VERIFICATION.md), [private local operator runbook](backend/content-api/LEGACY-IMPORT.md), and committed source mappings/import/repeat/rollback reports. All 1174 sources were imported into persistent local Owner-only quarantine; no backend deployment, remote migration or production publishing.

# PHASE E — Connect BiGuess Mobile to remote content distribution

### [x] T39 — Add anonymous remote catalog and offline-aware Mobile browsing
**Agent task:** Add a versioned public content catalog repository and cached Topic/Pack summaries to the existing Mobile app. Players never log into Studio or Firebase. Reuse current Topic/Pack visuals; request data only when discovery is needed or the user explicitly refreshes, not on every rebuild/launch. Clearly label locally installed, unavailable and not-downloaded Packs. Maintain a safe offline view and the existing migration fallback until T47.
**Acceptance:** Anonymous public read path works, existing offline Packs remain browsable with backend down, private Studio drafts/ownership data never leak, and no automatic launch network dependency is introduced.

**Implementation evidence:** [T39 verification](docs/migration/T39-VERIFICATION.md). Anonymous v1 summaries use origin-separated atomic caches, explicit discovery/Refresh and a once-only missing-list fetch on Topic navigation. Installed content remains authoritative and playable offline; summary-only Packs cannot enter gameplay. Mobile: 280 tests; Studio: 288 tests; both analyzers clean. Public catalog: 5 tests; agent setup: 962 checks; automation: 163 tests. Endpoint configuration is opt-in; no deployment or downloads.

### [x] T40 — Implement verified complete Pack downloads
**Agent task:** Download only published content from public v1 endpoints; check manifest/receipt trust, hashes, sizes, signatures and pinned keys, then atomically install via existing local Pack store. Include progress, retry, timeout, no-space and corruption states; download is user initiated, not automatic. Avoid writing images to public gallery folders.
**Acceptance:** Cleared fixture Pack survives restart and airplane mode; tampering, untrusted key, offline/error and partial downloads fail without marking Pack playable or destroying its prior revision.

**Implementation evidence:** [T40 verification](docs/migration/T40-VERIFICATION.md). Explicit Download/update actions verify pinned Ed25519 receipts, manifest/archive identity, hashes, sizes and cleared provenance before private atomic installation. Failed downloads retain the prior revision; manual retry, progress, timeout, no-space and corruption states are covered. Signed fixture reopens through SQLite/private images with its server stopped; the host offline gameplay gate passes with zero HTTP clients. Mobile: 298 tests and clean analysis; public publication/download regression: 8 tests; agent setup: 962 checks; automation: 163 tests. Origin and public trust pins remain build configuration; no deployment or production publishing. Physical-device airplane-mode validation remains a separate device gate.

### [x] T41 — Add download concurrency, interruption recovery, and atomic activation
**Agent task:** Keep existing content usable during downloads/updates; limit simultaneous jobs, stage writes in private storage, resume or safely restart interrupted requests, and support cancel/retry. Never mutate a running GameSession snapshot.
**Acceptance:** Kill/restart, storage-full, cancellation and concurrent download tests leave prior installed Packs playable, with bounded temporary-file cleanup.

**Implementation evidence:** [T41 verification](docs/migration/T41-VERIFICATION.md). One active transfer plus three queued requests, same-Pack deduplication, queued/active cancellation and explicit retry from byte zero. Leased private staging and pending-generation recovery reclaim at most eight abandoned entries per pass without touching live transfers or previous activated generations. Linux SIGKILL/restart tests cover partial transfers and precommit generations; storage-full/cancellation/concurrency preserve prior Packs. A successful update refreshes browsing while the running GameSession retains its original snapshot and private images. Mobile: 311 tests and clean analysis; agent setup: 962 checks; automation: 163 tests; offline gameplay gate passes with zero HTTP clients. No automatic launch download, backend deployment or publication; physical-device process-death validation remains a separate gate.

### [x] T42 — Switch Mobile gameplay to verified locally installed content
**Agent task:** Route Topic → Pack → Configuration → every round exclusively through locally installed Packs and private images. Accountless, zero network requests after Start. Enforce Free's 5 downloaded-Pack slots and 10-round per-game limit, with internal Pro QA bypass only; do not introduce public billing. Missing Packs show a clear download choice.
**Acceptance:** Full airplane-mode play across rounds works; Free slot limits and replay/Home reset rules remain correct; service outage cannot block an already installed Pack.

**Implementation evidence:** [T42 verification](docs/migration/T42-VERIFICATION.md). Start reopens cleared private generations instead of trusting cached SQL Cards, cancels/drains earlier content and app-update work, and blocks network actions through completion/Pro replay until Home. Missing/damaged files fail before gameplay; summary-only Packs retain explicit Download actions. Free five-slot/ten-round and release-only-Free rules pass alongside replay/Home tests. Mobile: 323 tests, clean analysis; agent setup: 962 checks; automation: 163 tests. Isolated host process gate passes SIGKILL, archive removal, fresh restart, 10 + 3 rounds, zero HTTP clients and SQLite integrity. Shorebird native automatic launch updates are disabled and configuration-checked; a new approved base binary and physical-device validation remain release/T46 gates. Migration fallback remains until T47; no publication, deployment or Mobile release.

### [x] T43 — Implement optional Home-initiated Pack-update discovery and incremental install
**Agent task:** Put `Check for updates` / `Update` in the **Home / installed-Packs management flow**; do not poll or silently replace Pack content during gameplay, on app startup, or merely on screen rebuild. A player who does not request a refresh keeps the verified installed revision. When requested, compare revisions/ETags, download changed Card metadata/images only, stage atomically and activate after verification for the next game. Clearly distinguish `Update available`, `Up to date` and errors.
**Acceptance:** Manual Home update check is the only ordinary content-update trigger; no network during game; an update from 100 to 105 Cards transfers only deltas; unchanged Packs incur minimal traffic; closing/restarting during update preserves old playable data.

**Implementation evidence:** [T43 verification](docs/migration/T43-VERIFICATION.md). Home management separates explicit Check from Update, with timestamps/statuses/errors; catalog/Pack browsing never activates installed-Pack updates. Anonymous revision checks are small; opt-in compact deltas reconstruct and verify the signed target manifest locally, reusing private images. The 100→105 fixture transfers only five Card/rights changes and five new images, without a full manifest/archive download. Shared transfer exclusion, cancellation, stale-base/atomic-store protection and Start draining preserve installed content and frozen games. Local-only development IDs never enter public checks. Mobile: 344 tests and clean analysis; backend: 235 tests and clean typecheck; automation: 164 tests; setup: 962 checks; OpenAPI 3.1/sibling references pass. The optional backend extension is locally verified and remains undeployed; no production publication or Mobile release. Device/release gates remain separate.

### [x] T44 — Handle authoritative deletions during valid Home synchronization and manage storage
**Agent task:** Separate user `Remove Download` (frees Free storage slot, redownloadable if still published) from server-issued Pack tombstones (no longer valid to redownload). Evaluate tombstones only through valid user-invoked Home/Pack-management synchronization or an explicitly approved future policy. Apply a detected deletion only at a safe Home/exit boundary; never during an active GameSession or by interpreting an absent catalog entry as deletion. Preserve accurate offline behavior and clearly explain that offline devices may retain content until they reconnect and sync.
**Acceptance:** Valid tombstone on Home sync retires installed Pack without mid-round interruption; no forced background sync or server check to start game; user removal is reversible, cloud deletion is respected after sync, and temporary files/storage slots remain consistent.

**Implementation evidence:** [T44 verification](docs/migration/T44-VERIFICATION.md). User Remove Download frees Free storage slots with offline confirmation; server tombstones validate exact Pack ID, revision, administrative reason and UTC timestamp through configured-origin public transport. Manual Home sync applies authoritative deletions at safe boundaries; absent catalog entries, malformed/stale/incomplete results cannot retire content. Bounded storage cleanup reclaims at most eight entries per pass, protecting leased generations and live transfers. Start cancels/drains pending checks; immutable game snapshots retain private images until Home. Mobile: 389 tests and clean analysis; agent setup: 962 checks; automation: 164 tests. Isolated offline process gate passes SIGKILL, source removal, fresh restart, all 10 + 3 rounds, zero HTTP clients and SQLite integrity. No backend change, deployment or production publication.

### [x] T45 — Remove blocking launch-time update checks while keeping app updates separate
**Agent task:** Audit and replace the old startup silent/mandatory update behavior without changing unrelated code prematurely. An installed-Pack player must launch and play offline without forced online validation. App binary/APK/Play Store updates are distinct from manually installed Pack revisions; any mandatory app upgrade requires separate product approval and must not be confused with content synchronization.
**Acceptance:** Offline launch is immediate and gameplay works with verified Packs; no background content update or blocking app-update dialog caused solely by unavailable servers; safe optional app update path is tested.

**Implementation evidence:** [T45 verification](docs/migration/T45-VERIFICATION.md). Launch no longer checks remote app version, downloads patches, or opens mandatory update dialogs. About → App updates is the manual availability check; a separate action downloads/installs an APK or applies a patch. APK downloads require HTTPS and valid publisher SHA-256; cached installer retries rehash before installation. Existing gameplay cancellation/draining guards remain. Mobile: 401 tests and clean analysis; agent setup: 962 checks; automation: 164 tests. Isolated offline process gate passes SIGKILL, source removal, fresh restart, all 10 + 3 rounds, zero HTTP clients and SQLite integrity. No APK/OTA release, backend deployment or production publication.

# PHASE F — Validate, migrate, and prepare controlled release

### [ ] T46 — GATE: Run full Studio authorization, Mobile offline, and sync test matrix
**Agent task:** Verify two isolated Collectors plus Owner (including guessed-ID/IDOR tests), Firebase allowlist revocation, account switch/local cache isolation, Studio offline draft/Commit/Refresh/conflicts, authorized bulk/image upload, Pack publish rights gate, public anonymous catalog, full/delta downloads, optional Home updates, valid cloud tombstones, interrupted installs and GameSession snapshots. Include malformed and malicious manifests and no-connectivity app restarts. Check T26A production frontend CI/CD behavior (successful Studio push, failed build, unchanged backend deployment, DNS/HTTPS, mobile viewport and rollback). Run a cross-browser Studio checklist (at least a desktop Chromium-based browser and a narrow/mobile-browser viewport, with other supported engines documented), plus Android physical-device tests for **BiGuess Mobile**; use rights-cleared fixtures only. Verify browser refresh, tab closure, cache eviction, offline draft recovery and origin/auth restrictions.
**Acceptance:** A documented pass/fail matrix has evidence for every Migration §25 scenario and collector-privacy boundary; nothing contacts the network between Start Game and completion; no unauthorized Studio data can be fetched or edited; automatic **static Studio frontend** releases remain scoped to approved `main` changes, and there are no automatic Content Backend deployments, database migrations, Pack publications or Mobile app releases.

### [ ] T47 — GATE: Retire Mobile legacy hardcoded content only after T46 passes
**Agent task:** After the offline and cloud-integrated path is verified, retire production reliance on `assets_manifest.dart` and bundled Anime/Flags images. Preserve source archives and rollback; deliberately clean obsolete directories, tooling and docs without rewriting Git history. Ensure Studio's own content fixtures and rights records are not mistaken for app-bundled, publicly redistributable content. Measure APK size, version correctness and local migration safety.
**Acceptance:** Mobile plays downloaded rights-cleared Packs without legacy asset dependency; **Studio Flutter Web builds and Android Mobile builds**; rollback reports and asset inventory reconcile; no unapproved content is distributed.

### [ ] T48 — GATE: Production Content Backend release security, Studio hosting audit, and staged rollout
**Agent task:** **Do not recreate or postpone the already-live Studio site or deployment pipeline from T26A.** Audit the established Pages custom domain, HTTPS, CI/CD permissions, preview access, rollback, cache policy, browser storage/privacy and CSP. Complete Firebase authorized-domain and Worker authenticated-origin CORS/security review before enabling privileged production data. Separately plan and obtain explicit owner approval for staging → production **Content Backend** rollout (Workers API, D1 migrations, private R2, Firebase allowlist/roles, operator secrets/Ed25519 signing keys, backups/rollback, usage alerts, content-rights/takedown safeguards and no public unlicensed content). Static Studio frontend pushes may continue automatically after successful `main` checks; **backend deployments, migrations and content publication must not become automatic because of the website workflow**. Verify login page publicly loads but only authorized Owner/Collectors can access administrative data. Preserve separate Android Mobile signing/distribution and Pack update policy.
**Acceptance:** Reviewed runbook and evidence confirm the T26A website/push-to-deploy pipeline has remained operational and secure, while production API/data rollout remains independently approved, staged, observable and reversible. DNS/TLS, CSP/CORS, Firebase authorized domains, web assets/secrets audit, contributor privacy, storage backups, usage limits, publication rights and Mobile signing have explicit owners and test results. No automatic backend production release, database migration, uncleared content publication or newly introduced secrets are permitted.

### [ ] T49 — GATE: Realistic browser Studio and player trials; MVP sign-off
**Agent task:** Conduct authorized **browser-based Studio** trials with multiple Collectors (each sees only their own contributions) and Owner review, on desktop and at least a small-screen browser; then run face-to-face Android Mobile playtests using rights-cleared Packs. Observe browser multi-image import ergonomics, offline draft persistence/limitations, manual Commit/Refresh, publication, role isolation, time-to-first-game, outward identity readability, Home updates, replay intent, and error recovery. Limit changes to evidenced blockers in separate PRs.
**Acceptance:** Recorded findings, privacy/rights checks, technical evidence and final MVP definition of done; product demand assessed separately from engineering completion.

---

# PHASE G — BiGuess Studio Web Modernization

This is an intentional post-MVP migration/redesign proposal, not authorization to replace Studio. T44–T49 remain unfinished, separate gates and must satisfy their own acceptance criteria before Phase G execution. Historical Flutter decisions and completed evidence remain unchanged. T50 must explicitly approve a forward-only React replacement; blueprint amendments are follow-up approval items, not changes made by this roadmap.

## Proposed architecture and universal quality/security contract

Prefer a static client-rendered React + TypeScript application built with Vite in temporary `studio-web/`, alongside `studio/`. Validate Tailwind CSS, shadcn/ui accessible primitives, React Router, TanStack Query/Table/Virtual, IndexedDB (possibly Dexie), React Hook Form + Zod, Motion for React, and Vitest/React Testing Library/Playwright in T50. Each dependency needs a concrete purpose, browser compatibility, security review and acceptable bundle cost; no automatic additions. Node.js is frontend tooling only; Next.js, SSR or a production server require measured justification and separate approval. Retain Workers/D1/private R2, Firebase identity, Cloudflare Pages and GitHub Actions.

- **Visual quality:** Original, coherent BiGuess identity, professional typography, spacing, surfaces and component language; preserve the exact centralized BiGuess palette unless separately approved. Keep readable density; references are interaction inspiration, not copied templates. Optional dark mode requires design approval.
- **Responsive quality:** Consider desktop, tablet and mobile independently, including touch-friendly cards, bottom sheets/full-screen editors, safe areas, landscape, zoom and software keyboards. Keep critical actions reachable; reduce clicks and nested dialogs without removing security confirmations.
- **Performance:** Measure bundle size, memory, responsiveness and stability throughout. Avoid redundant requests/renders, huge DOM trees, oversized decoding and long main-thread tasks; use bounded workers, lazy resources and virtualization where measured.
- **Motion/accessibility:** Purposeful navigation/progress/state feedback, never required to understand or complete actions. Semantic labels, focus management, keyboard/mouse/touch, text scaling, contrast and reduced motion target WCAG 2.2 AA.
- **Security/product:** Preserve frozen anonymous `/content/v1` and compatible Studio contracts, canonical Card fields, server-derived Owner/Collector scope and zero Collector deletion. Never bundle credentials, signing keys or private datasets; isolate account caches and reject late prior-session responses. Keep Anime/Flags quarantined. No billing, public creators, marketplace, AI or F01–F08 expansion; Android/gameplay remain independent.
- **Data/workflow:** Preserve offline drafts, explicit Commit/manual Refresh, revisions, idempotency and conflicts. No polling, realtime or per-keystroke server writes. Browser storage is best effort; never promise recovery after eviction without a verified backup. No irreversible migration without approval, no deletion of the old dataset before verified migration, and no automatic publication.
- **Release:** Keep `https://studio.saoudi.online`, the existing scoped Pages/GitHub Actions mechanism and the working Flutter frontend until approved cutover. Frontend release never triggers backend deployment, D1 migration, publication or Android release.

## Execution sequence and approval gates

**T50 → T51 → T52 → T53 → T54 → T55 → T56 → T57 → T58 → T59 → T60 → T61 → T62 → T63 → T64 → T65 → T66 → T67**

A single coding agent follows this order; parallel work requires satisfied dependencies and a documented reviewed exception. T50 architecture, T51 visual design, T56 local-data preservation, T66 validation and T67 cutover are explicit approval gates. **No production replacement before T66 passes and explicit T67 release approval.** Each ticket normally yields one reviewable PR; staged tickets below use ordered, separately reviewable PRs within that ticket, with completion only after all stages pass.

T52 precedes the application scaffold: deliver tokens, component specifications and isolated previews first; integrate runnable React primitives into T53's scaffold as its second PR stage. Any need for an earlier temporary React harness requires a reviewed sequencing exception, not an implicit full application build.

### [ ] T50 — GATE: Audit current Studio, benchmark performance, and approve frontend migration

**Agent task:** Audit the existing Flutter Web Studio before replacing anything.

Document every screen, user journey, API integration, role restriction, IndexedDB workflow, and existing feature.

Create a complete feature-parity matrix covering at least:

- Dashboard
- Topics
- My Packs
- Cards
- Profile and statistics
- Google sign-in/sign-out
- Owner/Collector permissions
- Card editing
- Multi-image import
- Duplicate detection
- Image normalization/upload
- Offline drafts
- Commit/Refresh
- Conflict handling
- Publishing/rights approval
- Loading, error, and recovery states

Record current browser startup performance, main interactions, bundle size, memory behavior, and mobile usability problems.

Compare a Flutter redesign against a React migration using maintenance cost, implementation risk, performance, usability, and dependency impact.

**Acceptance:** Documented feature-parity inventory, reproducible baseline measurements, migration risks, rollback strategy, and explicit owner approval of the React migration before T51 proceeds.

**Dependencies:** T49 completion; existing Studio implementation and deployment evidence. Preserve [Studio scope contracts](contracts/studio/v1/README.md), [image ingestion](contracts/studio/v1/image-ingestion.md), [profile](contracts/studio/v1/profile.md), and [public content contracts](contracts/content/v1).

**Verification:** Inventory current source, contracts, verification reports and deployment workflow; record repeatable browser traces, payload and memory results, parity matrix, rollback rehearsal plan and signed architecture decision. Distinguish implemented features from targets.

### [ ] T51 — GATE: Design the premium Studio UX and obtain visual approval

**Agent task:** Create a coherent visual direction before developing production components.

Design high-fidelity mockups for desktop, tablet, and mobile, covering Dashboard, Topics, Packs, Cards, bulk import, Card editing, publishing, and authentication states.

The design should include:

- Distinct BiGuess brand identity
- Premium typography and spacing
- Professional color palette
- Strong visual hierarchy
- High-quality cards, tables, menus, and dialogs
- Elegant image-focused layouts
- Consistent interaction patterns
- Clear status and validation presentation
- Light and optional dark-theme proposals
- Purposeful animation specifications

Provide mockups for important loading, empty, offline, error, and conflict states.

Avoid blindly copying Linear, Notion, Airtable, or other products. Use them only as references for interaction quality and visual discipline.

**Acceptance:** Approved design direction, component inventory, responsive mockups, interaction specifications, accessibility review, and an explicit owner design sign-off.

No full frontend implementation before approval.

**Dependencies:** T50 accepted; T50/T51 approvals and all applicable earlier Phase G gates. Preserve [Studio scope contracts](contracts/studio/v1/README.md), [image ingestion](contracts/studio/v1/image-ingestion.md), [profile](contracts/studio/v1/profile.md), and [public content contracts](contracts/content/v1).

**Verification:** Review desktop/tablet/mobile mockups and all state variants with keyboard/focus/contrast annotations; record owner sign-off before production component work.

### [ ] T52 — Build the reusable design system and animation foundations

**Agent task:** Create the React design system from the approved T51 designs.

Define tokens for typography, colors, spacing, borders, radii, shadows, elevation, responsive layouts, and motion.

Build accessible shared primitives such as buttons, inputs, comboboxes, dialogs, sheets, dropdowns, tables, cards, status indicators, notifications, skeletons, and confirmation flows.

Define motion durations and easing curves. Prefer brief transitions, typically around 120–250 ms, adjusted to the interaction.

Support `prefers-reduced-motion`.

**Acceptance:** Documented design tokens, reusable components, representative component previews/tests, consistent visual states, keyboard navigation, reduced-motion support, and no substantial duplication of styling logic.

**Dependencies:** T51 accepted; T50/T51 approvals and all applicable earlier Phase G gates. Preserve [Studio scope contracts](contracts/studio/v1/README.md), [image ingestion](contracts/studio/v1/image-ingestion.md), [profile](contracts/studio/v1/profile.md), and [public content contracts](contracts/content/v1).

**Verification:** Component state previews and accessibility/keyboard/reduced-motion tests; review token reuse and motion timing. Stage 1 specifications/previews; stage 2 runnable integration in T53.

### [ ] T53 — Scaffold the independent React Studio application and CI

**Agent task:** Create the separate React + TypeScript + Vite project without replacing Flutter Studio.

Establish routing, module boundaries, environment configuration, strict TypeScript checking, ESLint, formatting, tests, local development scripts, and production builds.

Set up scoped CI without modifying the current live deployment target.

Configure production-safe static routing and prepare for Cloudflare Pages.

**Acceptance:** A working independent frontend with passing type checks, lint, tests, and static builds; existing Flutter Studio and Android Mobile remain unchanged and functional.

**Dependencies:** T52 accepted; T50/T51 approvals and all applicable earlier Phase G gates. Preserve [Studio scope contracts](contracts/studio/v1/README.md), [image ingestion](contracts/studio/v1/image-ingestion.md), [profile](contracts/studio/v1/profile.md), and [public content contracts](contracts/content/v1).

**Verification:** Run strict typecheck, lint, unit tests and static build in scoped CI; test deep-link fallback and confirm current deployment workflow/target are untouched. Stage 1 scaffold; stage 2 T52 component integration.

### [ ] T54 — Reimplement authentication, authorization-aware routing, and session lifecycle

**Agent task:** Integrate the existing Firebase Google sign-in system.

Preserve server-derived Owner/Collector permissions and reject unauthorized users.

Implement protected routing, session restoration, token refresh, expiry/revocation handling, sign-out, account switching, and clear offline/authentication errors.

Handle browser popup/redirect limitations.

Do not assume frontend route protection provides server-side security.

**Acceptance:** Two-Collector/Owner and unauthorized-user tests; no cross-account data exposure; expired/revoked sessions fail safely; Chrome, Firefox, and WebKit authentication flows are tested where supported.

**Dependencies:** T53 accepted; T50/T51 approvals and all applicable earlier Phase G gates. Preserve [Studio scope contracts](contracts/studio/v1/README.md), [image ingestion](contracts/studio/v1/image-ingestion.md), [profile](contracts/studio/v1/profile.md), and [public content contracts](contracts/content/v1).

**Verification:** Automated two-Collector/Owner/unauthorized and expired/revoked-session tests, account-switch late-response checks; browser popup/redirect limitations documented with supported Chromium/Firefox/WebKit checks.

### [ ] T55 — Implement a typed, contract-compatible Studio API client

**Agent task:** Build a typed frontend service layer using the existing Studio API contracts.

Cover authorized reads, pagination, change feeds, mutations, image ingestion, role lookup, statistics, and publishing operations.

Handle HTTP 401/403/404/409/412, cancellation, timeouts, validation, retry policies, and idempotency correctly.

Do not make unauthorized or hidden private records available through frontend caches.

Avoid unnecessary background requests.

**Acceptance:** Contract tests and representative Worker integration tests pass without changing established public or administrative API semantics.

**Dependencies:** T54 accepted; T50/T51 approvals and all applicable earlier Phase G gates. Preserve [Studio scope contracts](contracts/studio/v1/README.md), [image ingestion](contracts/studio/v1/image-ingestion.md), [profile](contracts/studio/v1/profile.md), and [public content contracts](contracts/content/v1).

**Verification:** Contract fixtures and local Worker integration tests for reads, pagination, feeds, mutations, ingestion, profile and publication; test status errors, cancellation, retries and idempotency without backend semantic changes.

### [ ] T56 — GATE: Preserve and migrate IndexedDB drafts, offline data, and pending operations

**Agent task:** Audit the existing Flutter Studio browser-storage schema and pending operation formats.

Implement account-isolated IndexedDB persistence for the React application.

Design and verify a safe migration path for existing browser-local data, including drafts, unsent changes, conflict markers, revisions, and image references.

Maintain offline editing of previously synchronized authorized data when browser storage permits.

Never overwrite or delete an old local dataset before a verified migration, and never silently discard an unsent operation.

Define recovery behavior for quota errors, incomplete migrations, browser eviction, and cross-account switches.

**Acceptance:** Real-browser tests prove draft preservation through reload, offline editing, migration interruption/retry, and account switching; no privilege leakage, silent data loss, or unintended automatic server writes.

Require explicit approval before any irreversible migration.

**Dependencies:** T55 accepted; T50/T51 approvals and all applicable earlier Phase G gates. Preserve [Studio scope contracts](contracts/studio/v1/README.md), [image ingestion](contracts/studio/v1/image-ingestion.md), [profile](contracts/studio/v1/profile.md), and [public content contracts](contracts/content/v1).

**Verification:** Use real existing-schema fixtures and browser tests for reload, offline editing, interrupted migration/retry, quota failure, stale tabs and account switches. Preview-origin storage cannot prove same-origin production migration; rehearse same-origin upgrade and rollback. Stage 1 audit/backup plan; stage 2 reversible migrator and proof; irreversible steps require owner approval.

### [ ] T57 — Build the responsive application shell and navigation

**Agent task:** Implement the approved new layout:

- Desktop navigation sidebar
- Collapsible or compact navigation on smaller screens
- Mobile-appropriate navigation and menus
- Contextual page headers
- Breadcrumbs where useful
- Global search entry points where appropriate
- Account menu
- Clear Commit/Refresh indicators
- Connection and unsaved-change status

Do not simply shrink the desktop layout for mobile.

Support mobile safe areas, software keyboards, landscape orientations, touch interactions, and browser zoom.

**Acceptance:** Layouts work at representative widths including 320, 360, 390, 430, 768, 1024, and 1440 pixels; no horizontal overflow, inaccessible controls, or hidden critical actions.

**Dependencies:** T56 accepted; T50/T51 approvals and all applicable earlier Phase G gates. Preserve [Studio scope contracts](contracts/studio/v1/README.md), [image ingestion](contracts/studio/v1/image-ingestion.md), [profile](contracts/studio/v1/profile.md), and [public content contracts](contracts/content/v1).

**Verification:** Browser screenshots and keyboard/touch checks at 320/360/390/430/768/1024/1440 px, landscape, 200% text/zoom, safe areas and software keyboard; assert no overflow or hidden actions.

### [ ] T58 — Rebuild the Dashboard and contributor Profile

**Agent task:** Create a visually polished, practical Dashboard that gives authorized users an immediate understanding of their content and pending work.

Show role-appropriate counts, recent activity, draft status, validation problems, and actionable navigation using existing authorized information.

Rebuild contributor Profile, role display, and scoped statistics.

Avoid unnecessary analytics features or exposing other contributors' activity.

**Acceptance:** Dashboard and Profile accurately display authorized data, have useful empty/offline states, and remain clear and performant on mobile.

**Dependencies:** T57 accepted; T50/T51 approvals and all applicable earlier Phase G gates. Preserve [Studio scope contracts](contracts/studio/v1/README.md), [image ingestion](contracts/studio/v1/image-ingestion.md), [profile](contracts/studio/v1/profile.md), and [public content contracts](contracts/content/v1).

**Verification:** Role-scoped fixture tests and mobile browser checks for accurate statistics, navigation and loading/empty/offline/error states.

### [ ] T59 — Rebuild Topic management

**Agent task:** Reimplement Topic browsing, creation, editing, visibility changes, search, and Owner-only lifecycle actions.

Provide an efficient Topic taxonomy picker for Collectors.

Respect existing role restrictions and relationships between Topics and Packs.

Use the new design system, accessible forms, and responsive presentation.

**Acceptance:** Feature parity with T29, authorization regression tests, clear confirmation flows, and desktop/mobile usability tests.

**Dependencies:** T58 accepted; T50/T51 approvals and all applicable earlier Phase G gates. Preserve [Studio scope contracts](contracts/studio/v1/README.md), [image ingestion](contracts/studio/v1/image-ingestion.md), [profile](contracts/studio/v1/profile.md), and [public content contracts](contracts/content/v1).

**Verification:** T29 parity, Owner/Collector negative authorization tests, taxonomy relationship validation and keyboard/touch form checks.

### [ ] T60 — Rebuild Pack management

**Agent task:** Create a premium Packs workspace with useful cards or tables, search, status filters, sorting, creation/editing, and contextual actions.

Show Card counts, completion status, draft state, publishing eligibility, and synchronization state where existing contracts support them.

Make the primary content workflow understandable without navigating through excessive dialogs.

Preserve Owner global access and Collector ownership restrictions.

**Acceptance:** Feature parity with T30, correct scope enforcement, safe pending edits, responsive presentation, and clear recovery from invalid relationships or conflicts.

**Dependencies:** T59 accepted; T50/T51 approvals and all applicable earlier Phase G gates. Preserve [Studio scope contracts](contracts/studio/v1/README.md), [image ingestion](contracts/studio/v1/image-ingestion.md), [profile](contracts/studio/v1/profile.md), and [public content contracts](contracts/content/v1).

**Verification:** T30 parity, ownership and invalid-parent tests, retained pending edits/conflicts, responsive filter/sort/action browser checks.

### [ ] T61 — Build the high-performance Cards workspace

**Agent task:** Create the Studio's primary content-management interface.

Support:

- Responsive Card table and image-grid views
- Fast search and multi-dimensional filters
- Difficulty/status indicators
- Duplicate detection
- Sorting
- Multi-selection
- Role-appropriate bulk operations
- Keyboard shortcuts where useful
- Efficient pagination or virtualization
- Clear draft/synced/conflict status

Target thousands of Cards without rendering all rows or images simultaneously.

Preserve existing exact-byte, exact-name, and similar-name duplicate semantics.

**Acceptance:** Feature parity with T34; a 5,000-Card test dataset remains smooth and searchable; no cross-account leakage; mobile has a genuinely usable Card browsing and selection interface.

**Dependencies:** T60 accepted; T50/T51 approvals and all applicable earlier Phase G gates. Preserve [Studio scope contracts](contracts/studio/v1/README.md), [image ingestion](contracts/studio/v1/image-ingestion.md), [profile](contracts/studio/v1/profile.md), and [public content contracts](contracts/content/v1).

**Verification:** T34 parity and duplicate fixtures (exact bytes/name/similar name); instrument 5,000 Cards, bounded DOM/image loading, search/filter latency and mobile multi-selection against T50 budgets.

### [ ] T62 — Rebuild Card editing and image review

**Agent task:** Create a fast, polished Card editing experience.

Consider contextual drawers, side panels, or dedicated mobile screens rather than excessive modal stacking.

Preserve canonical Card product fields only:

- Name
- Image
- Difficulty (1–3)
- Pack relationship

Support image preview, replacement, validation, duplicate warnings, and draft-status visibility.

Maintain stable Card IDs and existing permissions.

**Acceptance:** Feature parity with T31, keyboard/touch accessibility, no accidental data loss, and correct offline draft behavior.

**Dependencies:** T61 accepted; T50/T51 approvals and all applicable earlier Phase G gates. Preserve [Studio scope contracts](contracts/studio/v1/README.md), [image ingestion](contracts/studio/v1/image-ingestion.md), [profile](contracts/studio/v1/profile.md), and [public content contracts](contracts/content/v1).

**Verification:** T31 parity, stable-ID and canonical-field tests, offline edit/reload, replacement/validation/duplicate handling and keyboard/touch loss-prevention browser checks.

### [ ] T63 — Rebuild the bulk image import and Card creation workflow

**Agent task:** Make multi-image import one of the strongest features of the new Studio.

Create an efficient desktop and mobile flow for:

- Selecting or dropping many images
- Previewing and reviewing candidates
- Filename-based name suggestions
- Batch editing names and difficulties
- Duplicate detection
- Image validation and normalization
- Processing progress
- Individual errors
- Cancellation and retry
- Safe upload and explicit Commit
- Recoverable local drafts where browser storage permits

Use bounded worker-based image processing, not main-thread work that freezes interactions.

Preserve existing upload limits, server validation, ownership rules, and idempotent mutation semantics.

**Acceptance:** Hundreds of fixture images can be prepared and reviewed without major UI stalls; cancellation and partial failures are recoverable; no automatic publication or silent loss of staged changes.

**Dependencies:** T62 accepted; T50/T51 approvals and all applicable earlier Phase G gates. Preserve [Studio scope contracts](contracts/studio/v1/README.md), [image ingestion](contracts/studio/v1/image-ingestion.md), [profile](contracts/studio/v1/profile.md), and [public content contracts](contracts/content/v1).

**Verification:** Browser import of hundreds of fixtures with measured main-thread stalls, bounded worker/memory use, cancellation/retry, partial failure, reload recovery, upload limits and explicit Commit. Stage 1 preparation/review; stage 2 upload/recovery integration.

### [ ] T64 — Rebuild synchronization, conflict resolution, and publishing workflows

**Agent task:** Create a clear and trustworthy interface for:

- Pending local changes
- Explicit Commit
- Manual Refresh
- Revision conflicts
- Stale browser tabs
- Upload failures
- Validation errors
- Publishing readiness
- Owner rights approval
- Preview/review/publish/unpublish

Do not introduce background polling, realtime collaboration, or per-keystroke server writes.

Make destructive and privileged actions deliberate and unambiguous.

**Acceptance:** Feature parity with T35/T36, correct Worker permissions, safe offline-to-online recovery, and no silent overwrite or unauthorized publication.

**Dependencies:** T63 accepted; T50/T51 approvals and all applicable earlier Phase G gates. Preserve [Studio scope contracts](contracts/studio/v1/README.md), [image ingestion](contracts/studio/v1/image-ingestion.md), [profile](contracts/studio/v1/profile.md), and [public content contracts](contracts/content/v1).

**Verification:** T35/T36 parity with local Worker: offline-to-online Commit/Refresh, stale tabs, 409/412, failed uploads, idempotent retries, rights review and unauthorized publishing. Stage 1 sync/conflicts; stage 2 privileged publication integration.

### [ ] T65 — Implement premium motion, interactions, and accessibility polish

**Agent task:** Polish the full application with restrained, cohesive animation.

Examples include:

- Subtle route transitions
- Smooth navigation state changes
- Hover/focus/press feedback
- Animated sidebar and mobile menu
- Dialog and drawer entrances
- Status transitions
- Import progress feedback
- Loading skeletons
- Optimistic local interaction feedback where safe
- Toasts and confirmations

Do not animate every element, delay important actions, or use excessive decorative movement.

Avoid expensive layout-thrashing animations. Favor transform and opacity when appropriate.

Ensure reduced-motion settings disable nonessential motion.

Target WCAG 2.2 AA accessibility, including contrast, keyboard operation, focus visibility, accessible announcements, and touch targets.

**Acceptance:** Consistent interaction quality, reduced-motion compatibility, accessibility tests, and no major animation-induced interaction delays or layout shifts.

**Dependencies:** T64 accepted; T50/T51 approvals and all applicable earlier Phase G gates. Preserve [Studio scope contracts](contracts/studio/v1/README.md), [image ingestion](contracts/studio/v1/image-ingestion.md), [profile](contracts/studio/v1/profile.md), and [public content contracts](contracts/content/v1).

**Verification:** Automated accessibility scans plus manual keyboard, focus, announcements, contrast, touch and reduced-motion checks; profile motion for layout thrashing, delays and shifts.

### [ ] T66 — GATE: Performance, cross-browser, mobile, security, and feature-parity validation

**Agent task:** Run an extensive verification program before production replacement.

Measure:

- Initial JavaScript and CSS payloads
- Startup and route rendering
- Core Web Vitals
- Search and filtering with 5,000+ Cards
- Large-table scrolling
- Image preview and batch processing
- CPU and memory usage
- Animation smoothness
- Offline draft recovery
- Session/account isolation
- Authorized upload and publishing
- Real-device mobile usability

Use real browser instrumentation, not only isolated unit benchmarks.

Target good Core Web Vitals on representative production conditions:

- LCP ≤ 2.5 seconds
- INP ≤ 200 ms
- CLS ≤ 0.1

Define reproducible browser/device/network conditions and report measured results, not assumed scores.

Aim for smooth 60 FPS motion on representative supported devices, with graceful degradation on slower hardware.

Use lazy loading, code splitting, memoization where justified, virtualized collections, careful image decoding, and bounded workers.

Run Playwright and relevant browser tests for desktop Chromium, Firefox, WebKit, and mobile viewports.

Compare the complete React feature-parity matrix against the existing Flutter Studio.

**Acceptance:** Documented passing functional/security/offline/accessibility test matrix, approved performance budgets, recorded measurements, no critical unresolved regression, and explicit owner acceptance before cutover.

**Dependencies:** T65 accepted; T50/T51 approvals and all applicable earlier Phase G gates. Preserve [Studio scope contracts](contracts/studio/v1/README.md), [image ingestion](contracts/studio/v1/image-ingestion.md), [profile](contracts/studio/v1/profile.md), and [public content contracts](contracts/content/v1).

**Verification:** Run recorded Playwright Chromium/Firefox/WebKit and real-device trials, security/account/offline matrix and full parity review. Record payload, startup/routes, 5,000+ Card search/scroll, batch images, CPU/memory and frame timing under reproducible device/network/cache conditions. Agree numerical bundle/memory budgets from T50; distinguish lab proxies from field INP. Stage 1 evidence; stage 2 regression closure and explicit owner acceptance.

### [ ] T67 — GATE: Controlled Cloudflare Pages cutover, rollback, and legacy cleanup

**Agent task:** Plan the final replacement of Flutter Studio on `https://studio.saoudi.online`.

Keep the existing production frontend available until the React version passes T66 and the owner explicitly approves release.

Update the existing scoped GitHub Actions deployment workflow to build and publish the approved React static output.

Do not create an unnecessary second production deployment mechanism.

Validate:

- Firebase authorized origin
- Worker CORS
- HTTPS and custom domain
- Deep-link routing and browser refresh
- Security headers and cache policy
- Absence of credentials/private data in bundles
- Account isolation
- Existing IndexedDB data migration
- Commit/Refresh and publishing
- Mobile behavior
- Failure rollback to a known-good release

Never couple frontend deployment to automatic backend deployment, D1 migrations, content publication, or Android releases.

Retain the Flutter implementation and recovery instructions until a separate approved cleanup stage determines removal is safe.

**Acceptance:** Documented successful cutover, real production smoke tests with authorized accounts, preserved local drafts, functioning scoped deployment and rollback, and explicit final acceptance of the redesigned Studio.

**Dependencies:** T66 accepted; T50/T51 approvals and all applicable earlier Phase G gates. Preserve [Studio scope contracts](contracts/studio/v1/README.md), [image ingestion](contracts/studio/v1/image-ingestion.md), [profile](contracts/studio/v1/profile.md), and [public content contracts](contracts/content/v1).

**Verification:** Rehearse known-good rollback including storage compatibility before owner release approval; then production authorized-account smoke checks, Firebase origin/CORS, HTTPS, deep links, headers/cache, bundle secrets, drafts, Commit/Refresh/publication and mobile. Stage 1 approved release/rollback plan; stage 2 scoped cutover and observation; stage 3 separately approved legacy cleanup after retention period and recovery proof.

## Human decisions / non-coding gates for remaining tickets

**Decisions now set (apply prospectively; do not edit completed tickets):**

1. **Studio platform and early live domain:** A **separate Flutter Web application** in `studio/`, usable in desktop/mobile browsers; after T26, **T26A deploys its safe static scaffold directly to `https://studio.saoudi.online`**. The site is updated on every passing Studio-related push to `main`, not on unrelated branch pushes. It is not a native Android Studio app or Play Store deliverable. Keep the root Android Mobile app and single repository.
2. **Studio access:** Google/Firebase Web authentication plus Worker-enforced allowlist and Owner/Collector roles. Anyone may reach the public login page, but only authorized contributors can access admin data; there are no public Studio accounts or player logins.
3. **Shared server:** One canonical D1 content database with R2 objects and Cloudflare Worker access *per environment*, not a database for every contributor. Firebase Auth handles identity, not content storage.
4. **Contributor scope:** Owner sees all Studio data. Each Collector sees/edits only their **own Pack contributions and contained Cards**, plus a minimal Topic taxonomy. No cross-Collector editing, arbitrary ownership assignment, deletion or restoration in MVP. This new requirement must be implemented in T27A/T27B before T28; it is **not** already guaranteed by completed T23/T24.
5. **Mobile update experience:** Download once, play offline from an immutable installed snapshot. Ordinary Pack updates are **manual from Home/Pack management**, not background/gameplay updates. Server-deletion tombstones are handled safely after a valid Home synchronization, never mid-game. App upgrades remain distinct.
6. **Sharing, credentials and rollout:** Share only stable domain/contracts where useful. Public GitHub source is permissible with strong credential hygiene and private rights/data records. The **Studio static frontend** goes live early, but **Content Backend production deployment remains deferred**; only harmless public scaffold/UI reaches the website before authorization is implemented.

**Still requires human approval before the affected gate:**

7. **Immediate website setup (T26A, one-time owner action):** Authorize the **Cloudflare Pages Direct Upload + GitHub Actions** project, secure GitHub deploy credentials, attach `studio.saoudi.online` through owner-controlled DNS, verify TLS and test a harmless `main` push/rollback. This authorizes **static frontend** deployment only; authentication domain/Worker CORS activation happens in T27 and its backend integration, and production backend/data rollout remains a separate T48 approval. This roadmap file alone does not change live DNS or deploy anything.
8. **Content rights:** Rights-clearance approval for each published dataset; old Anime/Flag assets stay quarantined despite being technically importable. A disclaimer alone grants no rights.
9. **Production release policy:** Early Studio website deployment/rollback is established by T26A. Independently approve staging/production **Content Backend** resources, API/data migrations, content-publication policy, costs, Mobile Android distribution and app-update policy before those production operations.
10. **Freemium:** Existing Free = 5 stored downloaded Packs and <=10 rounds per game; internal Pro QA mode only until separately approved commercial billing. No ad walls or online checks during play.
11. **Takedown limitations:** A tombstone is applied after valid synchronization; it cannot retroactively erase content on a disconnected device or retract already redistributed files.

## Explicitly deferred, post-MVP backlog — do not assign until real demand exists

- **F01:** Free vs Pro payment gateway, billing integration, and entitlement management (following the established 5-pack storage and 10-round per game Free model vs unrestricted Pro), after legal/commercial review and user-demand evidence.
- **F02:** Billing and entitlement restoration that do not require per-round internet checks.
- **F03:** Public creator accounts, submission and moderation queue, rights verification, abuse reporting, takedown tooling; these are **not** implied by a publicly reachable but admin-restricted Studio website.
- **F04:** Creator contributions, public reputation and marketplace — only after moderation, payments, taxation, and licensing are viable.
- **F05:** Fully licensed/owned partner content and custom event Packs.
- **F06:** Advanced analytics/experiments after basic retention is measured privacy-consciously.
- **F07:** Revisit timer, AI, scores, matchmaking, realtime play only on demonstrated need; these explicitly contradict the current lean MVP scope unless consciously approved as a new product direction.
- **F08:** Optional multi-contributor shared Pack ownership, delegation, or reassignment, after a new explicitly authorized visibility and attribution contract is approved.
