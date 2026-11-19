# T49 — trial findings and MVP definition of done

**Status: NOT SIGNED OFF. Human trials NOT RUN.**

Prepared 2026-11-12 against `75520b6` (`1.534.144`). The
[trial protocol](T49-TRIAL-PROTOCOL.md) is ready for authorized participants;
this record must not be presented as completed user research or an approved MVP.

## What was actually available

- No Collector, Owner-reviewer or face-to-face player sessions were supplied or
  conducted. There are **zero completed participant sessions** and **zero
  physical Android playtests**. No interview responses were obtained.
- Fresh `adb devices -l` returned an empty device list. No physical time-to-first-
  game, outward-readability, replay-intent or interruption result exists.
- [T46](T46-VERIFICATION.md) remains NOT PASSED. Its broad Studio browser harness
  fails; later assertions are unexecuted, and live role/physical evidence is
  incomplete. T47 legacy retirement did not run.
- [T48](T48-ROLLOUT-RUNBOOK.md) remains NO-GO with Owner plan/execution approval
  pending. Production Studio is older than main, migrations 0009/0010 are pending,
  remote staging is absent, and backup/restore, alerts and named operators lack
  signoff. No new cloud state or public content was created for T49.
- The cleared Shapes source has four Cards. It supports technical flow tests;
  it does not represent realistic content variety or establish demand. No legacy
  Anime/Flags content was approved or published for these trials.

Participant availability/environment and physical-device questions were raised
during preparation. An unanswered question is neither consent nor approval.
Previous T48 plan-approval questions remain pending; the T49 request is not an
implicit answer to them or a grant to provision/publicize content.

## Existing technical findings, not participant observations

| Finding | Verified source/evidence | Consequence for a real trial |
| --- | --- | --- |
| Collector privacy, stale writers and upload scope pass local fixtures | T46: 235 Worker/D1/R2 tests; two Collectors/Owner, guessed IDs, audit counts, 412/409 and image origin/ownership checks | Strong engineering evidence; does not substitute for independent real accounts or human comprehension of scope/conflicts. |
| Desktop/narrow focused browser paths pass | T46: sync, profile, private ingestion, public login viewport and IndexedDB checks | Actual browser evidence with synthetic identities; no participant ergonomics or Google-authenticated three-role trial completed. |
| Broad browser/hosted checks still fail | T46/T48: missing incremental-feed route in broad fixture; hosted backend lacks Pillow; strict popup smoke reports COOP warnings | Later broad assertions and current frontend release remain blocked. Fix only in separate reviewed work, then re-run. |
| Same-tab offline drafts persist; new offline tab needs online authorization | T46 tracked tab-close harness and T48 privacy review | Include the limitation in consent/task interpretation. Confirm recovered draft/queue after fresh auth; do not promise uninterrupted offline tab-closure editing. |
| Local drafts remain plaintext and can be lost on eviction | T48 IndexedDB/privacy source review | Application account isolation is not secure erasure or per-OS-user encryption. Confirm shared-device/retention expectations; eviction recovery cannot recover the only copy. |
| Worker allowlist removal and Firebase administrative revocation differ | T48 verified signature/expiry+allowlist behavior; no live revocation test | Do not advertise Firebase-only disable as immediate backend denial. Obtain an approved procedure for a live revocation trial. |
| Installed gameplay survives host kill/restart with no HTTP | T46 isolated network process: source archive removed, fresh restart, 10 + 3 rounds, SQLite integrity | Host proof supports the design; physical Android, outward readability and native-engine behavior are still NOT RUN. |
| App updates are optional and separate | T45 launch/optional UI/checksum tests, carried through T46 | Verify on the approved device binary; do not trigger release or content synchronization just to begin an installed game. |

## Participant findings ledger

There are no participant findings yet. Do not fill this table with automated
results, invented quotes or assumptions about what users want.

| Session | Participant code/role | Task/device/viewport | Observed outcome/assistance | Timing or feedback | Sanitized evidence | Disposition |
| --- | --- | --- | --- | --- | --- | --- |
| — | — | — | NOT RUN | Not measured/collected | — | Schedule approved trials |

