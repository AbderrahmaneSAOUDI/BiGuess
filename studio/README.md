# BiGuess Studio

Independent Flutter Web application. The Android Mobile project stays at the
repository root. Studio supports Web Google/Firebase sign-in and Worker-derived Owner/Collector
sessions. Builds without public Firebase configuration retain the inert preview.
The deployed frontend has Firebase configuration but no Content API URL: signing
in cannot grant a role or expose private content until the separately gated
Worker integration is configured. No content dataset or server credentials are bundled.

## Local development

Use Flutter **3.47.9**, Dart **3.13.7** (the CI pin). From `studio/`:

```bash
flutter pub get
flutter run -d chrome
bash scripts/check.sh all
```

Individual gates: `bash scripts/check.sh format|analyze|test|build` (choose one).
Format fixes: `dart format lib test`. Release output: `studio/build/web`.
No Android platform, APK or installation package is created. The build bundles
CanvasKit and fallback fonts locally (`--no-web-resources-cdn`) and disables service workers.
After the static app resources load, all preview navigation works offline.
A first visit still needs the static files; offline installation is not promised.

## Brand and icons

The Studio logo and favicon are unchanged copies of `../assets/logos/biguess_logo.webp`.
The independent app registers the brand logo and nine local SVG icons; it does not
import Mobile assets at runtime. The UI uses neutral surfaces and the exact `BiGuessColors` palette in
`lib/app/studio_brand_colors.dart`: red `#EA4335`, blue `#4285F4`, green `#34A853`,
yellow `#F9AB00`, outline `#1A1919`. Blue is the primary accent; selected labels
stay dark for readability. Red, green and yellow have semantic theme roles. No decorative hero, generated illustration or promotional
copy is included.

The supplied SVGs are optimized in `../assets/icons/`. Studio bundles only the
nine it currently uses, with local copies under `studio/assets/icons/` and an
explicit asset list. The [icon map](assets/icons/README.md) lists current uses.
`flutter_svg` renders local assets. Firebase Core/Auth and `http` are the Web
identity and Worker-session adapters; no Mobile plugins are imported.

## Boundaries

- `lib/app/`: application composition, URL routing, responsive theme tokens.
- `lib/presentation/`: shell and reusable empty/loading/offline/error states.
  Loading and offline states are presentation components, not fake live status
  indicators; no network probes run. Startup HTML also reports loading/failure.
- `lib/auth/`: Firebase identity, short-lived Worker role checks and browser
  session lifecycle. Live Worker authorization and bearer tokens are never
  persisted by the dataset layer. `lib/data/` owns T28 account/role-isolated
  IndexedDB snapshots and local draft queues; publishing remains later work.
- Do not import root Mobile UI, providers, gameplay, native plugins or bundled
  character assets. No shared Dart models are needed for empty routes. When
  needed, stable wire contracts live under `../contracts/content/`; share only
  contracts that both apps actually use.
- `scripts/check_boundary.py` enforces the deliberately narrow initial import,
  dependency, platform and build-asset policy. It is not a general secret scanner;
  review future source/dependency changes before broadening this policy.

Navigation uses clean paths (`/dashboard`, `/topics`, `/my-packs`, `/cards`,
`/profile`, `/login`) with browser history and unknown-route fallback. A static
server must fall back to `index.html` for deep-link refresh. Flutter's development
server does this. Wide screens use a rail, narrow screens a labelled drawer;
Material controls support Tab/Enter, pointer and touch. Content scrolls at large
text sizes. Browser guards require a current Worker-authorized session. Every privileged
server request must independently verify Firebase identity, origin and role;
route guards alone never authorize access.

## Static deployment: T26A

