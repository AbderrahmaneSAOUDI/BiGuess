# T49 — browser Studio and face-to-face Android trial protocol

**Ready for scheduling; participant trials NOT RUN.** This protocol does not
authorize production provisioning, role changes, publication or a Mobile release.
Use it with [the trial/sign-off record](T49-MVP-SIGNOFF.md). Do not turn automated
fixture assertions into participant observations.

## Session prerequisites and record

Record the facilitator, observer, consenting participant codes, time window and
approved environment. Minimum Studio coverage is two independently authorized
Collectors, `C-A` and `C-B`, plus an Owner reviewer, `O`. Do not share browser
profiles, account credentials or sessions between them. The Android trial needs
a consenting face-to-face player pair and physical device. Participants can fill
several roles if the role/session boundaries remain distinct; record that choice.
The agent cannot recruit, contact or impersonate people without instructions.

Before beginning, capture:

| Field | Required evidence |
| --- | --- |
| Environment | Exact frontend SHA/release, Worker version, applied migration ledger, origin and approval reference |
| Browser | Engine/version, desktop viewport, small-screen viewport, touch/keyboard mode; label emulation separately from a real phone browser |
| Android | Physical model/OS, app version/build/certificate reference, app/private storage state and approved installation source |
| Content | Topic/Pack IDs, revision, Card count, manifest/archive/object checksums, approved signing-key fingerprint and per-content rights record |
| Authorization | Who approved test accounts, fixture creation/publication and fault injection, plus rollback/cleanup limits |
| Consent and privacy | Participant codes; agreed notes/recording scope, storage, access and retention. Record no passwords, bearers, secret allowlists or unrelated private content |
| Network | Normal, simulated outage and true disconnected states; how network attempts from Start through completion are observed |

The T48 audit found no remote staging Worker/bucket, unapplied production
migrations 0009/0010 and no API publication pins/operator credential. Do not use
its production connection as a ready-made trial sandbox. Prepare an approved
isolated environment and complete its change/rights records first. A local
synthetic identity adapter is useful for an engineering walkthrough, but is not
a real Firebase authorization trial.

Existing `test/fixtures/cleared_shapes/pack.json` declares four original cleared
Shapes with explicit publication permission. It is an approved **test provenance
fixture**, not blanket permission to release arbitrary content or publish it to
production. Use it to verify flow and recovery; four geometric Cards are not
representative evidence of content variety, audience demand or willingness to
play again. A realistic playtest needs separately confirmed suitable cleared
content. Never substitute bundled Anime/Flags, quarantine imports or arbitrary
Collector ownership. No test artifact is automatically public.

## Studio tasks — observe before coaching

Run the ordinary authoring path on desktop and a small-screen browser; record
which participant performs each task at each viewport. Have both Collectors
author in isolated sessions and the Owner review both. Rotate viewport order
where practical and record prior product experience. Begin without UI coaching;
record every hint, recovery and repeat attempt.

| Task | Participant action | Observe and verify |
| --- | --- | --- |
| Sign-in and scope | `C-A`, `C-B`, `O` sign in separately | Identity/role understood; each Collector sees only own contributions/activity; Owner sees both. Confirm server responses, not just hidden navigation. |
| Multi-image import | Each Collector selects an approved batch of cleared JPEG/PNG/WebP files | Exact batch count/bytes, discovery of selection, preview/name/difficulty edits, progress, cancellation, duplicate/error recovery, responsiveness and small-screen reachability. File preparation must not imply upload. |
| Draft and queue | Edit a Card/Pack, queue locally and navigate/reload | Participant can explain local draft versus unsent queue versus uploaded/synced state; preserve names/IDs/edits and last complete good dataset. No per-keystroke remote write. |
| Offline continuity | Disconnect an already-authorized tab, edit and reload it; then separately close/reopen the tab | Observe same-tab persistence. A new offline tab currently denies editing until fresh online authorization; record that limitation, then reconnect and verify original drafts/queue recover. Do not promise browser-eviction recovery. |
| Commit and Refresh | Reconnect, explicitly Commit, then manually Refresh | Participant discovers each control, sees timestamp/error/confirmation and understands their distinct effects. Record request count and transferred bytes. Unchanged Refresh should not fetch a full dataset. |
| Competing editors | Open two authorized tabs at the same revision, edit the same aggregate and Commit sequentially | Preserve winner and losing edits. Verify local CAS/remote 412 and idempotency 409 handling, conflict comprehension and intentional resolution; no silent overwrite. |
| Collector privacy | With `C-A`, use facilitator-provided `C-B` fixture IDs in detail/read/write/feed/image/activity requests | Server denies foreign access; no other Collector payload/count/activity is exposed. Restrict probes to known authorized fixture resources. Owner still reviews both without changing attribution. |
| Account/role change | Switch accounts with pending drafts; execute a separately approved revocation/downgrade test | No prior-account data renders/uploads. Record allowlist removal separately from Firebase disable/revocation; existing ID tokens are not immediately denied by Firebase-only revocation in current Worker code. |
| Owner rights review | Owner reviews both contributors' approved fixtures and an explicitly uncleared negative fixture | Correct contribution attribution; reject unauthorized/uncleared publication. If operator activation is approved for the isolated catalog, verify only the cleared revision becomes anonymously discoverable/downloadable. Otherwise mark actual publication NOT RUN. |
| Error recovery | Trigger approved upload/connection/storage faults in disposable fixtures | Clear errors and preserved local data/previous complete dataset; explicit retry/cancel; no destructive cleanup or publication side effect. |

