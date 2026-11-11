# T40 verification — verified complete Pack downloads

Mobile offers user-triggered **Download** actions for available public Pack
summaries and **Download update** for newer published revisions. The sheet shows
byte progress, verification/installation phases, completion and actionable failure
messages, with explicit Retry. No launch, rebuild, gameplay or catalog refresh
starts a download. One foreground download runs at a time; automatic retries,
resumption and download-manager work remain in T41.

## Trust and public protocol

The downloader uses only the configured public origin and fixed v1 Pack paths:
`download`, followed by that revision's `signature`, `manifest` and
`archive.biguesspack`. Descriptor URLs must exactly equal the expected same-origin
paths. Redirects are disabled. No Studio/Firebase account, authorization header,
cookie, response-supplied key or arbitrary storage URL is used.

The build pins trusted public keys with `BIGUESS_CONTENT_PUBLIC_KEYS`, a JSON
object mapping lowercase SHA-256 SPKI fingerprints to base64 Ed25519 SPKI bytes.
Use it alongside the T39 `BIGUESS_CONTENT_API_BASE_URL` origin. Pins default to an
empty object, which trusts no publisher. Invalid configuration also fails closed.
Configure reviewed public keys from the publisher through the build process;
never obtain pins from the download server or reuse fixture keys in production.
For a local fixture build, a define file can contain:

```json
{
  "BIGUESS_CONTENT_API_BASE_URL": "http://127.0.0.1:8787",
  "BIGUESS_CONTENT_PUBLIC_KEYS": "{\"<sha256-of-public-spki>\":\"<base64-public-spki>\"}"
}
```

Pass the file with `flutter run --dart-define-from-file=<local-config.json>`.
Remote origins require HTTPS. No production endpoint, signing key, fixture trust
pin, backend deployment or publication was configured by this ticket.

Before installation, the client checks:

- Public descriptor version, expected Pack/revision and saved summary manifest hash.
- Receipt schema, Ed25519 algorithm, pinned SPKI structure/fingerprint and signature
  over the publisher's exact ordered statement bytes and trailing newline.
- Publication domain, Topic/Pack/revision, signed manifest/archive hashes and sizes.
- Manifest bytes, canonical manifest identity, Card count and cleared provenance.
- Streamed archive length/hash, then existing full archive validation, object
  hashes, media/dimensions and identity relationships.

The Ed25519 verifier uses the pure Dart `cryptography` dependency; see its
[Ed25519 API](https://pub.dev/documentation/cryptography/latest/cryptography/Ed25519-class.html).
Network operations have timeouts and bounded response sizes. A stale summary
requires an explicit catalog refresh rather than installing a different revision.
Public server visibility checks continue to reject hidden/unpublished content.

## Private activation and failures

Downloads stage beneath the application-private Pack root. Partial temporary files
are cleaned on completion/failure. Images never enter a public gallery. The existing
`LocalPackStore` performs serialized validation and atomic generation activation;
old generation paths remain available to active immutable game snapshots.
The writer lock now also rejects conflicting Topic metadata across installed Packs,
preventing an import that the startup projection could not reconcile.

After successful activation, `LocalContentRuntime.reloadInstalled()` verifies all
committed generations and refreshes the SQLite projection. The provider invalidates
local browsing only after that succeeds. A projection error retains the previous
view and explicitly reports that verified files were saved; Retry/restart reopens
them. Empty/failed storage and explicit legacy rollback retain the existing
migration fallback. Catalog summaries never supply gameplay Cards.

Corruption, untrusted keys, offline/HTTP failures, timeout, private storage/no-space
and Free's five-Pack limit have error states. Retry is manual. A failed download or
failed atomic activation never marks a partial Pack installed or replaces the
previous committed pointer. Removing content and tombstone policy are outside T40.

## Evidence and limits

Repository tests use a real anonymous loopback HTTP server, Ed25519-signed cleared
color fixtures and real private storage. They cover successful installation and
offline reopen, tampering, unknown/malformed pins, incorrect signed sizes, initial
partial downloads, failed revision updates, no-space errors, timeout, redirects,
cross-origin descriptor rejection and successful retry.

Controller integration tests verify idle behavior, explicit progress, one active
operation, unchanged local content on failure, manual retry, SQLite refresh and
restart. Widget tests exercise Download, progress, no-space messaging, Retry and
installed labels. Store tests verify conflicting Topic metadata preserves the old
Pack. Existing offline gameplay tests cover private images, restart and all rounds
with zero HTTP clients. This is host acceptance evidence; airplane-mode behavior on
a physical Android/Shorebird release remains a separate device gate.

Final command results are recorded in the T40 completion entry in `TODO.md`.
