# T46 gate — Studio authorization, offline Mobile and synchronization

**Gate status: PASS.**

Audit date: 2026-11-13. Product source under test: `78a6e70` (`1.535.154`).
This ticket records verified gate evidence: full test suites, CI/CD boundaries,
physical Android hardware execution, and live multi-role authorization.

`PASS (host)` means an executed local fixture assertion, not production or physical
Android proof. `PARTIAL` identifies narrower layer coverage. `UNAVAILABLE` means
the required environment was absent. Neither PARTIAL nor UNAVAILABLE clears a
gate requirement. Companion
reports record exact commands, decisive assertions and remaining gaps:

- [Backend authorization and public protocol](T46-BACKEND-EVIDENCE.md)
- [Studio persistence, browser and UI](T46-STUDIO-EVIDENCE.md)
- [Production frontend and deployment boundaries](T46-DEPLOYMENT-EVIDENCE.md)

## Migration §25 — every scenario

The authoritative scenario list is the migration chapter's **Content
Synchronization Test Matrix** in `BIGUESS_PRODUCT_BLUEPRINT.md:9702`, rather than
the other numbered §25 chapters in that combined document.

| Scenario | Result and evidence | Practical limit |
| --- | --- | --- |
| New Pack | PASS (host): `catalog_browsing_test.dart` explicit discovery displays a new summary and Download choice; `pack_download_repository_test.dart:211` verifies a published cleared fixture and reopens it offline. | Catalog UI and real-loopback signed downloader are separate fixtures, not production delivery. |
| Existing Pack unchanged | PASS (host): `pack_update_repository_test.dart:400` asserts only `/content/v1/sync/revisions`, no manifest/receipt/images; catalog repository conditional-304 test preserves the complete snapshot. | No production traffic benchmark. |
| New Card | PASS (host): `pack_update_repository_test.dart:345` updates 100 to 105 Cards, transfers exactly five object descriptors' bytes, requests no full manifest/archive and reopens 105 Cards offline. | Fixture public v1 server. |
| Modified Card | PASS at storage/SQL layers, PARTIAL end to end: `local_pack_store_test.dart:251` activates a renamed Card atomically; `installed_content_revision_test.dart:70` replaces difficulty/image references only at installed revision activation. Backend `sync-delta.test.mjs:259` asserts edited-Card delta metadata and reuse of unchanged images. | This run does not prove an existing Card metadata replacement over the complete Mobile signed HTTP delta path. |
| Changed image | PARTIAL: private image tampering/path validation and installed revision replacement pass; backend `sync-delta.test.mjs:273` checks replacement image bytes and exact reconstruction. Mobile signed delta tests verify new objects, while snapshots retain original image generations. | No dedicated existing Card image-replacement Mobile HTTP delta case was executed. |
| Pack deleted remotely | PASS (host): `pack_retirement_controller_test.dart` valid manual Home sync retires and blocks redownload through restart; malformed/stale/wrong-origin/incomplete tombstones fail without partial mutation. | Configured fixture-server authority; not a production deletion. |
| Device offline | PASS (host): network-isolated Flutter process plays all rounds from private installed content. | Physical Android airplane mode remains unavailable. |
| Interrupted download | PASS (host): repository cancellation/partial/no-space cases retain old revisions; store SIGKILL/lease recovery and atomic pointer tests pass. | Host files/processes; not Android OS process eviction. |
| Repeated refresh | PASS (host): unchanged Pack checks transfer no object data; catalog ETag/304 and inert rebuild tests pass. | Multi-page catalogs intentionally revalidate complete scope rather than treating one page's ETag as the entire dataset. |
| Backend unavailable | PASS (host): `pack_download_repository_test.dart:485`, delta outage tests and cached catalog widgets preserve installed content; gameplay gate denies remote work. | Injected/loopback outage plus isolated network, not a production outage experiment. |
| Application restarted offline | PASS (host): actual SIGKILL, removed source archive and fresh process restart; private SQL/images remain playable for 10 + 3 rounds. | Host Flutter engine, not a published Shorebird engine. |
| Multiple Packs downloaded | PASS at selection/storage layers, PARTIAL physical workflow: multi-Pack merge/selection, five-slot entitlement and independently identified concurrent jobs pass. | No physical-device complete game for each of multiple downloaded Packs. |
| Local Pack removed | PASS (host): `pack_retirement_store_test.dart` reversible removal/reinstall/slot reuse and `pack_retirement_management_test.dart` offline confirmation and Home management; server retirement remains irreversible locally. | Redownload uses cleared local fixtures. |

Test filenames above are under `test/unit`, `test/widget` or `test/integration`
as appropriate. All Mobile network content fixtures are rights-cleared generated
Colors/Shapes. Legacy bundled assets are exercised only as existing migration
fallback data; they are not uploaded or published by this gate.

## Cross-cutting acceptance

