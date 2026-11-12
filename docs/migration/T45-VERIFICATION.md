# T45 verification — optional app updates and offline launch

Launch no longer checks the remote app version or Shorebird patch availability,
downloads patches, or opens mandatory update dialogs. This applies to installed
Packs and the migration/rollback bundled fallback. APK cache cleanup also runs
only before an explicit download, rather than delaying startup. Local installed
Pack validation remains independent of any app-update server.

About → **App updates** is the manual availability check. Checking does not apply
a patch or download an APK. A separate action downloads/installs an APK or applies
an app patch and restarts. The dialog stays dismissible, including legacy mandatory
hints and connection failures. Remote `minRequiredVersion` metadata is retained
for compatibility but does not enforce an upgrade. Any future mandatory policy
requires separate product approval.

The UI distinguishes app binaries/patches from Home's installed-Pack management.
No Pack polling, startup discovery or content replacement was added. Existing
gameplay cancellation/draining guards remain in place. `shorebird.yaml` already
disables native `auto_update`; these source changes do not retrofit an older
published engine. A future approved binary release must verify that configuration
on the device.

Explicit APK downloads require HTTPS and a valid publisher SHA-256. Bytes remain
temporary until their hash matches. Cancellation, malformed hashes, mismatches
and storage failures cannot launch a partial APK. Cached installer retries require
the current controller's verified download identity and rehash the file before
installation. Cleanup affects only owned APK cache files, preserving Pack storage
and unrelated files. The development-signing guard remains enforced.

## Verification

- Launch widget tests cover installed Packs, empty migration fallback and explicit
  rollback. Rebuilds and elapsed time cause no update calls. Injected legacy
  mandatory hints and unavailable-server errors do not open a launch dialog.
- Optional UI tests cover explicit checks, a separate installation action,
  dismissal/cancellation and app-versus-Pack wording.
- Version decisions ignore minimum-version enforcement while retaining ABI and
  version selection. APK tests verify hashes, invalid metadata, tampering,
  cancellation during asynchronous cache lookup, concurrent rejection and retry
  after storage failure. Unbound cached APKs cannot launch the installer.
- `flutter test`: **401 passed**; `flutter analyze`: **no issues**.
- Agent setup: **962 checks**; automation: **164 tests passed**.
- Isolated offline process gate: SIGKILL during the first rendered round, source
  archive removed, fresh process restart, all **10 + 3 rounds**, **zero HTTP
  clients**, SQLite integrity and foreign keys valid. Evidence was captured in
  `/tmp/t45-offline/summary.json` and its phase logs.

These are host Flutter/SQLite/file-system checks. Physical Android installation,
published Shorebird-engine behavior and Play Store release validation remain
device/release gates. No APK/OTA release, backend deployment or production
publication was performed. Shared unrelated `TODO.md` edits were preserved and
excluded from this task's commit.
