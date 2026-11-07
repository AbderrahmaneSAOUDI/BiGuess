# BiGuess Studio — T26

Independent Flutter Web application. The Android Mobile project stays at the
repository root. This public preview has empty Dashboard, Topics, My Packs,
Cards and Profile pages and an inert sign-in explanation. It collects no account
details, makes no API calls and includes no content dataset or credentials.

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
CanvasKit locally (`--no-web-resources-cdn`) and disables service workers.
After the static app resources load, all preview navigation works offline.
A first visit still needs the static files; offline installation is not promised.

## Boundaries

- `lib/app/`: application composition, URL routing, responsive theme tokens.
- `lib/presentation/`: shell and reusable empty/loading/offline/error states.
  Loading and offline states are presentation components, not fake live status
  indicators; no network probes run. Startup HTML also reports loading/failure.
- No data/auth layer exists yet. T27 owns Firebase authentication. Later tickets
  own authorized API adapters, account-isolated storage and publishing.
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
text sizes. Routes provide no authorization and all are safe for public visitors.

## Immediate next target: T26A

**`https://studio.saoudi.online` is the immediate next deployment target in T26A.**
T26 does not configure DNS, Cloudflare Pages, hosting, secrets or a deploy workflow.
The scoped `studio-web-checks.yml` only validates; it cannot publish. T26A must add
owner-authorized Pages/DNS/TLS and main-only deployment after passing Studio gates,
verify SPA deep links and refresh, set appropriate cache/security headers and
prove rollback. The initial deployment must serve only this inert public preview.
Backend Workers/D1/R2 remain local and undeployed; authentication follows in T27.

## Verification

Widget tests cover all destinations, compact touch navigation, 200% text,
keyboard navigation, accessible status messages, URL parsing and route updates.
The CI also runs `node scripts/browser_smoke.cjs` against the release build in
headless Chromium, checking desktop pointer/keyboard and mobile touch navigation,
browser back/forward, direct-route refresh, loaded-app offline operation, no
external requests, and no account storage or service-worker registrations.
To run locally without adding browser tooling to the app dependencies:

```bash
npm install --prefix /tmp/biguess-studio-browser --no-save --package-lock=false playwright@1.65.0
/tmp/biguess-studio-browser/node_modules/.bin/playwright install chromium
NODE_PATH=/tmp/biguess-studio-browser/node_modules node scripts/browser_smoke.cjs
```

Set `CHROME_EXECUTABLE` to use an existing Chrome executable instead.
Root Mobile checks and the release browser results are recorded in
`VERIFICATION.md`. Studio CI runs only on Studio or its own workflow changes.
Root analysis excludes this separate package and continues checking Mobile.