## MVP definition of done — required evidence still open

This checklist expresses the engineering and trial acceptance boundary. It is
not a product-expansion roadmap or a signed approval. Every item requires an
actual evidence link, responsible reviewer and explicit result before marking
it complete. Existing local passes alone do not complete cross-system items.

| Required result | Evidence now | Remaining before sign-off |
| --- | --- | --- |
| Canonical Topic → Pack → Card flow, installed private images and immutable per-game content | Local model/store/session tests and T46 offline gate | Complete physical approved-binary playtest and source/deployed compatibility checks. |
| Accountless, offline Android launch and all configured rounds without Start-to-completion network attempts | Host isolation/HTTP trap passes | Physical device instrumentation, airplane-mode restart and completion evidence. |
| Free five downloaded-Pack slots and ten-round limit; correct replay/Home resets; no public billing | Local entitlement/session/controller tests | Observe actual player intent and physical reset/management flow. |
| Multiple authorized browser Collectors see/edit only own contributions; Owner reviews all | Local server/browser authorization tests | Independent live account sessions, guessed-ID/role-change checks and Owner review on desktop/small screen. |
| Multi-image preparation/import is understandable, bounded and recoverable | Worker/Canvas/ingestion fixtures pass | Real Collector batch observation with exact count/bytes, assistance/errors and small-screen ergonomics. |
| Offline draft/queue limitations are understood; explicit Commit/Refresh and conflicts preserve edits | Focused browser/IndexedDB tests pass | Participant explanation/recovery, stale writers, account switch, tab closure and documented retention policy. |
| Only explicitly cleared content can be published/discovered/downloaded; private ownership stays private | Rights/quarantine, public protocol and signed-download fixture tests | Approved trial content/release record; live Owner review and separately authorized publication validation. |
| Signed full/delta downloads verify pinned keys and atomically retain prior playable data on failure | Local loopback/store/process tests pass | Physical interruption/storage/error tests plus outstanding existing-Card/image delta end-to-end coverage. |
| Only user-invoked Home updates/deletion sync; no active snapshot mutation | T43/T44 controller/store/widget tests | Physical Home update, removal/redownload/tombstone boundary and next-game revision observation. |
| Names/images read clearly while held outward and first-game path is usable | No participant/device evidence | Record lighting/distance/grip/text scale, timings from explicit initial states and assistance. Owner reviews results against agreed criteria. |
| Existing Studio frontend release path remains separate; production backend operations are approved/recoverable | T48 partial live hosting/auth metadata and rollout plan | Close T46/T48 failures, confirm operators, token policy, backups/restore, alerts, rights/takedown and execution approvals. |
| Legacy production reliance retired with archives/rollback/inventory/build evidence only after T46 | T47 explicitly blocked | Pass T46, then execute/review T47; do not distribute uncleared legacy assets as trial catalog content. |
| No unreviewed blocker remains; fixes are scoped and reverified | No T49 product fixes made | Separate PR per evidenced blocker, reviewed regression proof and retested participant path. |
| Engineering MVP sign-off recorded | **NOT APPROVED** | Named Owner + engineering reviewer, exact release/artifact/Pack revisions, evidence set, known limitations and decision date. |

No demand criterion is silently attached to these engineering checks. **Product
demand is NOT ASSESSED**: no participants/interviews or behavioral sample were
available. Record demand research, sampling limits and product decision separately;
an engineering pass does not imply appeal, retention, market fit or purchase intent.

## Decision and next executable step

Do not sign off MVP or mark T49 complete. Confirm participant codes/availability,
approved trial environment, appropriate cleared content and a physical Android
phone. Then conduct the protocol, attach real observations and close the remaining
engineering gates. Nothing in this report approves provisioning, publication,
legacy removal, a redesign or a Mobile release. No trial-evidenced blocker fix
was attempted; no unrelated product code was changed.

Fresh T49 repository verification and evidence fingerprints are recorded in
[T49-HOST-RESULTS.json](T49-HOST-RESULTS.json). These are technical checks, not
completed trials. Shared unrelated `TODO.md` edits remain outside this task.
