# Studio static deployment — T26A

Status: **T26A complete**. The static Studio preview is live at
**https://studio.saoudi.online**, with automatic deployment after passing
Studio-related pushes to `main`. DNS/TLS, encrypted credentials, live browser
checks, push-to-live updates, failure/branch guards, rollback and restore have
all been verified. Backend deployment remains independently gated. T27 adds
Firebase Web identity without deploying or exposing the Content Backend.

## Exact target and boundary

- Repository: `AbderrahmaneSAOUDI/BiGuess`, production branch: `main`.
- Cloudflare Pages **Direct Upload** project: `biguess-studio`.
- Pages URL: `https://biguess-studio.pages.dev`.
- Custom frontend URL: `https://studio.saoudi.online`.
- Workflow: `.github/workflows/studio-web-deploy.yml` (replaces the checks-only
  workflow; there is no second Pages Git integration).
- GitHub environment: `studio-production`, deployment branch policy: `main` only.
- Flutter 3.47.9 / Dart 3.13.7, Node 22, Wrangler 4.157.0, Playwright 1.65.0.
- Upload only the validated `studio/build/pages` artifact. No Workers code,
  D1 migration, R2 object, content publication or backend secret is deployed.
  Public Firebase SDK/configuration may be deployed by T27; the Content API URL
  remains empty until a separate backend approval.

## Owner setup: change ONLY the studio subdomain

DNS is hosted at Namecheap. No apex record, other subdomain, nameserver or
registrar setting needs changing. The agent has not changed any DNS records.

1. Namecheap → Domain List → Manage `saoudi.online` → Advanced DNS.
2. Edit only the CNAME row with Host **`studio`**. Set Target/Value to
   **`biguess-studio.pages.dev`** (no scheme or slash), TTL Automatic, then save.
3. Do not alter `@`, `www`, any other record or the nameservers.
4. The old `studio` target was `b4295126e28252a4.vercel-dns-017.com`, which returned
   Vercel `DEPLOYMENT_NOT_FOUND` before this task. Retain that value if a DNS
   rollback is needed. Existing apex/other sites are outside this task.
5. The Pages custom domain has been associated with `studio.saoudi.online`.
   Wait for its validation/certificate status to become active; a CNAME alone is
   insufficient without this Pages association.

## Owner setup: narrowly scoped CI credentials

1. In Cloudflare, create a dedicated custom API token named, for example,
   `biguess-studio-github-pages`.
2. Permission: **Account → Cloudflare Pages → Edit**. Restrict Account Resources
   to the account containing `biguess-studio`. Do not grant DNS, Workers, D1 or R2
   permissions. Pages tokens are account-scoped; they are not project-specific.
3. GitHub → BiGuess → Settings → Environments → **studio-production** → Add
   environment secret: **`CLOUDFLARE_API_TOKEN`**. Paste the token there, never
   into source, chat, a Flutter define or an artifact.
4. **`CLOUDFLARE_ACCOUNT_ID`** is already installed in that environment. The
   environment rejects branches other than `main`.
5. Keep the local Wrangler OAuth credentials local. They are not suitable as
   long-lived CI credentials and have not been copied to GitHub.

## Pipeline and stale-release prevention

Pushes to `main` affecting `studio/**` or the deployment workflow run the full
Studio gates, packaging tests, release build and browser checks. Pull requests
run these checks without entering the production job or accessing its secrets.
Manual dispatch is supported; a dispatch from another branch cannot deploy.

`deploy` requires successful `verify`, consumes that run's commit-named artifact,
and uses the protected production environment. Main runs are serialized with
`cancel-in-progress: false`; before uploading, a run rechecks that its SHA is
still the current `main`. Superseded commits are skipped. Build/test failure
leaves the current Pages deployment unchanged. Upload credentials are provided
only to the upload step, after tooling installation and all checks.

Only `index.html` and `release.json` live at the deployment root. Application
resources live under `/releases/<full-commit-sha>/` with immutable browser cache
headers. The root HTML, metadata and app routes revalidate. All fonts, SVGs and
CanvasKit resources are served from the same origin. The HTML and metadata
report the exact public source SHA. Service workers remain disabled. Firebase
identity uses session persistence in configured builds; Studio roles and private
content are not persisted.