The immediate target is **`https://studio.saoudi.online`**, using the
`biguess-studio` Cloudflare Pages Direct Upload project. The
`studio-web-deploy.yml` workflow validates pull requests and deploys only a
successful current `main` build through the `studio-production` environment.
See [deployment setup, status, evidence and rollback](DEPLOYMENT.md).
T26A is complete: DNS/TLS, encrypted CI credentials, live browser checks,
push-to-live, failure/branch guards and rollback/restore are verified. Only the `studio` DNS record is in scope; the apex domain and
other records are unchanged. Workers/D1/R2 remain local and undeployed.

## Verification

Widget tests cover all destinations, compact touch navigation, 200% text,
keyboard navigation, accessible status messages, URL parsing and route updates.
Enlarged text also exercises tablet/desktop navigation at the responsive boundary.
CI also runs `node scripts/browser_smoke.cjs` against the packaged release in
headless Chromium. Unconfigured builds verify inert navigation, history, offline
operation and zero external requests or account storage. Configured builds
verify protected deep links, the real Google popup and cancellation at desktop
and narrow touch sizes. Both modes reject runtime errors and service workers.
Auth controller/client tests also run in Chrome with injected identity and HTTP
adapters; they do not require real privileged accounts.
To run locally without adding browser tooling to the app dependencies:

```bash
npm install --prefix /tmp/biguess-studio-browser --no-save --package-lock=false playwright@1.65.0
/tmp/biguess-studio-browser/node_modules/.bin/playwright install chromium
NODE_PATH=/tmp/biguess-studio-browser/node_modules node scripts/browser_smoke.cjs
```

Set `CHROME_EXECUTABLE` to use an existing Chrome executable instead.
Root Mobile checks and the release browser results are recorded in
`VERIFICATION.md`. Studio CI/deployment runs only on Studio or its own workflow changes.
Root analysis excludes this separate package and continues checking Mobile.

## Firebase Web configuration (T27)

The user-selected Studio Firebase project is `biguess-firebase` (project number
`230843736734`), with Web app `1:230843736734:web:210d943207c2e8b5f1518f`.
Google sign-in is enabled. Authorized domains are `studio.saoudi.online`,
`localhost`, `127.0.0.1`, `biguess-firebase.firebaseapp.com` and
`biguess-firebase.web.app`. These settings were read back on 2026-11-09.
This supersedes the initially inferred Mobile-associated project; see the
correction evidence in [DEPLOYMENT.md](DEPLOYMENT.md).

CI optionally reads the repository variable `STUDIO_PUBLIC_CONFIG_JSON`. It
accepts only public client fields, validated before the Flutter build:

```json
{
  "STUDIO_FIREBASE_API_KEY": "public Firebase Web API key",
  "STUDIO_FIREBASE_APP_ID": "Firebase Web app ID",
  "STUDIO_FIREBASE_PROJECT_ID": "biguess-firebase",
  "STUDIO_FIREBASE_AUTH_DOMAIN": "biguess-firebase.firebaseapp.com",
  "STUDIO_FIREBASE_MESSAGING_SENDER_ID": "230843736734",
  "STUDIO_API_BASE_URL": ""
}
```

Public Firebase client configuration is expected in JavaScript bundles. Never
supply service-account keys, OAuth client secrets, Worker credentials or R2
credentials. Unknown JSON keys are rejected. The API URL intentionally remains
empty in the live frontend: no production Worker, D1 or private content has been
released. A future approved integration must set an HTTPS API base URL and match
its precise CORS origin allowlist before any privileged content request.

For a configured local build, save this public JSON outside source and use:

```bash
STUDIO_PUBLIC_CONFIG_FILE=/absolute/path/studio-public.json bash scripts/check.sh all
python3 scripts/prepare_deployment.py --commit "$(git rev-parse HEAD)" --public-config /absolute/path/studio-public.json --output build/pages-auth
```

