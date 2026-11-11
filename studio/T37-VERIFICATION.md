# T37 — contributor profile and scoped statistics

The Profile route shows the Worker-verified email, UID and current role. An
explicit **Refresh profile** loads contribution counts and validated activity.
Owner can inspect the contributor roster and select a contributor's activity;
Collector responses contain only their own totals/activity and no roster. No
profile writes, public accounts, rankings, badges or XP are added.

The authenticated `/studio/v1/profile` endpoint (also available under the frozen
`/content/v1/studio/profile` alias) projects the immutable `studio_audit` log.
It never derives counts from current entities, browser drafts or client counters.
Created content keeps its historical credit after hide, deletion, restoration or
purge. Soft deletion counts removals, including audited cascades; permanent
purge is a separate operation. Aggregate-only `batch` audit rows are excluded to
avoid counting Pack revision bookkeeping as a second contribution. Counts cover
validated content create/update/hide/activate/delete/restore/purge operations;
private image transfers and the separate publication-review ledger are excluded.
See the [wire contract](../contracts/studio/v1/profile.md).

The counts, roster totals and first activity page share one D1 snapshot. Activity
pages use encrypted, padded, expiring cursors bound to account, authoritative
role, effective authorization, filter and limit. Continuations freeze the audit
high watermark and timestamp so concurrent writes cannot alter the counts or
repeat/skip rows in that scan. Collector SQL filters by authenticated actor UID
before reading rows. Client contributor selectors, unknown query parameters,
foreign cursors and public/anonymous requests fail closed. Owner roster includes
zero-operation allowlisted accounts, the configured pinned Owner and historical
actors who no longer have access; historical commit roles are labeled separately
from current access.

The client rechecks authorization before each explicit read and again before
showing its response. It rejects mismatched identity/role and discards old-account
responses and errors. Profile state lives in memory under the account's dataset
controller so it survives the temporary authorization screen; every session
transition clears it. It is not stored in IndexedDB, browser storage, the URL or
logs. An expired page requires an explicit new Refresh; a failed next page can
retain earlier validated pages only for the same still-authorized identity/role.
There is no background polling, automatic profile fetch or per-keystroke write.
Offline profiles ask the user to reconnect for a fresh access check.

## Local reproduction

From `backend/content-api/`:

```sh
npm run typecheck
npm test
```

The new `studio-profile.test.mjs` exercises real local Workerd/D1 routing and
signed synthetic Firebase tokens (only Google's public-key response is mocked).
It verifies two isolated Collectors and Owner, audit reconciliation, idempotent
replay/failed-write exclusion, historical credit after cascade deletion/purge,
frozen pagination, cross-account/role/filter cursor rejection, guessed-ID query
rejection, revocation, CORS, anonymous/public-route denial, former contributors,
and pinned Owner authority. Migration `0009` adds an audit actor index only;
there is no counter table, audit rewrite or remote schema operation.

From `studio/`:

```sh
flutter test
flutter analyze
flutter build web --release --no-web-resources-cdn --pwa-strategy=none
python3 scripts/check_boundary.py
```

The client tests verify bearer/filter requests, malformed or leaking payloads,
manual reads, role changes before promotion, late old-account success/failure,
retained pages, auth-screen transitions and a 360px viewport with 2x text.
Root Flutter tests/analyzer and agent setup/automation checks also run.

All identities and content used for verification are synthetic local fixtures.
No backend deployment, remote migration, real-account trial or content publication
is included in this ticket.

## Results in this checkout (2026-11-11)

- Studio: 288 tests passed; analyzer clean; all 83 Dart files formatted.
- Mobile: 249 tests passed, including offline gameplay gate; analyzer clean.
- Agent setup: 962 checks passed; 163 automation tests passed.
- Content API: typecheck and build passed; full suite passed 223 tests. Final
  focused profile run passed seven tests, including opaque contributor UID
  selection, empty/oversized UID validation and the six authorization/audit cases.
- Production web and browser-fixture release builds passed; boundary check passed.
  Flutter's optional Cupertino-font/Wasm informational messages do not prevent
  successful compilation.
- Chromium acceptance passed: two isolated Collectors' identity/role, totals,
  activity and pagination; Owner roster/filter; role downgrade; revocation; and
  a 390px viewport. Rendering performs no profile fetch; ten explicit synthetic
  profile requests completed without browser errors.

Browser reproduction (Playwright must be available to Node):

```sh
flutter build web --release --no-web-resources-cdn --pwa-strategy=none \
  --target test/browser_dataset_app.dart --output build/dataset-web
CHROME_EXECUTABLE=/usr/bin/google-chrome node scripts/profile_browser.cjs
```

The browser harness serves disposable synthetic identities/data on loopback HTTP
and uses real packaged Flutter, session/controller code and IndexedDB. Its static
cache headers match the production release policy; API responses remain no-store.
It removes its temporary artifact directory and never contacts Firebase or a
production content backend. This is browser-flow evidence; authoritative SQL
scope/count reconciliation is proved separately by the real Worker tests above.