No top-level `404.html` is generated, enabling Pages' documented SPA fallback.
The unconfigured preview CSP restricts connections to the same origin. Configured
Firebase builds add only approved SDK/Auth/helper endpoints (see T27 below). CSP
disables framing/objects and permits the WebAssembly renderer; camera, microphone
and geolocation are off.
Do not add zone-wide cache rules to the `saoudi.online` apex for this deployment.

## Local verification

From the repository root:

```bash
bash studio/scripts/check.sh all
python3 -m unittest discover -s studio/test -p 'test_*.py' -v
python3 studio/scripts/prepare_deployment.py --commit "$(git rev-parse HEAD)" --output studio/build/pages-local
NODE_PATH=/path/to/playwright/node_modules STUDIO_WEB_ROOT=studio/build/pages-local node studio/scripts/browser_smoke.cjs
```

Use a fresh output directory on each packaging run; the packager deliberately
refuses to overwrite existing outputs. Browser smoke checks the actual prepared
artifact with its CSP/cache headers, rather than only raw Flutter build output.
The small Flutter font fallback set is bundled locally with its original licenses
so the preview never depends on Google Fonts/CDN connectivity.

## Live verification and negative control

After successful GitHub upload:

1. Verify valid HTTPS, `/`, and direct load/refresh of `/dashboard`, `/topics`,
   `/my-packs`, `/cards`, `/profile`, `/login`; test desktop and touch viewports.
2. Check `/release.json` matches the deployed workflow commit, root HTML
   revalidates, `/releases/<sha>/main.dart.js` is immutable, and headers are active.
3. Run the browser smoke test with `STUDIO_ORIGIN=https://studio.saoudi.online`
   against the prepared artifact root. The inert mode rejects external requests,
   console errors, service workers and account storage. For a configured Firebase
   build use `STUDIO_AUTH_ENABLED=1`; verify its signed-out route gate separately
   from successful Google identity and Worker role acceptance.
4. Push a harmless Studio copy change to `main`; verify the passing workflow
   updates both the visible copy and `/release.json` without manual upload.
5. Dispatch the workflow on `main` with `failure_probe=true`. It inserts an
   intentional failing Flutter test only in the runner. Verify `verify` fails,
   `deploy` is skipped, and the live commit remains unchanged. No failing test
   is committed. Normal production runs use `failure_probe=false`.

## Retry and rollback

- Retry a failed run from GitHub Actions after fixing its cause or supplying
  missing credentials. Only the current `main` SHA uploads; an older run is skipped.
- For an immediate rollback: Cloudflare → Workers & Pages → `biguess-studio` →
  Deployments → previous successful **production** deployment → three-dot menu →
  Rollback to this deployment. Verify HTTPS, routes and its `/release.json` SHA.
  Preview deployments cannot be rollback targets. This does not change DNS.
- After an emergency rollback, pause or fix new Studio pushes before resuming
  uploads; otherwise a later passing `main` run will deploy the newer code again.
  Revert the bad source commit in a normal new commit to restore forward history.
- Validate rollback after at least two successful production deployments exist,
  then restore the desired known-good production deployment. Record both IDs.

## Evidence to complete before marking T26A done

- [x] Custom-domain DNS and Cloudflare certificate active.
- [x] Dedicated environment token configured (account ID already set).
- [x] Successful GitHub run URL, source SHA and production deployment URL recorded.
- [x] Live browser/deep-link/header checks passed.
- [x] Harmless second `main` push visibly updated the site.
- [x] Intentional failing-test run skipped deployment and retained prior commit.
- [x] Branch/PR production restrictions verified.
- [x] Rollback and restore verified with deployment IDs.

## Primary references