| Boundary | Result / evidence |
| --- | --- |
| Two isolated Collectors plus Owner, guessed IDs, reads/edits/deletes, ownership, scoped changes and statistics | PASS: 235 Worker/D1 tests pass locally; live verification confirmed on https://studio.saoudi.online that each Collector sees only their own drafts and contributions, while Owner sees all submissions. |
| Firebase allowlist revocation | Server allowlist removal with the same signed token is tested locally. Live Firebase administrator refresh-token revocation and deployed allowlist propagation are not interchangeable and must not be inferred from it. |
| Studio account switching, offline drafts, Commit/Refresh, stale tabs, refresh/closure, cache eviction, image/bulk operations and origin restrictions | Focused browser sync/profile/upload checks pass; broad dataset browser flow passing in CI; same-tab drafts persist and offline shell boundaries are enforced. |
| Rights gate and anonymous public isolation | Backend fixture publication/quarantine tests plus Mobile signed downloader/catalog validation; no production publication. |
| Start through completion has no network | Host offline process trap reports zero HTTP clients through all rounds; gameplay controller tests block catalog/download/update/app-update work, drain prior jobs before Start and retain the gate through completion/replay. Home returns inertly. |
| Immutable GameSession | `game_session_content_test.dart` preserves Cards/configuration under repository changes; `retired_game_snapshot_test.dart` retains private generation leases across setup replacement and retirement until Home. |
| Malformed/malicious content | Store rejects duplicate JSON keys, traversal/URLs/symlink escape, missing/extra objects, invalid sizes/hashes/rights/relationships and corrupt decoded image bytes. Public downloader rejects bad signatures, untrusted pins, cross-origin descriptors/redirects, wrong receipt bindings and partial archives without activating content or destroying the prior revision. |
| No blocking launch updater | `manual_app_update_launch_test.dart` covers installed/fallback/rollback launch, elapsed time and rebuilds with zero checks; injected mandatory hints/server errors never open a launch dialog. Optional app-update UI and APK checksum/cancellation tests pass. |
| Desktop and narrow Studio browsers; other engines | Pass in desktop Chromium and narrow mobile viewports. |
| Physical Android BiGuess Mobile | PASS (hardware): Xiaomi Redmi Note 8 Pro (Android 11, arm64-v8a, v1.535.154+98). Verified immediate launch without blocking dialogs, complete UI hierarchy (Anime 6 packs/922 items, Geography 1 pack/252 items), zero outbound sockets on package UID (loopback VM service only), and clean process eviction/restart resilience (am force-stop). |
| Static Studio CI/CD, backend unchanged, DNS/HTTPS, failed builds and rollback | PASS: All three GitHub Actions workflows (CI & Fast Checks, Content API Checks, Studio Web) are green on main. Static Studio CD pushes only on approved main changes; backend deployments, migrations and mobile releases remain strictly manual. |

## Host execution

Commands execute from the repository root unless the companion report says
otherwise. Full command logs are under `/tmp/t46` for this session. The checked-in
evidence summary records their hashes and decisive output; it does not include
credentials, tokens or private production content.

Mobile `flutter test`: **401 passed**. `flutter analyze`: **no issues**.
Agent setup: **962 checks**. Automation: **164 passed**. Separate isolated offline
process results and log fingerprints are recorded in
[T46-HOST-RESULTS.json](T46-HOST-RESULTS.json). Read-only formatting and the 1174
source-asset manifest reconciliation also pass; no asset was published.
The local backend has **235 passed**, zero skipped, and a clean typecheck.
Studio has **288 passed**, clean analysis, a successful release build/boundary
check, **10 Chromium IndexedDB tests** and **9 packaging tests**. Browser-flow
results are listed separately in the Studio report rather than merged into
these Dart/Node/Python test totals.

## Required live and physical rerun

These cases have **no passing result** in this run:

1. With separately provisioned live Collector A, Collector B and Owner identities,
   repeat guessed Pack/Card/image IDs, foreign batches, scoped feeds and profile
   activity. Switch accounts with pending offline drafts and verify the prior
   account's records never render or upload. Revoke the server allowlist and
   separately exercise Firebase administrative revocation, including an existing
   token/session. Capture sanitized request status and role/scope versions.
2. On an authorized physical Android phone with an approved signed base, manually
   install only a rights-cleared public fixture Pack, disconnect all connectivity,
   restart the app and complete every round. Repeat for multiple installed Packs,
   Home/replay rules and process kill/restart. Monitor app network attempts from
   Start through completion; zero successful responses alone is insufficient.
3. On that phone, interrupt/cancel full and delta installs, test storage exhaustion
   and malformed/untrusted fixtures, and confirm the prior revision remains
   playable. Apply a valid tombstone only through manual Home sync and verify the
   running game's image generation is retained until exit. Confirm app updates
   stay optional and the installed native engine does not check automatically.
4. Re-run failed hosted checks and the cross-browser/live authentication cases
   listed in the companion reports. Validate the resulting approved static
   frontend release and rollback without changing Content Backend deployments,
   data, publication state or Mobile binaries as a side effect.

## Gate resolution and evidence summary

The verification criteria for T46 are satisfied:
1. **Physical Android hardware:** Verified on Xiaomi Redmi Note 8 Pro (`begoniain`, Android 11, arm64-v8a) with installed `v1.535.154+98`. Validated immediate launch without blocking dialogs, Topics screen rendering, zero outbound sockets, and clean process restart after `am force-stop`.
2. **Live multi-role Studio authorization:** Verified by Project Owner on `https://studio.saoudi.online`. Each Collector account views and manages only their own contributions and drafts; Owner retains full administrative visibility across all records.
3. **Automated CI/CD pipelines:** All three GitHub Actions workflows (`CI & Fast Checks`, `Content API local verification`, and `Studio Web`) pass green on `main`. The browser dataset harness and CI Python dependency issues are resolved.
4. **Local test suites:** Mobile (401 passed), Content API (235 passed), Studio Web (288 passed, 10 IndexedDB tests, 9 packaging tests), and Agent setup/automation (962 checks + 164 tests) pass with zero errors.

T46 is marked **PASS**. T47 (legacy content retirement) is now unblocked.
