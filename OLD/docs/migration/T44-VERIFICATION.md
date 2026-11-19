# T44 verification — local removal, authoritative retirement and safe storage cleanup

Home's installed-Pack management now separates **Remove Download** from a
publisher deletion. Local removal asks for confirmation, works without an online
endpoint, frees the Free download slot and leaves a **Download removed** record.
The player can return to Topic browsing and download again if the Pack is still
published. It sends no server deletion request and creates no cloud tombstone.

**Check for updates** explicitly explains that a manual check also applies server
Pack deletions at Home. The UI explains that offline devices may keep copies until
they reconnect and sync. A valid deletion becomes **Deleted by publisher**, with no
redownload action. Unknown/unavailable results and absent catalog entries do not
retire anything. No startup, rebuild, round, replay or forced online check was added.

## Valid synchronization and durable authority

The public revision feed remains the existing T25 endpoint. The transport validates
the complete response for every requested ID before returning any result, including
all batches. Deletion evidence must name that exact Pack, advance its known local
revision, use the administrative-deletion reason and carry a valid UTC timestamp
without date overflow. Its source origin is attached from the configured endpoint,
never accepted from the response body. Remote origins require HTTPS; HTTP remains
limited to loopback fixtures. This is configured-server authority through the public
transport, not a Studio login or a newly invented tombstone-signature protocol.

Manual checks include active cleared Packs and previously user-removed public
identities, so a later deletion can be learned even after local removal. Private
local development IDs and already authoritative retirements are not sent. A malformed,
partial, cancelled, reordered, duplicated or stale result cannot partially apply a
batch. The Home controller also checks the configured source origin and rechecks the
safe-point/cancellation guard inside the store immediately before the atomic commit.

Authoritative tombstones commit as one bounded private ledger transaction, with
revision/digest comparisons against installed or locally removed records. That ledger
is consulted by installed reads and installation, and survives cleanup/restart.
Cached summaries and even previously valid full archives cannot reinstall a retired
ID. The raw full downloader rejects a known tombstone before HTTP as well as at the
final store boundary. No client restore policy for authoritatively retired IDs is
introduced; a catalog entry alone cannot erase deletion evidence.

Local removal atomically replaces the installed pointer with a reversible removal
record. Cancellation before commit, storage-full and rename failures retain the old
pointer and its slot state. Once an atomic commit begins, completion wins. Server
retirement similarly validates every local revision comparison before its single
ledger commit; a newer concurrent activation makes stale evidence fail safely.

## Home/exit boundary and immutable games

Active rounds, completion and internal Pro replay keep the existing network/storage
management gate closed. Start cancels/drains a pending manual check; a late deletion
is not queued for automatic application on a later Home visit. Applying a tombstone
or local removal refreshes local management metadata before the disposable SQL view,
so a projection error cannot make a known retired ID appear playable through stale
SQL rows. Start always reopens the private store authority.

Verified Start now retains shared generation leases through the full session,
including setup route replacement. Home/exit releases them; failed Start and runtime
disposal also release them. Canonical local reference counts and OS locks protect
snapshots in the owning isolate and other processes. A second process may retire a
Pack at its own Home boundary while the first continues every round with its original
private images. No active session snapshot is rewritten.

After the last managed download is removed, local history keeps an empty installed
SQL view rather than resurrecting bundled content. The migration fallback remains
for never-managed/explicit rollback use until T47, but even explicit rollback filters
known retired IDs. Unreadable management authority fails closed without deleting
saved files; Home displays the storage error.

## Bounded storage cleanup

**Clean up storage** is a local Home action. Removal, valid retirement and cold open
also attempt bounded cleanup. Temporary-download recovery and obsolete-generation
cleanup each remove at most eight owned entries per pass. Current installed generations,
uncertain metadata, live transfers and leased image generations are protected.

Cleanup also revisits non-current generations after redownload/update, even if a
local-removal record has already been replaced. Otherwise a protected old generation
could be stranded forever. Repeated safe passes reclaim remaining bytes. Slot release
is atomic; physical byte reclamation waits for readers and the cleanup budget.

New generations reserve their reader-lock file before activation. Start opens that
file read-only, avoiding an additional file allocation when playing on a full disk.
Older generations gain the lease file when first retained. Disposing leases remains
safe if the support directory disappears, without leaking handles or local holds.

## Validation

- New real-loopback transport cases: strict tombstones, malformed/stale/wrong-ID
  evidence, complete result validation/cancellation, previously removed public IDs
  and excluded private IDs. Checks themselves remain read-only.
- Store cases: reversible removal/reinstall, Free-slot reuse, atomic multi-Pack
  tombstones, stale concurrent writers, disk-full/rename/cancel rollback, permanent
  reinstall denial, missing-root release, bounded cleanup and redownload/update GC.
- Actual process tests: foreign shared playback leases and SIGKILL before/after
  ledger commit preserve committed authority and old leased image bytes.
- Controller/widgets: offline confirmation/Keep, last-download removal, persistent
  Home access, manual sync retirement, no cached redownload, no midgame mutation,
  cancelled checks not later applied, explicit rollback filtering and leases across
  the real Topic → Pack → setup → game → Home route.
- Full Mobile tests and the isolated host offline process gate cover restart,
  private decoding and all rounds with zero HTTP clients and SQLite integrity.

Final host results: `flutter test` **389 passed**; `flutter analyze` **no issues**;
agent setup **962 checks**; agent automation **164 tests passed**. The isolated
offline process gate passes SIGKILL/source removal/fresh restart, all **10 + 3**
rounds, **zero HTTP clients**, and SQLite integrity/foreign-key checks.

Physical Android and
published Shorebird-engine validation remain separate device/release gates. No
backend change, deployment, production publication, APK or OTA release is required.