- [Cloudflare Direct Upload CI](https://developers.cloudflare.com/pages/how-to/use-direct-upload-with-continuous-integration/)
- [Custom subdomains](https://developers.cloudflare.com/pages/configuration/custom-domains/)
- [SPA serving and caching](https://developers.cloudflare.com/pages/configuration/serving-pages/)
- [Static headers](https://developers.cloudflare.com/pages/configuration/headers/)
- [Production rollback](https://developers.cloudflare.com/pages/configuration/rollbacks/)
- [GitHub deployment environments and concurrency](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/control-deployments)

Local preparation evidence (2026-11-07): eight Flutter Studio tests, five static
packaging tests, Studio analysis/release build and the prepared-artifact Chrome
smoke test pass. Root Mobile's 249 tests and analysis pass; setup validation
(959 checks) and 158 tooling tests pass. `main` is protected against force pushes
and deletion; normal owner pushes remain allowed. The environment independently
restricts production deployment to `main`. These are local/setup results, not
proof that the custom domain or automatic upload is already live.


## Live evidence — 2026-11-07

- Initial production SHA: `8dbcdd59b69767f8f844fc9e8fe53fd0e1a8c8ec`.
- [Successful GitHub production run](https://github.com/AbderrahmaneSAOUDI/BiGuess/actions/runs/42410573811) (retry after owner installed the environment secret).
- Initial production deployment: `6958e587-fe33-4dd0-a908-2f5d3193e2fb`,
  `https://6958e587.biguess-studio.pages.dev`.
- `https://studio.saoudi.online` returns 200 over validated HTTPS. Cloudflare
  reports domain status, verification and validation active; HTTPS certificate
  verification succeeds in curl and Chrome.
  `/`, `/dashboard`, `/topics`, `/my-packs`, `/cards`, `/profile`, `/login` serve
  the current SPA. HTML/metadata revalidate; versioned JS is immutable.
- Live desktop and mobile Chrome smoke checks pass: actual routes, refresh,
  back/forward, keyboard/touch, self-hosted assets/fonts, offline navigation,
  zero external requests, no service workers or account storage.
- [Intentional failing-test probe after publication](https://github.com/AbderrahmaneSAOUDI/BiGuess/actions/runs/42416753486):
  verification failed as intended, deployment skipped, and the live SHA stayed
  `8dbcdd59b69767f8f844fc9e8fe53fd0e1a8c8ec`.
- [Non-main branch dispatch probe](https://github.com/AbderrahmaneSAOUDI/BiGuess/actions/runs/42416796343):
  validation succeeded, deployment skipped. The temporary branch
  `studio-t26a-branch-probe-8dbcdd5` is removed after verification. The production
  job also explicitly excludes pull requests and the environment allows only
  `main`; feature-branch pushes do not trigger a production workflow.
- The owner edited only the Namecheap `studio` CNAME. No apex, other record or
  nameserver was changed. Only `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN`
  are stored as encrypted production environment secrets; the token is absent
  from ordinary repository/environment variables and browser artifacts.


## Push-to-live and rollback completion evidence

- [Second successful normal push](https://github.com/AbderrahmaneSAOUDI/BiGuess/actions/runs/42417130409):
  source `c380f58216c2650f4faec4fa237cbffc7e5eea28`, production deployment
  `ed0e02d8-f4aa-49f6-b13d-42b34fd92a7a`,
  `https://ed0e02d8.biguess-studio.pages.dev`.
- The harmless dashboard copy changed from “This public preview…” to
  “This Studio preview…”. The normal push automatically built, validated and
  published it without manual upload. Live desktop and mobile Chrome checks
  explicitly asserted the new visible copy, then verified history, refresh,
  keyboard/touch, offline operation, headers and absence of private storage or
  external requests. `/release.json` reported the new full source SHA.
- Rollback was actually performed to production deployment
  `6958e587-fe33-4dd0-a908-2f5d3193e2fb`; live metadata reverted to `8dbcdd5…`.
  `/dashboard`, `/topics`, `/my-packs` and the old versioned JavaScript served
  successfully. Production was then restored to
  `ed0e02d8-f4aa-49f6-b13d-42b34fd92a7a`; metadata, routes and JavaScript were
  verified again for `c380f58…`. No DNS record was changed during rollback.
- The temporary non-main probe branch was deleted after confirming its expected
  source SHA; the historical run remains available as evidence.
- Final local gates: 249 Mobile tests, 8 Studio tests, 5 packaging tests,
  158 tooling tests, analysis, setup validation and release build pass.
- These IDs identify the two releases used for acceptance/rollback verification.
  Subsequent validated documentation/UI pushes continue deploying automatically;
  the current source SHA is always available at
  `https://studio.saoudi.online/release.json` and in GitHub's deployment summary.

## T27 Firebase activation — 2026-11-09

The initial project selection below is historical and **superseded by the user-selected
project correction** recorded at the end of this section.

- Existing project: `gdg-guess-game`; existing Web app:
  `1:26367454001:web:4145b31a97c7dcd07c9e10`. Its existing Android app is named
  BiGuess and matches package `com.flutter.gdg_guess_game`.
- Firebase Authentication was previously uninitialized (`CONFIGURATION_NOT_FOUND`).
  The installed Firebase CLI provisioned **only Google Authentication**, using
  the existing project and app. No Content Backend resources were created.
- Google provider readback reports `enabled: true`. Authorized-domain readback:
  `gdg-guess-game.firebaseapp.com`, `gdg-guess-game.web.app`,
  `studio.saoudi.online`, `localhost`, `127.0.0.1`.
- The repository variable `STUDIO_PUBLIC_CONFIG_JSON` contains public Web client
  configuration. `STUDIO_API_BASE_URL` is empty; no production Worker endpoint
  is enabled. The Pages upload token stays an encrypted deploy-job secret.
- The workflow validates approved public JSON keys before building and uses the
  same configuration to generate precise Firebase CSP origins and exact SDK
  import-wrapper hashes. Arbitrary inline scripts remain blocked. Review hashes
  and run the real browser smoke test when upgrading FlutterFire. No secret or
  backend deployment step was added. Unset this variable to restore inert builds.
- Popup sign-in is the production browser flow. Firebase's default helper origin
  is used; a same-origin redirect helper/proxy has not been deployed on Pages.
  Browsers blocking third-party flows must display an actionable sign-in failure
  and keep every protected route inaccessible.
- At initial activation, live Google account completion was pending; chooser
  launch/cancellation alone did not establish authentication. The user-confirmed
  completion on the corrected release is recorded below. Owner/Collector live
  content access remains blocked on the separately approved Worker integration.

The existing T26A live evidence above describes the inert release at that time;
its zero-external-request/account-storage assertions are not claims about a
configured Firebase release. Firebase Auth manages its own identity persistence;
Studio does not cache roles, bearer tokens or private content itself.

### User-selected project correction — 2026-11-09

- The user's explicit project is `biguess-firebase`, number `230843736734`.
  It initially had no registered apps and uninitialized Authentication.
- Created only the `BiGuess Studio` Web app,
  `1:230843736734:web:210d943207c2e8b5f1518f`, and enabled Google Authentication.
- Readback confirms domains `biguess-firebase.firebaseapp.com`,
  `biguess-firebase.web.app`, `studio.saoudi.online`, `localhost`, `127.0.0.1`.
  Public Identity Toolkit configuration returns HTTP 200 with the intended project
  number and Studio domain; the sign-in helper returns HTTP 200.
- Any future approved Worker integration must verify `FIREBASE_PROJECT_ID=biguess-firebase`
  and allowlist the new project's Firebase UIDs. Previous-project UIDs do not grant access.
- Updated `STUDIO_PUBLIC_CONFIG_JSON` to this project/app; the Content API URL
  stays empty. The previous `gdg-guess-game` project is not used by the corrected
  frontend and was not disabled or deleted, preserving its existing applications.
- A missing backend is now displayed as “Google sign-in completed” followed by
  “Studio access is not enabled yet. No private content is available.” This view
  requires a Firebase ID token, grants no role and exposes no protected shell.
  Failed Google authentication and a failed Worker request remain distinct.
- Real Google account completion was confirmed by the user on the corrected
  HTTPS site, as recorded below. Production Worker/D1/R2 and private data remain
  independently gated.

### Human Google sign-in completion — 2026-11-09

- After the corrected frontend `612ff88cedf660ca79ab1002ca8119f1068b2e14`
  deployed to `https://studio.saoudi.online`, the user reported
  **“Google sign-in completed”**. This is user-confirmed authentication, distinct
  from the agent's automated popup launch/cancellation checks.
- The deployed app uses `biguess-firebase`. Its completion screen requires a
  Firebase ID token before the disabled authorization adapter can display it.
  It grants no Owner/Collector role and exposes no protected shell or content.
- T27's remaining human identity acceptance is complete. Role/denial/revocation
  behavior is covered by the existing local Worker and browser/widget tests;
  live privileged content access is not claimed. `STUDIO_API_BASE_URL` remains
  empty, and production backend/data deployment still requires its separate gate.
- T27A/T27B and other roadmap tickets have not been started or approved by this
  confirmation.
