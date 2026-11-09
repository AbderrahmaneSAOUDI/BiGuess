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
  session lifecycle. Roles and content are never persisted in browser storage.
  Later tickets own account-isolated drafts and publishing.
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
implement cached private datasets or draft storage.

When Google authentication completes while the Content API is intentionally
disabled, Studio shows “Google sign-in completed” and explains that Studio access
is not enabled. This does not grant a role or expose the shell. A real Worker
connection failure or denied role remains a separate failure state.