Cache eviction deletes the only local copy of an unsent draft. Test only in a
disposable browser profile after recording/exporting permitted test evidence.
Expected behavior is fail-closed recovery with fresh authorization, not magical
draft recovery. Plaintext IndexedDB retention and same-profile visibility are
explicit privacy limits; do not describe sign-out as secure deletion.

## Physical Android tasks — outward identity and offline games

No emulator, browser touch viewport or host Flutter engine can satisfy these
physical-device observations. Install only an approved binary; do not publish a
new APK/Play/Shorebird release to conduct this protocol. Use separately pinned
public keys and a rights-cleared Pack from the approved trial endpoint. Players
never need a Studio/Firebase account.

| Task | Procedure | Record |
| --- | --- | --- |
| First playable game | From an explicit stated initial condition, discover/download the cleared Pack, configure and Start | Separate time spent obtaining/installing the app, discovering content, downloading/verifying the Pack and reaching first rendered identity. Record assistance and network conditions. |
| Warm installed launch | Disconnect all connectivity, relaunch with installed Pack and Start | No online validation/update dialog; time from launch to first identity; storage startup behavior. A server outage cannot block the installed Pack. |
| Face-to-face readability | Player holds the screen outward as intended; partner names what they can read without facilitator coaching | Physical distance, lighting, angle, font scale, orientation, name/image legibility, glare and grip. Record observed failures or requests to reposition, not assumed accessibility. |
| Complete game | Play the configured rounds through completion, including local reveal/advance behavior | Attempts to peek/tap, accidental advances, understanding of final round, any freeze/crash and total round count. Observe network attempts throughout Start → completion, not just successful responses. |
| Replay intent | Ask what the pair wants to do before offering replay instructions | Whether they intend same settings/content, different Packs or Home. Verify actual Free completion/Home reset rules; internal Pro QA replay is a separate labelled case. No billing or public Pro promise. |
| Installed-Pack management | At Home, manually Check for updates, inspect unchanged/update/error states, then explicitly Update | Participant control/understanding, delta bytes, old revision still playable if interrupted; activation applies to the next game. No launch/rebuild/gameplay polling. |
| Recovery and interruption | In disposable storage, cancel/kill/restart during an approved full/delta transfer; try an approved no-space/corrupt/untrusted case | Prior revision survives, partial content is not playable, clear retry/cancel, private images absent from public gallery. Record actual device evidence separately from injected host tests. |
| Tombstone versus removal | At Home, locally Remove Download and redownload while published; separately consume an approved fixture tombstone | Reversible local removal frees slot; authoritative deletion prevents redownload after valid sync. Running snapshot remains stable; offline devices cannot learn a new deletion. |

Do not force a background check or mutate an active GameSession to make a test
finish. Use separate approved fixture revisions/jobs for interruption and errors.
Record five-slot/ten-round Free behavior and Home/replay reset where exercised;
unexecuted cases remain NOT RUN.

## Observation form and handling blockers

For each attempt record session/participant code, role, task, viewport/device,
initial state, fixture IDs/revisions, start/end timestamps, observed outcome,
participant wording, assistance, error/request ID and sanitized evidence link.
Keep `NOT RUN`, `FAIL`, `PASS`, `UNAVAILABLE` and `WITH ASSISTANCE` distinct. Do
not backfill absent timing or human feedback with test duration or facilitator
guesses. Agree target timing/readability criteria before judging a timed trial.

Record each finding with observed behavior versus expected behavior, scope,
reproduction, severity, affected evidence and owner disposition. A reproducible
crash, lost edit, privacy leak, uncleared release or offline-game blocker stops
the relevant trial path. Preserve evidence without spreading private data.
Product fixes require a separate narrowly scoped PR and focused regression
proof. Retest the affected scenario after review; do not bundle a redesign,
backlog feature, new production deployment or content cleanup into T49.

## Demand interview — separate from engineering acceptance

After uncoached tasks, ask what participants expected, where they needed help,
whether they would choose another game and why, what content they would want,
and how they currently solve that need. Record voluntary responses, refusals,
sample/recruitment limits and whether comments concern toy fixture content.
Distinguish stated intent from observed behavior. No demand conclusion, conversion
rate, market-fit claim or willingness-to-pay estimate follows from a passing test
suite or a tiny convenience sample. Engineering sign-off and product-demand
decisions require their own evidence and Owner decisions.
