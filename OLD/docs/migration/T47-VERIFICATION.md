# T47 Gate — Mobile Legacy Hardcoded Content Retirement & Asset Quarantine

**Gate status: PASS.**

Audit date: 2026-11-13.  
Target Gate: Phase F — [T47](file:///home/saoudi26/Documents/GitHub/PERSONAL/BiGuess/TODO.md#L119) (`Retire Mobile legacy hardcoded content only after T46 passes`).

---

## 1. Executive Summary & Verification Matrix

| Verification Requirement | Status | Evidence & Metrics |
|---|---|---|
| **Retire production reliance on `assets_manifest.dart` and bundled images** | **PASS** | `pubspec.yaml` assets stripped of all 7 Anime and Geography flag pack folders. Production APK contains **zero** unverified card images. |
| **Mobile plays downloaded rights-cleared Packs without legacy asset dependency** | **PASS** | Verified in `test/integration/legacy_content_retirement_test.dart` and `test/offline/local_pack_gameplay_test.dart`. Downloaded Packs play offline via SQLite projections and private file generation stores. |
| **Preserve source archives and rollback path** | **PASS** | Source image files preserved in `assets/images/` for developer tools (`scripts/export_pack.py legacy --development-only`); explicit `--dart-define=biguessUseLegacyContent=true` switch verified to activate `LegacyManifestContentRepository`. |
| **Reconcile asset inventory reports & quarantine** | **PASS** | `python3 scripts/content_inventory.py --check --include-fixtures --summary` passed with 100% reconciliation (1,174 unverified disk files quarantined, 4 cleared Shapes fixtures). |
| **Clean obsolete root directories & documentation without rewriting Git history** | **PASS** | Removed obsolete `ChatGPT/` (10 early design dossiers), `CHATGPT_CHAT.md`, `chatgpt_readme.md`, and `Obsidian/` via normal Git tracked deletions. |
| **Studio Flutter Web builds cleanly** | **PASS** | `cd studio && flutter build web --release` completed successfully (`✓ Built build/web` in 42.8s). |
| **Android Mobile builds cleanly** | **PASS** | `flutter build apk --release --target-platform android-arm64` completed successfully (`✓ Built build/app/outputs/flutter-apk/app-release.apk (22.8MB)` in 72.4s). |
| **Measure APK size reduction** | **PASS** | Baseline release APK: **35,064,718 bytes** (33.44 MiB). Lean new APK: **22,826,383 bytes** (21.77 MiB). Net reduction: **12,238,335 bytes** (~11.67 MiB, **34.9% size reduction**). |

---

## 2. APK Size Measurement & Bundled Asset Audit

### Size Comparison
- **Baseline Release APK (`build/app/outputs/flutter-apk/app-release.apk`):**  
  `35,064,718 bytes` (~33.44 MiB / 35.1 MB)
- **New Lean Release APK (`build/app/outputs/flutter-apk/app-release.apk`):**  
  `22,826,383 bytes` (~21.77 MiB / 22.8 MB)
- **Net Size Savings:**  
  `-12,238,335 bytes` (~11.67 MiB reduction, **-34.9%**)

### Internal Asset Bundle Verification
Inspection of `assets/flutter_assets/` inside the release APK via `unzip -l build/app/outputs/flutter-apk/app-release.apk`:
- **Unverified Card Images in APK:** `0` (confirmed via `unzip -l ... | grep "assets/flutter_assets/assets/images/"` returning empty).
- **Retained Core Application Assets:**
  - Typography: `assets/fonts/GoogleSans-Bold.ttf`, `GoogleSans-Medium.ttf`, `GoogleSans-Regular.ttf`
  - UI Logos: `assets/logos/` (app logo, franchise badges for UI themes)
  - Profile Avatars: `assets/profile/`
  - Shaders: `shaders/ink_sparkle.frag`, `shaders/stretch_effect.frag`
  - Configuration: `shorebird.yaml`, `AssetManifest.bin`, `FontManifest.json`

---

## 3. Runtime Architecture & Fallback Behavior

### Production Path (`useLegacy: false`)
In `lib/data/local/local_content_runtime.dart`:
1. `LocalContentRuntime.open(useLegacy: false)` accesses the local SQLite content repository (`SqliteContentRepository`).
2. When no Packs are installed (`installed.isEmpty`), the runtime initializes an empty SQLite projection rather than falling back to `LegacyManifestContentRepository`.
3. The Topics screen renders empty onboarding discovery controls ("Discover online content", "Manage installed Packs") without hardcoded anime or geography cards.
4. When a user downloads a rights-cleared Pack (or imports a `.biguesspack`), it is committed to `LocalPackStore` and projected into SQLite. The game engine plays the Pack offline with zero network calls and zero references to bundled assets.
5. In case of storage initialization failure with `useLegacy: false`, `LocalContentRuntime` falls back to `_RetirementFallback(legacy, const {}, excludeAll: true)`, ensuring that unverified legacy content is never accidentally served to players.

### Rollback Switch (`useLegacy: true`)
When explicitly configured with `--dart-define=biguessUseLegacyContent=true`:
1. `LocalContentRuntime.open` intercepts the request at startup.
2. It returns `LegacyManifestContentRepository` backed by `TopicPackDataSource` and `assets_manifest.dart`.
3. Tested and verified in:
   - `test/integration/legacy_content_retirement_test.dart`
   - `test/integration/local_content_runtime_test.dart`
   - `test/widget/manual_app_update_launch_test.dart`

---

## 4. Asset Inventory & Quarantine Reconciliation

Execution of `python3 scripts/content_inventory.py --check --include-fixtures --summary`:

```text
======================================================================
             📦 BiGuess Content Inventory & Rights Gate               
======================================================================
Total Assets Inventoried:    1178
Total Data Volume:           11.42 MB
Disk Files Scanned:          1174
Counts Reconciled:           True
Image checks:                1178 verified, 0 damaged, 0 unsupported, 0 unreadable
Rights Breakdown:            1174 unverified (quarantined), 4 cleared
Public Test Publishable:     4 (quarantine prevents public exposure)
Exact Duplicate Hash Sets:   3 (7 files)
Cross-Pack Name Matches:     7 characters
----------------------------------------------------------------------
Anime (922 cards):
   • Attack on Titan: 131 cards
   • Black Clover: 67 cards
   • Demon Slayer: 43 cards
   • Hunter X Hunter: 135 cards
   • Naruto: 80 cards
   • One Piece: 466 cards
Geography (252 cards):
   • Flags: 252 cards
Shapes (4 cards):
   • Geometric Shapes: 4 cards
======================================================================

✅ All counts reconciled and integrity checks passed!
```

- All 1,174 legacy files on disk remain cataloged and quarantined.
- No copyrighted or unverified assets are marked as public-test publishable.
- Test suites continue to use confirmed-cleared fixtures (`Shapes / Geometric Shapes` with CC0-1.0 license).

---

## 5. Repository Cleanup & History Integrity

The following obsolete files and directories were removed using standard tracked Git deletions (`git rm`), strictly preserving commit history without history rewriting or rebasing:
- `ChatGPT/` (10 early design markdown files from pre-blueprint phase)
- `CHATGPT_CHAT.md`
- `chatgpt_readme.md`
- `Obsidian/` (abandoned Obsidian vault configuration files)

---

## 6. Test Suites & Verification Results

1. **Mobile Test Suite (`flutter test`):**  
   **404/404 tests passed** (including unit, integration, widget, and offline tests).
2. **Studio Test Suite (`cd studio && flutter test`):**  
   **289/289 tests passed**.
3. **Agent Setup & Tooling Suite:**  
   - `python3 .agents/scripts/validate_setup.py`: **962 checks passed**.
   - `python3 -m unittest discover -s .agents/tests -v`: **164 tests passed**.
4. **Static Analysis (`flutter analyze`):**  
   - Root project: **No issues found!**
   - Studio project: **No issues found!**
5. **Release Compilation Gates:**  
   - Studio Flutter Web: `flutter build web --release` passed (`build/web`).
   - Android Mobile: `flutter build apk --release --target-platform android-arm64` passed (`build/app/outputs/flutter-apk/app-release.apk`, 22.8 MB).
