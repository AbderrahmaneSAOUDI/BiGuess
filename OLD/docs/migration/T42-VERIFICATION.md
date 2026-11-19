# T42 verification — verified local gameplay and offline Start boundary

The installed-Pack route uses Topic/Pack IDs for browsing and selection, then
freezes freshly verified private content at **Start Game**. Each subsequent round
and internal Pro replay uses that immutable session snapshot. It does not query a
catalog, authenticate a player or retrieve image URLs.

## Start and local authority

`LocalContentRuntime.verifyForPlay` reopens every selected committed generation,
including its manifest and private image integrity checks. It rejects missing,
corrupt, wrong-Topic or uncleared-development content. SQLite remains a disposable
browsing projection: cached Cards or an altered SQL installed revision cannot
replace the file-verified Cards handed to the game. The setup step rechecks Free
entitlement after asynchronous work and freezes the verified pool only on success.

Missing/damaged bytes leave the player in setup with an error and **Back to Packs**.
A summary-only Pack remains unselectable and shows the existing explicit Download
action in the Pack browser. A download/install must complete before it can supply
Cards. Neither catalog visibility nor service availability gates installed play.

The migration fallback and explicit `biguessUseLegacyContent` rollback remain as
required until T47; this ticket does not retire bundled sources or assets. The
verified installed runtime always uses private generation images. Legacy rollback
continues on its separate bundled compatibility path rather than being relabeled
as verified downloaded content.

## Network boundary

Before creating the session, setup sets the preparation gate, cancels queued and
active content downloads, and closes earlier catalog HTTP clients. If an atomic
install has already begun committing, Start waits for its safe completion and
reopens the resulting private generation. No accepted download or late catalog
page can continue into ordinary gameplay.

The gate remains closed through active rounds and completion, including direct
internal Pro replay. Content repositories cannot start new requests while blocked;
controller methods also guard against calls through injected/test repositories.
Returning to Home/exit releases the gate and restores cache/manual-request
eligibility without initiating a request or polling.

`shorebird.yaml` sets `auto_update: false`, closing the native engine's independent
launch-update path that could otherwise continue into a game. This follows the
[Shorebird manual-update configuration](https://docs.shorebird.dev/code-push/update-strategies/).
The setting must be verified in a new approved base binary, not assumed to reach
already installed binaries through a Dart-only patch. Native patch/rollback checks
then occur through app-update checks outside gameplay; an already installed patch
continues to run. The existing native-change release marker remains true.

About's app-update controls are replaced with a return-to-Packs hint during the
gate. `UpdateController.pauseForGameplay` cancels version-manifest HTTP and APK
transfers and drains already-running native update work before the session begins.
Operation epochs prevent old work from launching another request, installer or
restart after being paused. Version request cancellation is isolated by service
instance. Home resumes eligibility without checking automatically. The existing
Dart app-launch update policy for the legacy fallback is unchanged; its separate
replacement remains T45.
No fresh app-update request is required to start an installed Pack.

## Free and QA rules

Existing local store enforcement permits five Free downloaded Packs and counts
installation plus activation under the writer lock. Retrying/updating an existing
Pack uses the same slot; concurrent sixth installs cannot bypass the limit.
GameSetup and GameSessionConfiguration enforce 1–10 Free rounds. The environment
entitlement forces Free in release builds even if the internal QA define is set.
Non-release `isProTestEnabled=true` remains the internal unlimited-storage/rounds
and direct-replay test path. No public account, billing, ad or online entitlement
check was added. Free replay returns through Home/Packs and clears the old session.

## Evidence

- The full Flutter suite covers the real Topic → Pack → setup → all-rounds route,
  Free limits, concurrent slot enforcement, internal Pro behavior, completion,
  replay and Home reset, including preservation of the migration fallback.
- New file-authority tests replace the SQL installed projection with an untrusted
  newer Card/image URL and still obtain the original private verified revision;
  corrupt/missing files fail before a session can be frozen.
- Start widget tests exercise an earlier pending catalog request/download, verify
  cancellation before play, block new requests while active and reject corrupted
  private image bytes. Separate real loopback HTTP tests verify catalog close
  aborts an outstanding refresh and preserves its last complete saved dataset.
- App-update tests cover hidden in-session actions, native-operation draining,
  suppressed post-pause install/restart stages and real per-instance HTTP body
  cancellation. Gate tests span preparation, every round, completion and Home.
- The host offline process gate runs with no external interface/route and an HTTP
  client trap. It kills the app during a rendered private Card, removes the import
  archive, restarts from SQLite/private generations, decodes images and completes
  all 10 + 3 rounds with zero HTTP clients and valid database integrity.

Final totals and process-gate results are recorded in `TODO.md`. Physical Android
and published Shorebird-engine airplane-mode behavior remain T46 device gates;
host proof does not replace them. No backend deployment, publication, APK or OTA
release was performed.
