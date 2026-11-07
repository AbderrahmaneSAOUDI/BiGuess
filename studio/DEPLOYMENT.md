# Studio static deployment — T26A

Status: **live; final acceptance checks in progress**. Custom-domain DNS/TLS and
the encrypted upload token are configured. The first GitHub deployment and live
browser checks pass. The second-push and rollback evidence is being completed.

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
  D1 migration, R2 object, content publication, auth SDK or backend secret is
  deployed. The website remains the inert T26 preview.

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
report the exact public source SHA. Service workers and private browser storage
remain disabled.

No top-level `404.html` is generated, enabling Pages' documented SPA fallback.
CSP restricts connections to the same origin, disables framing/objects and
permits the WebAssembly renderer; camera, microphone and geolocation are off.
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
   against the prepared artifact root. It rejects external requests, console
   errors, service workers and account storage.
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
- [ ] Harmless second `main` push visibly updated the site.
- [x] Intentional failing-test run skipped deployment and retained prior commit.
- [x] Branch/PR production restrictions verified.
- [ ] Rollback and restore verified with deployment IDs.

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