Packaging receives the same public file and permits only Firebase's SDK loader,
Auth token endpoints and exact helper origin in CSP; the default unconfigured
build retains a same-origin policy. Prefer the supported popup flow on this
Cloudflare Pages site. A redirect flow on browsers blocking third-party storage
requires one of [Firebase's documented same-origin/helper solutions](https://firebase.google.com/docs/auth/web/redirect-best-practices);
adding an authorized domain alone does not solve browser storage restrictions.
See [Flutter federated authentication](https://firebase.google.com/docs/auth/flutter/federated-auth)
and [Google sign-in configuration](https://firebase.google.com/docs/auth/web/google-signin).

Google authentication alone never grants access. Session restoration, refresh,
focus/resume checks and denied/error transitions must obtain fresh server roles.
Logout and account switching discard the previous role immediately. T27 does not
implement cached private datasets or draft storage; T28 below adds those separately.

When Google authentication completes while the Content API is intentionally
disabled, Studio shows “Google sign-in completed” and explains that Studio access
is not enabled. This does not grant a role or expose the shell. A real Worker
connection failure or denied role remains a separate failure state.

## Account-isolated dataset and first sync (T28)

With an independently configured API, successful Worker authorization starts a
paginated `/studio/v1/sync/initial` scan. Only the scoped administrative dataset
is stored, never the anonymous catalog as an authoring dataset. All pages stage
in memory; the last page, resume cursor, last-sync timestamp and preserved local
drafts commit in one IndexedDB transaction. Interrupted scans retain the last
complete dataset. An expired cursor gets one bounded restart; other failures
require Retry/Refresh. Refresh verifies the session before the scan and checks
the same token's UID/role again before promotion. There is no content polling,
realtime subscription, upload or per-keystroke server write.

Production uses pinned `idb_shim` over native browser IndexedDB, with explicit
schema upgrades and no native filesystem/SQLite or silent in-memory fallback.
Namespaces include protocol/scope version, Firebase project, UID and role. An
account's current-role receipt gates every read/write. Immutable local revisions
provide compare-and-swap protection against stale tabs. Downgrading Owner to
Collector changes namespace; old role drafts remain stored but inaccessible to
the new role. Logout/switch/denial immediately clear rendered content, editors,
queries and open handles; late responses cannot reactivate them. Revocation
removes the offline receipt without deleting pending drafts. No tokens, email,
private image bytes, server credentials or authority-bearing claims are stored
in the dataset or static caches.

Topics, My Packs and Cards now browse that dataset. A minimal local name editor
demonstrates durable offline edits without implementing the later Topic/Pack/Card
administration tickets. **Save locally** creates a draft; **Queue commit** marks
an unsent local commit and sends nothing. Draft, Unsent commit, Conflict and Synced
labels are distinct. A changed or removed remote revision marks a retained draft
as Conflict. The API does not supply authoritative publication revisions, so the
UI labels publication as unknown rather than equating active content with a
published revision. Future publishing/sync work can populate the optional
published-revision field.

Offline reopening requires the same tab's restored Firebase identity, a complete
previously authorized snapshot, its current-role receipt, and a nonsecret
session-storage readiness marker. A new account/tab cannot authorize offline.
Readiness is cleared on known denial/logout and cannot be granted by stored
bearer data. Blocked marker reads/writes fail closed. The UI explicitly labels
offline access and local-only edits. Remote revocation cannot be discovered while
fully offline; reconnect/focus must verify the session before content reappears.
Storage quota, private-mode restrictions, browser eviction, cleared site data and
lost session identity can make offline data unavailable. Unsaved editor text
survives a failed save; success is shown only after the transaction commits.
Browser storage is not a backup or an encryption boundary against someone with
access to the same browser profile.

API-configured T26A packages opt into a static offline shell. Its generated worker
preloads only the exact public build allowlist; API, bearer, query, cross-origin,
private and `no-store` requests/responses never enter CacheStorage. The worker
does no runtime cache writes. API-empty live builds remain inert and install no
worker; packaging automatically unregisters an older Studio shell on rollback to
that mode. Offline shell installation itself needs one successful online visit
and enough browser storage. Firebase's SDK/session must also remain available.

See [T28 verification and reproducible browser checks](T28-VERIFICATION.md).
