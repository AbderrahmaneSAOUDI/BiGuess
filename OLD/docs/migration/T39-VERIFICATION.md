# T39 verification — anonymous Mobile catalog

Mobile now supplements its existing Topic/Pack screens with a cached, summary-only
public v1 catalog. Installed content and the migration fallback remain authoritative
for gameplay. Remote summaries cannot supply Cards or make a Pack selectable.

## Configuration and request triggers

Set the build-time origin with
`--dart-define=BIGUESS_CONTENT_API_BASE_URL=https://PUBLIC-CONTENT-ORIGIN`.
The default is empty: existing local builds have no catalog network dependency.
Only HTTPS origins are accepted, except HTTP loopback origins for local tests.
No credentials, path, query or fragment belong in this value.

Opening Mobile restores saved summaries through local IO. The Topics screen offers
**Discover online content** and **Refresh catalog**. Navigating to a discovered
Topic loads its first missing Pack list once; subsequent visits use saved summaries.
Failures require explicit Refresh. Screens do not poll, refresh on rebuild, or
automatically refresh on launch. Existing APK/OTA update behavior is unchanged.

The repository uses only anonymous GET requests to `/content/v1/catalog/topics`
and `/content/v1/catalog/packs?topicId=…`. It sends no Studio/Firebase identity,
authorization header or cookie, follows no redirects, and rejects extra/private
fields, unsupported versions, inconsistent parents and malformed responses.

## Offline and cache behavior

Origin-separated v1 JSON caches live in application support storage, independently
of installed Packs and their private images. Complete scans are validated before
atomic replacement. Partial pages, network failures, malformed responses and failed
cache writes retain the previous complete snapshot. Requests have bounded pages,
response sizes and timeouts. Expired cursors restart at most once.

Single-page complete scopes use ETags/304; multi-page scopes rescan all pages so a
first-page validator cannot falsely validate a complete saved dataset. Complete
catalog disappearance marks saved summaries unavailable. It does not delete or
disable valid installed gameplay content.

Rows distinguish **Installed**, **Not downloaded** and **Unavailable**. An installed
Pack missing online is additionally labeled **Unavailable online** and remains
playable locally. Saved timestamps and refresh errors explain stale browsing.
Remote-only Packs remain disabled; downloads and installation belong to T40.
No public origin was deployed or configured by this change.

## Acceptance evidence

- Repository tests exercise real anonymous loopback HTTP, strict public schemas,
  ETags, paging, disappearance, redirects, origin isolation, disk restart and
  preservation of the last complete snapshot on failures.
- Provider tests prove launch/rebuild cache-only behavior, one missing-list fetch
  per navigation scope, manual retry, parent collision protection and installed
  content preservation.
- Widget tests cover explicit discovery, remote-only disabled selection, offline
  local gameplay navigation, unavailable labels and narrow/enlarged-text layouts.
  A configured real repository restores cache and rebuilds with an HTTP-client
  allocation trap, proving no catalog request on startup.
- Existing public Worker catalog tests verify anonymous published-only summaries;
  Mobile never invokes Studio routes. Existing offline gameplay tests also cover
  imported private-image Packs through restart and complete rounds.

Validation results are recorded with the T39 completion entry in `TODO.md`.
